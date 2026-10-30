import AVFoundation
import Foundation
import Speech

// The real `Dictation`: Apple's on-device SpeechAnalyzer + SpeechTranscriber (macOS 26+), microphone through AVAudioEngine.
// SpeechTranscriber runs on-device only and does not use SFSpeechRecognizer, so only the microphone permission is needed.
// Below macOS 26 (the package deployment target is 14) it reports `.needsNewerOS` and touches no Speech API.

public enum MicrophoneStatus: Equatable, Sendable { case granted, denied, restricted }

public protocol MicrophoneAccess: Sendable {
    /// The current permission; asks (system prompt) only when the user was never asked.
    func ensure() async -> MicrophoneStatus
}

public struct SystemMicrophoneAccess: MicrophoneAccess {
    public init() {}
    public func ensure() async -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

private protocol SessionControl: AnyObject {
    @MainActor func requestStop()
}

@MainActor
public final class SpeechDictation: Dictation {
    public var onEvent: (@MainActor (DictationEvent) -> Void)?
    public static var osSupported: Bool { if #available(macOS 26, *) { true } else { false } }

    private let mic: MicrophoneAccess
    private let locale: Locale
    private let osSupported: Bool
    private var generation = 0
    private var task: Task<Void, Never>?
    private var session: SessionControl?
    private var pendingStart = false

    public init(mic: MicrophoneAccess = SystemMicrophoneAccess(), locale: Locale = .current, osSupported: Bool = SpeechDictation.osSupported) {
        self.mic = mic; self.locale = locale; self.osSupported = osSupported
    }

    public func start() {
        guard task == nil else { pendingStart = true; return }   // a session is still shutting down: start after it
        generation += 1
        let gen = generation
        task = Task { [weak self] in await self?.run(gen) }
    }

    public func stop() {
        guard task != nil else { return }
        if let session { session.requestStop() } else { task?.cancel() }
    }

    private func run(_ gen: Int) async {
        let emit: @MainActor (DictationEvent) -> Void = { [weak self] e in
            guard let self, self.generation == gen else { return }
            self.onEvent?(e)
        }
        defer {
            if generation == gen {
                task = nil; session = nil
                if pendingStart { pendingStart = false; start() }
            }
        }
        emit(.state(.preparing))
        guard osSupported else { emit(.state(.error(.needsNewerOS))); return }
        switch await mic.ensure() {
        case .granted: break
        case .denied: emit(.state(.error(.microphoneDenied))); return
        case .restricted: emit(.state(.error(.microphoneRestricted))); return
        }
        if Task.isCancelled { emit(.state(.idle)); return }
        if #available(macOS 26, *) {
            let s = SpeechSession(locale: locale, emit: emit)
            session = s
            await s.run()
        } else {
            emit(.state(.error(.needsNewerOS)))
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class SpeechSession: SessionControl {
    private let locale: Locale
    private let emit: @MainActor (DictationEvent) -> Void
    private let stopSignal = AsyncStream.makeStream(of: Void.self)
    private var stopRequested = false

    init(locale: Locale, emit: @escaping @MainActor (DictationEvent) -> Void) { self.locale = locale; self.emit = emit }

    func requestStop() {
        guard !stopRequested else { return }
        stopRequested = true
        stopSignal.continuation.yield()
    }

    /// Prepares assets, listens until `requestStop`, then finalises. Always ends with `.idle` or `.error`.
    func run() async {
        var feeder: AudioFeeder?
        var inputEnd: AsyncStream<AnalyzerInput>.Continuation?
        var analyzer: SpeechAnalyzer?
        var results: Task<Void, Error>?
        do {
            // The user's locale, else en-US.
            var chosen = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            if chosen == nil { chosen = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
            guard let chosen else { emit(.state(.error(.languageUnsupported(locale.identifier)))); return }
            let transcriber = SpeechTranscriber(locale: chosen, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])

            switch await AssetInventory.status(forModules: [transcriber]) {
            case .unsupported:
                emit(.state(.error(.languageUnsupported(chosen.identifier)))); return
            case .supported, .downloading:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
            case .installed: break
            @unknown default: break
            }
            if stopRequested { emit(.state(.idle)); return }

            let a = SpeechAnalyzer(modules: [transcriber])
            analyzer = a
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                emit(.state(.error(.failed("no compatible audio format")))); return
            }
            let input = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputEnd = input.continuation
            let emit = self.emit
            results = Task { @MainActor in
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    emit(r.isFinal ? .final(text) : .partial(text))
                }
            }
            let f = AudioFeeder(target: format, input: input.continuation, gate: SilenceGate()) { [weak self] in
                Task { @MainActor in self?.requestStop() }
            }
            feeder = f
            try await a.start(inputSequence: input.stream)
            try f.start()
            emit(.state(.listening))

            for await _ in stopSignal.stream { break }

            f.stop(); input.continuation.finish()
            try await a.finalizeAndFinishThroughEndOfInput()
            try await results?.value
            emit(.state(.idle))
        } catch {
            feeder?.stop(); inputEnd?.finish()
            results?.cancel()
            await analyzer?.cancelAndFinishNow()
            emit(.state(.error(.failed(error.localizedDescription))))
        }
    }
}

/// Microphone -> converted buffers for the analyzer, plus the silence gate. Lives off the main actor (audio thread).
@available(macOS 26.0, *)
private final class AudioFeeder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let onSilence: @Sendable () -> Void
    private let lock = NSLock()
    private var gate: SilenceGate
    private var fired = false
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation, gate: SilenceGate, onSilence: @escaping @Sendable () -> Void) {
        self.target = target; self.input = input; self.gate = gate; self.onSilence = onSilence
    }

    func start() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationFeedError.noInput }
        if format != target { converter = AVAudioConverter(from: format, to: target) }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in handle(buffer) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let ch = buffer.floatChannelData, buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[0][i] * ch[0][i] }
            rms = (sum / Float(buffer.frameLength)).squareRoot()
        }
        let stopNow: Bool = lock.withLock {
            guard !fired, gate.feed(rms: rms, duration: Double(buffer.frameLength) / buffer.format.sampleRate) else { return false }
            fired = true
            return true
        }
        if stopNow { onSilence() }

        guard let converter else { input.yield(AnalyzerInput(buffer: buffer)); return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let fed = FedFlag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed.take() { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: out))
    }
}

private final class FedFlag: @unchecked Sendable {
    private var done = false
    /// True when the buffer was already handed over.
    func take() -> Bool { defer { done = true }; return done }
}

private enum DictationFeedError: LocalizedError {
    case noInput
    var errorDescription: String? { "no microphone input is available" }
}

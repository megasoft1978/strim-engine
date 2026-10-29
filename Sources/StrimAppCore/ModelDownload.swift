import Foundation
import Combine

public struct ModelDownloadProgress: Equatable, Sendable {
    public var file: String
    public var doneBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSec: Double
    public var etaSec: Double?
    public init(file: String, doneBytes: Int64, totalBytes: Int64, bytesPerSec: Double, etaSec: Double? = nil) {
        self.file = file; self.doneBytes = doneBytes; self.totalBytes = totalBytes
        self.bytesPerSec = bytesPerSec; self.etaSec = etaSec
    }
    public var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

public enum ModelDownloadState: Equatable, Sendable {
    case idle
    case needsDownload(sizeBytes: Int64, freeBytes: Int64, resumable: Bool)
    case confirming
    case downloading(ModelDownloadProgress)
    case verifying(file: String)
    case startingServer
    case done
    case failed(message: String, resumable: Bool)

    /// States that replace the normal Status dashboard with the focused first-run flow.
    public var isBlockingFirstRun: Bool {
        switch self {
        case .needsDownload, .confirming, .downloading, .verifying, .startingServer, .failed: true
        case .idle, .done: false
        }
    }
}

public enum PullJSONEvent: Equatable, Sendable {
    case plan(totalBytes: Int64, files: [String])
    case progress(ModelDownloadProgress)
    case verify(file: String)
    case done
    case error(code: String, message: String)
    case ignored
}

/// Incremental NDJSON parser. Unknown event names and malformed lines are ignored for forward compatibility.
public struct PullJSONParser: Sendable {
    private var pending = Data()
    public init() {}
    public mutating func append(_ data: Data) -> [PullJSONEvent] {
        pending.append(data)
        var out: [PullJSONEvent] = []
        while let nl = pending.firstIndex(of: 0x0a) {
            let line = pending[..<nl]
            pending.removeSubrange(...nl)
            if let event = Self.parse(line), event != .ignored { out.append(event) }
        }
        return out
    }
    public mutating func finish() -> [PullJSONEvent] {
        defer { pending.removeAll() }
        guard let event = Self.parse(pending), event != .ignored else { return [] }
        return [event]
    }
    private static func parse(_ data: Data) -> PullJSONEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = obj["event"] as? String else { return .ignored }
        switch kind {
        case "plan":
            guard let total = (obj["totalBytes"] as? NSNumber)?.int64Value, let files = obj["files"] as? [String] else { return .ignored }
            return .plan(totalBytes: total, files: files)
        case "progress":
            guard let file = obj["file"] as? String, let done = (obj["doneBytes"] as? NSNumber)?.int64Value,
                  let total = (obj["totalBytes"] as? NSNumber)?.int64Value,
                  let rate = (obj["bytesPerSec"] as? NSNumber)?.doubleValue else { return .ignored }
            return .progress(.init(file: file, doneBytes: done, totalBytes: total, bytesPerSec: rate,
                                   etaSec: (obj["etaSec"] as? NSNumber)?.doubleValue))
        case "verify": return (obj["file"] as? String).map(PullJSONEvent.verify) ?? .ignored
        case "done": return .done
        case "error":
            guard let code = obj["code"] as? String, let message = obj["message"] as? String else { return .ignored }
            return .error(code: code, message: message)
        default: return .ignored
        }
    }
}

public protocol ModelDownloadProcess: Sendable {
    func run(binary: String, arguments: [String], line: @escaping @Sendable (Data) -> Void) async throws
    func cancel()
}

/// Runs the installed CLI and forwards stdout bytes. It always terminates a live child during cancellation/deinit.
public final class ProcessModelDownload: ModelDownloadProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    public init() {}
    public func run(binary: String, arguments: [String], line: @escaping @Sendable (Data) -> Void) async throws {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: binary); p.arguments = arguments
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        setProcess(p)
        defer { setProcess(nil) }
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in let data = h.availableData; if !data.isEmpty { line(data) } }
        try p.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in continuation.resume() }
        }
        handle.readabilityHandler = nil
        let tail = handle.readDataToEndOfFile(); if !tail.isEmpty { line(tail) }
        guard p.terminationStatus == 0 else { throw ProcessModelDownloadError.exit(p.terminationStatus) }
    }
    public func cancel() { lock.lock(); let p = process; lock.unlock(); if let p, p.isRunning { kill(p.processIdentifier, SIGINT) } }
    private func setProcess(_ value: Process?) { lock.lock(); process = value; lock.unlock() }
    deinit { cancel() }
}

public enum ProcessModelDownloadError: Error { case exit(Int32) }

private final class DownloadEventDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    func append(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
    func drain() -> [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; defer { tasks.removeAll() }; return tasks }
}

@MainActor
public final class ModelDownloader: ObservableObject {
    @Published public private(set) var state: ModelDownloadState = .idle
    public static let modelBytes: Int64 = 15_200_000_000
    public static let reserveBytes: Int64 = 5_000_000_000
    public let process: ModelDownloadProcess
    private let binary: () -> String?
    private let directory: String
    private let freeSpace: (URL) -> Int64
    private let modelExists: () -> Bool
    private var autostart: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var activeRunID = UUID()
    private var parser = PullJSONParser()
    private var resumable = false
    /// Fraction reached when the user paused; shown as "Paused at 42%".
    @Published public private(set) var pausedFraction: Double?
    private var cancelRequested = false
    private var hasConfirmed = false
    private var modelReadyReported = false
    private var pendingProcessError: (String, String)?

    deinit { process.cancel() }

    public init(process: ModelDownloadProcess = ProcessModelDownload(), directory: String = NSHomeDirectory() + "/.strim/models",
                binary: @escaping () -> String? = {
                    if case .found(let path) = HostCommand.resolveBinary(settings: AppSettings()) { path } else { nil }
                },
                freeSpace: @escaping (URL) -> Int64 = { ModelDisk.freeBytes(at: $0) },
                modelExists: (() -> Bool)? = nil, initialState: ModelDownloadState = .idle, pausedFraction: Double? = nil,
                autostart: @escaping @MainActor () -> Void = {}) {
        self.process = process; self.directory = directory; self.binary = binary; self.freeSpace = freeSpace; self.autostart = autostart
        self.modelExists = modelExists ?? { ModelDisk.hasRequiredFiles(at: directory) }
        self.state = initialState
        self.pausedFraction = pausedFraction
        self.resumable = ModelDisk.hasPartialFiles(at: directory)
    }
    public func inspect() {
        if modelExists() {
            state = .done
            if !modelReadyReported { modelReadyReported = true; autostart() }
            return
        }
        let free = freeSpace(URL(fileURLWithPath: directory))
        state = .needsDownload(sizeBytes: Self.modelBytes, freeBytes: free, resumable: resumable)
    }
    public var availableFreeBytes: Int64 { freeSpace(URL(fileURLWithPath: directory)) }
    public func serverDidStart() {
        guard case .startingServer = state else { return }
        state = .done
    }
    public func setAutostartHandler(_ handler: @escaping @MainActor () -> Void) { autostart = handler }
    public func confirm() {
        guard case .needsDownload = state else { return }
        state = .confirming
    }
    public func dismissConfirmation() {
        guard case .confirming = state else { return }
        state = .needsDownload(sizeBytes: Self.modelBytes, freeBytes: freeSpace(URL(fileURLWithPath: directory)), resumable: resumable)
    }
    public func beginDownload() {
        guard case .confirming = state else { return }
        hasConfirmed = true
        pausedFraction = nil
        let free = freeSpace(URL(fileURLWithPath: directory))
        let needed = Self.modelBytes + Self.reserveBytes
        guard free >= needed else {
            state = .failed(message: "Not enough free disk space. You need 20.2 GB; you are missing \(ModelDisk.gb(needed - free)).", resumable: resumable); return
        }
        guard let bin = binary() else { state = .failed(message: "Strim CLI was not found.", resumable: resumable); return }
        parser = PullJSONParser()
        pendingProcessError = nil
        cancelRequested = false
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self, process] in
            guard let self else { return }
            do {
                let deliveries = DownloadEventDeliveries()
                try await process.run(binary: bin, arguments: ["pull", "--progress-json", "--tier", "4bit", "--dir", directory]) { [weak self] data in
                    let delivery = Task { @MainActor in
                        guard let self, self.activeRunID == runID else { return }
                        self.consume(data)
                    }
                    deliveries.append(delivery)
                }
                guard activeRunID == runID else { return }
                for delivery in deliveries.drain() { await delivery.value }
                guard activeRunID == runID else { return }
                for event in parser.finish() { apply(event) }
                if let (_, message) = pendingProcessError {
                    state = .failed(message: message, resumable: true)
                    resumable = true
                } else if case .failed = state {} else {
                    state = .startingServer; resumable = false
                    if !modelReadyReported { modelReadyReported = true; autostart() }
                }
            } catch {
                guard activeRunID == runID else { return }
                if cancelRequested { return }
                resumable = true
                let message = pendingProcessError?.1 ?? error.localizedDescription
                state = .failed(message: message, resumable: true)
            }
        }
        state = .downloading(.init(file: "Preparing download", doneBytes: 0, totalBytes: Self.modelBytes, bytesPerSec: 0, etaSec: nil))
    }
    public func cancel() {
        if case .downloading(let p) = state { pausedFraction = p.fraction }
        cancelRequested = true; activeRunID = UUID(); process.cancel(); resumable = true; task?.cancel(); task = nil
        state = .needsDownload(sizeBytes: Self.modelBytes, freeBytes: freeSpace(URL(fileURLWithPath: directory)), resumable: true)
    }
    public func retry() {
        guard case .failed = state else { return }
        if hasConfirmed { state = .confirming; beginDownload() }
        else { state = .needsDownload(sizeBytes: Self.modelBytes, freeBytes: freeSpace(URL(fileURLWithPath: directory)), resumable: true) }
    }
    private func consume(_ data: Data) { for event in parser.append(data) { apply(event) } }
    private func apply(_ event: PullJSONEvent) {
        switch event {
        case .plan: break
        case .progress(let p):
            if case .done = state { return }
            if case .failed = state { return }
            state = .downloading(p)
        case .verify(let file):
            if case .done = state { return }
            if case .failed = state { return }
            state = .verifying(file: file)
        case .done:
            if case .failed = state { return }
            state = .done; resumable = false
        case .error(let code, let message): pendingProcessError = (code, message)
        case .ignored: break
        }
    }
}

public enum ModelDisk {
    public static func freeBytes(at url: URL) -> Int64 {
        var path = url.path
        while !FileManager.default.fileExists(atPath: path), path != "/" { path = URL(fileURLWithPath: path).deletingLastPathComponent().path }
        let values = try? FileManager.default.attributesOfFileSystem(forPath: path)
        return (values?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    public static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(max(0, bytes)) / 1_000_000_000) }
    public static func hasRequiredFiles(at root: String) -> Bool {
        let fm = FileManager.default
        let repos = ["qwen38-4bit", "qwen38-mtp-4bit"]
        return repos.allSatisfy { name in
            let path = root + "/" + name
            if fm.fileExists(atPath: path + "/.strim-pull.json") { return true }
            guard fm.fileExists(atPath: path + "/config.json"), let files = try? fm.contentsOfDirectory(atPath: path) else { return false }
            return files.contains { $0.hasSuffix(".safetensors") }
        }
    }
    public static func hasPartialFiles(at root: String) -> Bool {
        for repo in ["qwen38-4bit", "qwen38-mtp-4bit"] {
            let repoPath = root + "/" + repo
            guard let enumerator = FileManager.default.enumerator(atPath: repoPath) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".part") {
                let path = repoPath + "/" + relative
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   ((attrs[.size] as? NSNumber)?.int64Value ?? 0) > 0 { return true }
            }
        }
        return false
    }
}

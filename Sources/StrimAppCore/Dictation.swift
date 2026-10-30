import Foundation

// Dictation inside the Strim chat composer. On-device only (Speech framework, macOS 26+); no system-wide hotkey and no
// Accessibility permission. The model-facing wiring is AppModel+Dictation.swift; the real engine is SpeechDictation.swift.

public enum DictationError: Equatable, Sendable {
    case needsNewerOS
    case microphoneDenied
    case microphoneRestricted
    case languageUnsupported(String)
    case failed(String)

    public var message: String {
        switch self {
        case .needsNewerOS: "Dictation needs macOS 26 or later."
        case .microphoneDenied: "Microphone access is off for Strim. Allow it in System Settings > Privacy & Security > Microphone."
        case .microphoneRestricted: "Microphone access is restricted on this Mac (for example by a profile)."
        case .languageUnsupported(let id): "Dictation does not support the language “\(id)” on this Mac."
        case .failed(let why): "Dictation stopped: \(why)"
        }
    }
    /// The message comes with a button that opens the Microphone pane of System Settings.
    public var offersSettings: Bool { self == .microphoneDenied }
}

public enum DictationState: Equatable, Sendable {
    case idle
    /// Asking for the microphone, or installing the on-device language assets.
    case preparing
    case listening
    case error(DictationError)

    /// A session is (being) set up or running.
    public var isActive: Bool { self == .preparing || self == .listening }
    public var error: DictationError? { if case .error(let e) = self { e } else { nil } }
}

public enum DictationEvent: Equatable, Sendable {
    case state(DictationState)
    /// The best guess so far for the phrase being spoken. Replaces the previous partial.
    case partial(String)
    /// The recogniser committed this phrase; it is appended and the partial is cleared.
    case final(String)
}

/// A speech-to-text source. `start` and `stop` return at once; everything comes back through `onEvent` on the main actor.
/// After `stop` the source may still deliver a last `final`, then `.state(.idle)`.
@MainActor
public protocol Dictation: AnyObject {
    var onEvent: (@MainActor (DictationEvent) -> Void)? { get set }
    func start()
    func stop()
}

public enum DictationInfo {
    public static let shortcut = "⇧⌘D"
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
}

/// The draft while dictating: what was typed before (`base`), the phrases the recogniser committed, and the live partial.
/// Dictated text always goes after the base, never into the middle, and is never sent by itself.
public struct DictationText: Equatable, Sendable {
    public private(set) var base = ""
    public private(set) var committed = ""
    public private(set) var partial = ""
    /// What the recogniser last said, unstripped, and the part of it the user already has in the draft (see `userEdited`).
    private var rawPartial = ""
    private var suppressed = ""

    public init(base: String = "") { self.base = base }

    /// The draft as it should read now.
    public var composed: String {
        let spoken = [committed, partial].filter { !$0.isEmpty }.joined(separator: " ")
        if spoken.isEmpty { return base }
        guard let last = base.last else { return spoken }
        return last.isWhitespace ? base + spoken : base + " " + spoken
    }

    public mutating func begin(base: String) { self = DictationText(base: base) }
    public mutating func setPartial(_ text: String) {
        rawPartial = Self.clean(text)
        partial = strip(rawPartial)
    }
    public mutating func commit(_ text: String) {
        let t = strip(Self.clean(text))
        suppressed = ""
        rawPartial = ""
        if !t.isEmpty { committed = committed.isEmpty ? t : committed + " " + t }
        partial = ""
    }
    /// The user typed while dictating: what is in the field now becomes the new base and dictation continues after it.
    /// Returns true when it was a real edit.
    @discardableResult
    public mutating func userEdited(_ draft: String) -> Bool {
        guard draft != composed else { return false }
        let inFlight = rawPartial
        begin(base: draft)
        suppressed = inFlight   // the recogniser keeps extending that phrase; its words are already in `draft`
        return true
    }

    /// Drops the already-shown prefix from the recogniser's phrase. Words are compared case-insensitively and without
    /// punctuation, so "Hello, world." matches "hello world"; a word must match whole ("worldwide" is not "world").
    private func strip(_ s: String) -> String {
        let want = Self.words(suppressed)
        let got = Self.words(s)
        guard !want.isEmpty, got.count >= want.count else { return s }
        for (w, g) in zip(want, got) where w.text.caseInsensitiveCompare(g.text) != .orderedSame { return s }   // finals get capitalised
        let end = got[want.count - 1].end
        return String(s[end...].drop(while: { $0.isWhitespace || $0.isPunctuation }))
    }

    /// Maximal runs of letters and digits, with the index just past each.
    private static func words(_ s: String) -> [(text: String, end: String.Index)] {
        var out: [(text: String, end: String.Index)] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i].isLetter || s[i].isNumber else { i = s.index(after: i); continue }
            let start = i
            while i < s.endIndex, s[i].isLetter || s[i].isNumber { i = s.index(after: i) }
            out.append((String(s[start..<i]), i))
        }
        return out
    }

    private static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides when to stop listening: ~2 s of quiet after speech, or a longer quiet stretch when nothing was said.
/// Fed the RMS level (0...1) of each audio buffer with that buffer's duration in seconds.
public struct SilenceGate: Equatable, Sendable {
    public var threshold: Float
    public var silenceLimit: Double
    public var noSpeechLimit: Double
    public private(set) var heardSpeech = false
    public private(set) var quiet = 0.0

    public init(threshold: Float = 0.01, silenceLimit: Double = 2, noSpeechLimit: Double = 8) {
        self.threshold = threshold; self.silenceLimit = silenceLimit; self.noSpeechLimit = noSpeechLimit
    }
    /// True when listening should end.
    public mutating func feed(rms: Float, duration: Double) -> Bool {
        if rms > threshold { heardSpeech = true; quiet = 0; return false }
        quiet += duration
        return quiet + 1e-9 >= (heardSpeech ? silenceLimit : noSpeechLimit)   // buffer durations are not exact binary sums
    }
}

/// Scriptable `Dictation` for tests and snapshots: no microphone, no Speech framework.
@MainActor
public final class FakeDictation: Dictation {
    public var onEvent: (@MainActor (DictationEvent) -> Void)?
    /// Delivered by `start()` / `stop()`.
    public var onStart: [DictationEvent] = [.state(.listening)]
    public var onStop: [DictationEvent] = [.state(.idle)]
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    public init() {}
    public func start() { startCount += 1; onStart.forEach(emit) }
    public func stop() { stopCount += 1; onStop.forEach(emit) }
    /// Deliver an event as the engine would.
    public func emit(_ e: DictationEvent) { onEvent?(e) }
}

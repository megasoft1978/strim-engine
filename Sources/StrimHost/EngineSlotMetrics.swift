import Foundation
import StrimEngine

/// Throughput counters fed from the `Usage` of every finished generation (exponentially weighted averages).
public struct EngineMetricsSnapshot: Sendable, Equatable {
    public var decodeTPS = 0.0
    public var prefillTPS = 0.0
    /// EWMA of the MTP draft acceptance rate (0 until an MTP request ran).
    public var mtpAcceptance = 0.0
    /// EWMA of tokens emitted per verify pass (0 without MTP); 1 + accepted drafts per pass.
    public var mtpDepth = 0.0
    /// Cached prompt tokens / prompt tokens, cumulative since the host started.
    public var prefixHitRate = 0.0
    /// Cached prompt tokens / prefill tokens-per-second EWMA: prefill time the cache saved.
    public var savedPrefillSeconds = 0.0
    public var requests = 0
    public var completionTokens = 0
    /// Completion tokens since local midnight.
    public var tokensToday = 0
    public init() {}
}

public final class EngineMeter: @unchecked Sendable {
    public static let alpha = 0.2
    private let lock = NSLock()
    private var s = EngineMetricsSnapshot()
    private var promptTotal = 0
    private var cachedTotal = 0
    private var saved = 0.0
    private var day: Date
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        day = Calendar.current.startOfDay(for: now())
    }

    private func ewma(_ cur: Double, _ x: Double) -> Double { cur == 0 ? x : cur + Self.alpha * (x - cur) }

    public func record(_ u: Usage) {
        lock.withLock {
            let today = Calendar.current.startOfDay(for: now())
            if today != day { day = today; s.tokensToday = 0 }
            s.requests += 1
            s.completionTokens += u.completionTokens
            s.tokensToday += u.completionTokens
            if u.decodeSeconds > 0, u.completionTokens > 0 {
                s.decodeTPS = ewma(s.decodeTPS, Double(u.completionTokens) / u.decodeSeconds)
            }
            let fresh = max(u.promptTokens - u.cachedTokens, 0)
            if u.prefillSeconds > 0, fresh > 0 {
                s.prefillTPS = ewma(s.prefillTPS, Double(fresh) / u.prefillSeconds)
            }
            if let a = u.mtpAccept { s.mtpAcceptance = ewma(s.mtpAcceptance, a) }
            if u.mtpPasses > 0 { s.mtpDepth = ewma(s.mtpDepth, Double(u.completionTokens) / Double(u.mtpPasses)) }
            promptTotal += u.promptTokens; cachedTotal += u.cachedTokens
            s.prefixHitRate = promptTotal > 0 ? Double(cachedTotal) / Double(promptTotal) : 0
            if s.prefillTPS > 0 { saved += Double(u.cachedTokens) / s.prefillTPS }
            s.savedPrefillSeconds = saved
        }
    }

    public func snapshot() -> EngineMetricsSnapshot {
        lock.withLock {
            var out = s
            if Calendar.current.startOfDay(for: now()) != day { out.tokensToday = 0 }
            return out
        }
    }
}

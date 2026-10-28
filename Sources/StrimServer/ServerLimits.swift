import Foundation

/// Caps on client-controlled values and queue sizes, read once from the environment. Every default leaves the
/// benchmark workloads (4-8 clients, 32K prompts, 16 MiB bodies) untouched; see docs/CONTROL-API.md.
public enum ServerLimits {
    static func env(_ name: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name], let v = Int(raw) else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// `STRIM_MAX_OUTPUT_TOKENS`: ceiling for any requested output length (clamped, not rejected).
    public static let maxOutputTokens = env("STRIM_MAX_OUTPUT_TOKENS", 1 << 20, 1 ... (1 << 24))
    /// `STRIM_BACKGROUND_MAX_TOKENS`: output ceiling for background-class requests (applies with or without ignore_eos).
    public static let backgroundMaxTokens = env("STRIM_BACKGROUND_MAX_TOKENS", 32768, 1 ... (1 << 24))
    /// `STRIM_MAX_QUEUE`: admission waiters allowed beyond the running ones before new requests get 429.
    public static let maxQueuedRequests = env("STRIM_MAX_QUEUE", 64, 1 ... 100_000)
    /// `STRIM_QUEUE_TIMEOUT_S`: longest a request waits for an admission slot before 503 + Retry-After.
    public static let queueTimeoutSeconds = env("STRIM_QUEUE_TIMEOUT_S", 600, 1 ... 86_400)
    /// `STRIM_RESPONSE_STORE_MB`: byte budget of the /v1/responses conversation store.
    public static let responseStoreBytes = env("STRIM_RESPONSE_STORE_MB", 64, 1 ... 4096) << 20
    public static let maxStopSequences = 16
    public static let maxStopBytes = 1024
}

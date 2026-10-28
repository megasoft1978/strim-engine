import Foundation
import MLX

public struct ModelID: Hashable, Sendable {
    public let repo: String
    public let revision: String
    public init(repo: String, revision: String) { self.repo = repo; self.revision = revision }
    public static let qwen38_27b = ModelID(repo: "mlx-community/Qwen3.8-27B-4bit", revision: "main")
}

public enum Quantization: Int, Sendable, CaseIterable {
    case q4 = 4
    case q6 = 6
    case q8 = 8
}

public struct RuntimeConfig: Sendable {
    public var model: ModelID
    public var quant: Quantization
    public var contextTokens: Int
    public var prefillStep: Int
    public var mtpDepth: Int
    public var wiredLimitGB: Int

    public init(model: ModelID = .qwen38_27b, quant: Quantization = .q4,
                contextTokens: Int = 65_536, prefillStep: Int = 2_048,
                mtpDepth: Int = 3, wiredLimitGB: Int = 44) {
        self.model = model; self.quant = quant; self.contextTokens = contextTokens
        self.prefillStep = prefillStep; self.mtpDepth = mtpDepth; self.wiredLimitGB = wiredLimitGB
    }
    public static let measuredSpeed = RuntimeConfig()
    public static let measuredQuality = RuntimeConfig(quant: .q8, contextTokens: 32_768)
}

/// Optional MLX wired (residency-set) limit. `STRIM_WIRED_LIMIT_GB=N` (unset or 0 = off, the MLX default of 0
/// = no allocation is pinned). Applied once, before the first weight load, through a never-ended
/// `WiredMemoryManager` ticket (sum policy over a zero baseline = N GiB). Never changes the system sysctl.
public enum WiredLimit {
    nonisolated(unsafe) private static var done = false
    private static let lock = NSLock()
    public static var envGB: Int? {
        guard let s = ProcessInfo.processInfo.environment["STRIM_WIRED_LIMIT_GB"], let v = Int(s), v > 0 else { return nil }
        return v
    }
    @discardableResult
    public static func applyFromEnvOnce() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !done, let gb = envGB else { return nil }
        done = true
        let ticket = WiredMemoryTicket(size: gb << 30, policy: WiredSumPolicy(), kind: .active)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var applied = 0
        Task.detached { applied = await ticket.start(); sem.signal() }
        sem.wait()
        FileHandle.standardError.write(Data("wired limit: requested \(gb) GiB, applied \(applied >> 20) MiB\n".utf8))
        return applied
    }
}

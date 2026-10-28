import Foundation
import StrimCore

/// Memory admission math. Bytes are estimates of what a request pins; the engine rejects a
/// request that cannot fit instead of letting Metal run out of memory.
public enum MemoryModel {
    /// Attention KV: 16 layers x (K+V) x 4 kv-heads x 256 dim x 2 bytes.
    public static let kvBytesPerToken = 64 * 1024
    /// MTP head KV: 1 layer, same geometry.
    public static let mtpBytesPerToken = 4 * 1024
    /// GDN state per sequence: ssm 48 layers x 3 MiB = 144 MiB, plus conv 48 x 61 KB = 3 MiB
    /// (owned 3-row buffer; see GDN.forward).
    public static let gdnBytesPerSequence = (144 + 3) << 20
    /// One prefill chunk's transient (measured 760-855 MiB at 1K-4K positions); reserved once
    /// because the scheduler runs one work unit at a time.
    public static let workspaceBytes = 800 << 20
    /// Resident weights are ~0.95x the safetensors bytes (MTP head included).
    public static let weightResidentFactor = 0.95
    /// MLX buffer-cache limit (EngineConfig.mlxCacheLimitBytes default); the cache fills to it.
    public static let defaultMlxCacheBytes = 4 << 30
    /// Upper bound of the trie budget (see `plan`). Trie accounting is honest (~215 MiB per 1024-token node, within
    /// ~5% of real), so 12 GiB holds 57 nodes = 58K tokens.
    public static let defaultPrefixCacheBytes = PrefixStore.defaultBudgetMB << 20
    /// Default share of RAM the whole engine (weights + trie + MLX cache + live state) may use.
    /// 50%: the machine also runs other apps, and a footprint past that point starts swapping them.
    /// `STRIM_MEM_FRACTION` raises it; `STRIM_MEM_BUDGET_GB` sets it absolutely.
    public static let defaultRamFraction = 0.50
    /// Default admission budget: half of RAM (32 GiB on a 64 GB machine).
    public static func defaultBudgetBytes(physicalMemory: UInt64, fraction: Double = defaultRamFraction) -> Int {
        Int(Double(physicalMemory) * fraction)
    }

    /// Live-request headroom reserved before sizing the trie (a few 16K sequences).
    public static let requestReserveBytes = 6 << 30

    public struct Plan: Equatable, Sendable {
        public var budget: Int
        public var prefix: Int
        public var mlxCache: Int
    }

    /// Memory plan scaled to the machine. Budget: `fraction` of RAM, but at least weights + 8 GiB
    /// (capped at 80% of RAM) so a 32/36 GB Mac can still run. MLX buffer cache: budget/32 (1 GiB at
    /// 32 GiB). Trie: what is left after weights, cache, one chunk transient and the request reserve,
    /// at most budget/5 and 12 GiB, at least 1 GiB.
    public static func plan(physicalMemory: UInt64, weightFileBytes: Int, fraction: Double = defaultRamFraction) -> Plan {
        let ram = Double(physicalMemory)
        let weights = Int(Double(weightFileBytes) * weightResidentFactor)
        let budget = max(Int(ram * fraction), min(weights + (8 << 30), Int(ram * 0.8)))
        let cache = min(defaultMlxCacheBytes, max(256 << 20, budget / 32))
        let room = budget - weights - cache - workspaceBytes - requestReserveBytes
        let prefix = min(defaultPrefixCacheBytes, budget / 5, max(1 << 30, room))
        return Plan(budget: budget, prefix: prefix, mlxCache: cache)
    }

    /// Always-resident bytes: weights + trie budget + MLX buffer-cache limit. The chunk
    /// transient (`workspaceBytes`) is added by `Admission.decide`.
    public static func fixedBytes(weightFileBytes: Int, prefixBytes: Int, mlxCacheBytes: Int?) -> Int {
        Int(Double(weightFileBytes) * weightResidentFactor) + prefixBytes + (mlxCacheBytes ?? defaultMlxCacheBytes)
    }

    /// Saturating: a client-controlled token count must never trap the host. Overflow (or a negative count)
    /// yields `Int.max` / the sequence floor, which admission then rejects as insufficient memory.
    public static func requestBytes(tokens: Int, mtp: Bool) -> Int {
        let perToken = kvBytesPerToken + (mtp ? mtpBytesPerToken : 0)
        let (kv, kvOverflow) = max(0, tokens).multipliedReportingOverflow(by: perToken)
        let (total, totalOverflow) = kv.addingReportingOverflow(gdnBytesPerSequence)
        return kvOverflow || totalOverflow ? Int.max : total
    }

    /// `a + b` clamped to `Int.max` (token counts from clients).
    public static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.max : Int.min) : sum
    }

    public static func hotSessionBytes(tokens: Int, mtp: Bool) -> Int {
        requestBytes(tokens: tokens, mtp: mtp)
    }
}

public struct AdmissionDecision: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case admit
        case reject(needed: Int, available: Int)
    }
    public var outcome: Outcome
    /// Hot sessions to demote (oldest first) before admitting.
    public var evictHot: [UInt64]
}

public enum Admission {
    /// - budget: total bytes the engine may use (weights + trie + live state).
    /// - fixed: `MemoryModel.fixedBytes` (weights + trie budget + MLX cache limit).
    /// - active: bytes already admitted to running requests.
    /// - hot: (session raw id, bytes) of resident hot sessions, oldest first.
    /// - protect: a hot session the new request will reuse (never evicted for itself).
    public static func decide(budget: Int, fixed: Int, active: Int, hot: [(id: UInt64, bytes: Int)],
                              needed: Int, protect: UInt64? = nil) -> AdmissionDecision {
        let hotTotal = hot.reduce(0) { $0 + $1.bytes }
        var used = fixed + active + hotTotal + MemoryModel.workspaceBytes
        // `needed` may be Int.max (saturated request size): compare by subtraction, never `used + needed`.
        var evict: [UInt64] = []
        for h in hot where needed > budget - used && h.id != protect {
            evict.append(h.id); used -= h.bytes
        }
        if needed > budget - used {
            return AdmissionDecision(outcome: .reject(needed: needed, available: budget - used), evictHot: [])
        }
        return AdmissionDecision(outcome: .admit, evictHot: evict)
    }
}

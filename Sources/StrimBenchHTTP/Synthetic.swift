import Foundation

/// Python's `random.Random(seed)` (MT19937) for the calls the synthetic fixture generator uses:
/// `choice`, `randint`, `randrange`. Bit-exact with CPython (`getrandbits` + `_randbelow`).
public struct PyRandom {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var idx = 625

    public init(seed: Int) {
        // random.seed(int): key = abs(n) as little-endian 32-bit words, init_by_array.
        var key: [UInt32] = []
        var n = UInt64(abs(seed))
        if n == 0 { key = [0] }
        while n > 0 { key.append(UInt32(truncatingIfNeeded: n)); n >>= 32 }
        initGenrand(19650218)
        var i = 1, j = 0
        var k = max(624, key.count)
        while k > 0 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1664525)) &+ key[j] &+ UInt32(j)
            i += 1; j += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            if j >= key.count { j = 0 }
            k -= 1
        }
        k = 623
        while k > 0 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1566083941)) &- UInt32(i)
            i += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            k -= 1
        }
        mt[0] = 0x8000_0000
        idx = 624
    }

    private mutating func initGenrand(_ s: UInt32) {
        mt[0] = s
        for i in 1 ..< 624 { mt[i] = 1812433253 &* (mt[i - 1] ^ (mt[i - 1] >> 30)) &+ UInt32(i) }
        idx = 624
    }

    private mutating func nextUInt32() -> UInt32 {
        if idx >= 624 {
            for kk in 0 ..< 624 {
                let y = (mt[kk] & 0x8000_0000) | (mt[(kk + 1) % 624] & 0x7fff_ffff)
                var v = mt[(kk + 397) % 624] ^ (y >> 1)
                if y & 1 != 0 { v ^= 0x9908_b0df }
                mt[kk] = v
            }
            idx = 0
        }
        var y = mt[idx]
        idx += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9d2c_5680
        y ^= (y << 15) & 0xefc6_0000
        y ^= y >> 18
        return y
    }

    private mutating func getrandbits(_ k: Int) -> UInt32 { nextUInt32() >> UInt32(32 - k) }

    /// Uniform in [0, n).
    public mutating func randbelow(_ n: Int) -> Int {
        let k = Int.bitWidth - n.leadingZeroBitCount
        var r = Int(getrandbits(k))
        while r >= n { r = Int(getrandbits(k)) }
        return r
    }

    public mutating func choice<T>(_ a: [T]) -> T { a[randbelow(a.count)] }
    public mutating func randint(_ a: Int, _ b: Int) -> Int { a + randbelow(b - a + 1) }
}

/// Port of agent_replay.py `synthetic_messages` / `write_synthetic`: the deterministic repo-like coding session
/// (one user paste, then assistant tool calls and tool results) used as the 8-turn replay fixture.
public enum SyntheticFixture {
    public static let seed = 20261026
    static let firstChars = 12000, lastChars = 120000
    static let system = "You are a coding agent working inside the strim-engine repository. "
        + "Read the relevant files with the tools before you answer. "
        + "Keep answers short and cite file paths and line numbers. "
        + "Never invent symbols; check them with grep first. "
        + "Prefer minimal, surgical changes and state how you verified them."
    static let paths = [
        "src/engine/attention.py", "src/engine/kv_cache.py", "src/engine/scheduler.py",
        "src/server/http_api.py", "src/server/stream.py", "src/model/gdn_block.py",
        "tests/test_prefix_cache.py", "tests/test_scheduler.py", "tools/checkparity.py",
        "bench/scoreboard.py", "docs/perf_notes.md", "config/engine.toml",
    ]
    static let words = [
        "prefill", "decode", "cache", "block", "stride", "token", "batch", "slot", "budget", "trie",
        "logits", "layer", "norm", "head", "state", "chunk", "queue", "lease", "evict", "prefix",
    ]
    static let notes = [
        "Reading the module to locate the prefix cache lookup.",
        "Checking how the scheduler hands off decode slots.",
        "Grepping for the block budget accounting before editing.",
        "Looking at the stream handler to see where usage is reported.",
    ]

    static func ident(_ r: inout PyRandom) -> String {
        let a = r.choice(words)
        let b = r.choice(words)
        return a + "_" + b
    }

    static func repoText(_ r: inout PyRandom, _ nchars: Int) -> String {
        var parts: [String] = []
        var total = 0
        while total < nchars {
            var lines = ["# file: \(r.choice(paths))"]
            for _ in 0 ..< r.randint(6, 18) {
                switch r.randbelow(4) {
                case 0:
                    let a = ident(&r), b = ident(&r), n = r.randint(1, 4096)
                    lines.append("def \(a)(\(b), n=\(n)):")
                case 1:
                    let a = ident(&r), b = ident(&r), n = r.randint(1, 512)
                    let w1 = r.choice(words), w2 = r.choice(words)
                    lines.append("    \(a) = \(b)(\(n))  # \(w1) \(w2)")
                case 2:
                    let a = ident(&r), n = r.randint(1, 65536), b = ident(&r)
                    lines.append("    if \(a) > \(n): return \(b)")
                default:
                    lines.append("")
                }
            }
            let block = lines.joined(separator: "\n") + "\n"
            parts.append(block)
            total += block.unicodeScalars.count
        }
        return String(String.UnicodeScalarView(parts.joined().unicodeScalars.prefix(nchars)))
    }

    public static func messages(turns: Int = 6, seed: Int = seed) throws -> [JSONValue] {
        guard (Replay.minTurns ... Replay.maxTurns).contains(turns) else {
            throw BenchError("synthetic turns must be \(Replay.minTurns)-\(Replay.maxTurns)")
        }
        var rng = PyRandom(seed: seed)
        let overhead = 300
        let step = Double(lastChars - firstChars) / Double(turns - 1)
        var msgs: [JSONValue] = [.obj(["role": "system", "content": .string(system)])]
        let task = "Task: find why the prefix cache misses after the second turn and propose a fix.\n\n"
        let first = repoText(&rng, firstChars - system.unicodeScalars.count - task.unicodeScalars.count)
        msgs.append(.obj(["role": "user", "content": .string(task + first)]))
        for k in 1 ..< turns {
            let name: String
            let args: JSONValue
            if k % 2 == 1 {
                name = "read_file"
                args = .obj(["path": .string(rng.choice(paths))])
            } else {
                name = "grep"
                let pattern = ident(&rng)
                args = .obj(["path": "src", "pattern": .string(pattern)])  // sort_keys=True
            }
            let cid = String(format: "call_%03d", k)
            let note = rng.choice(notes)
            msgs.append(.obj([
                "role": "assistant", "content": .string(note),
                "tool_calls": .array([.obj([
                    "id": .string(cid), "type": "function",
                    "function": .obj(["name": .string(name), "arguments": .string(JSON.dumps(args))]),
                ])]),
            ]))
            msgs.append(.obj(["role": "tool", "tool_call_id": .string(cid),
                              "content": .string(repoText(&rng, max(200, Int(step) - overhead)))]))
        }
        msgs.append(.obj(["role": "assistant",
                          "content": "Findings: the cache key changes when the system prompt head changes, so lookups miss."]))
        return msgs
    }

    /// `json.dumps(msgs, indent=1, ensure_ascii=False) + "\n"`
    public static func render(_ msgs: [JSONValue]) -> String { JSON.dumps(.array(msgs), indent: 1, ensureASCII: false) + "\n" }

    @discardableResult
    public static func write(path: String, turns: Int) throws -> [JSONValue] {
        let msgs = try messages(turns: turns)
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        try render(msgs).write(toFile: path, atomically: false, encoding: .utf8)
        return msgs
    }
}

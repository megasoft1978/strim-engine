import CryptoKit
import Darwin
import Foundation
import MLX

/// Opt-in, disk-persisted spill of prefix-trie nodes (`STRIM_PREFIX_DISK=1`, default OFF).
///
/// One file per trie node under `<root>/<model fingerprint>/<key>-<parent>.spd`:
///   "STRIMPD1" | u32 header length | JSON header | raw tensor bytes | SHA-256 of everything before it.
/// The tensors are exactly the node's in-memory arrays (KV delta, GDN conv/ssm, MTP block), so a restored
/// node is bit-identical to the node that was spilled and a hit stays exact.
///
/// Privacy: a file holds tensors and a 256-bit hash chain only. Token ids are never written; the key of
/// block i is SHA-256(fingerprint | key of block i-1 | block tokens), so a prompt can be confirmed by
/// someone who already has it but not recovered. The cache dir is 0700 and files are 0600.
///
/// Threading: all trie/MLX access stays on the caller's thread. A serial utility queue only writes bytes
/// that were captured (and kept alive) at enqueue time; verification of files on load runs concurrently
/// but touches no MLX object.
public final class PrefixDisk: @unchecked Sendable {
    /// Bump when the file layout changes.
    public static let formatVersion = 1
    /// Bump when prefill arithmetic or KV/GDN/MTP layouts change: old files then never match.
    public static let engineRev = "strim-prefix-disk-r2"
    public static let defaultBudgetBytes = 20 << 30
    public static let defaultFloorBytes = 20 << 30
    public static let defaultPendingCap = 384 << 20
    /// Longest the engine thread waits for the writer before leaving a node memory-only.
    static let maxStall = 5.0
    static let magic = Array("STRIMPD1".utf8)

    public struct Stats: Sendable, Equatable {
        public var files = 0, bytes = 0
        public var spilled = 0, spilledBytes = 0
        public var stalls = 0, stallSeconds = 0.0
        public var skippedBusy = 0, skippedFloor = 0, skippedOrphan = 0, writeErrors = 0
        public var loadedNodes = 0, loadedBytes = 0, loadSeconds = 0.0
        public var corrupt = 0, evicted = 0
    }

    struct Entry { var size: Int; var mtime: Date; var parent: String }

    struct TensorInfo: Codable { var n: String; var d: String; var s: [Int]; var o: Int; var l: Int }
    struct Header: Codable {
        var v: Int
        var rev: String
        var fp: String
        var key: String
        var parent: String
        var depth: Int
        var end: Int
        var mtpStart: Int?
        var tensors: [TensorInfo]
    }

    /// A file whose checksum and header passed; tensors are built by `PrefixDisk.makeNode` on the caller's thread.
    struct VerifiedFile {
        let header: Header
        let data: Data          // mapped file
        let payloadStart: Int
        var bytes: Int { header.tensors.reduce(0) { $0 + $1.l } }
    }

    public let dir: URL
    public let fingerprint: String
    public let budgetBytes: Int
    public let floorBytes: Int
    public let pendingCap: Int
    public let rootKey = Data(count: 32)
    private let fpData: Data
    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var total = 0
    private var inflight: Set<String> = []
    private var pending = 0
    private var _stats = Stats()
    private let queue = DispatchQueue(label: "strim.prefix-disk", qos: .utility)

    public var stats: Stats { lock.withLock { var s = _stats; s.files = index.count; s.bytes = total; return s } }

    // MARK: setup

    /// nil unless `STRIM_PREFIX_DISK=1` (zero overhead and zero files otherwise).
    /// `STRIM_PREFIX_DISK_DIR` (default `~/.strim/cache`), `STRIM_PREFIX_DISK_GB` (20), `STRIM_PREFIX_DISK_FLOOR_GB` (20).
    public static func fromEnvironment(modelDir: String, headDir: String?, policy: CutPolicy,
                                       env: [String: String] = ProcessInfo.processInfo.environment) -> PrefixDisk? {
        guard env["STRIM_PREFIX_DISK"] == "1" else { return nil }
        let root = env["STRIM_PREFIX_DISK_DIR"].map { ($0 as NSString).expandingTildeInPath } ?? defaultRoot
        let gb = Double(env["STRIM_PREFIX_DISK_GB"] ?? "") ?? 20
        let floor = Double(env["STRIM_PREFIX_DISK_FLOOR_GB"] ?? "") ?? 20
        let fp = fingerprint(modelDir: modelDir, headDir: headDir, policy: policy)
        do {
            return try PrefixDisk(root: URL(fileURLWithPath: root), fingerprint: fp,
                                  budgetBytes: Int(gb * 1_073_741_824), floorBytes: Int(floor * 1_073_741_824))
        } catch {
            FileHandle.standardError.write(Data("prefix disk cache disabled: \(error)\n".utf8))
            return nil
        }
    }

    public static var defaultRoot: String { NSHomeDirectory() + "/.strim/cache" }

    /// Model + head file identity (config bytes, safetensors names, sizes, mtimes), cut policy, format and engine revision.
    /// Any change gives a new directory, so files from another model, quantization or engine build are never read.
    public static func fingerprint(modelDir: String, headDir: String?, policy: CutPolicy) -> String {
        var h = SHA256()
        func add(_ s: String) { h.update(data: Data(s.utf8)); h.update(data: Data([0])) }
        add("v\(formatVersion)"); add(engineRev)
        add("policy \(policy.maxBlock) \(policy.minBlock) \(policy.boundary.map(String.init) ?? "-") \(policy.assistant.map(String.init) ?? "-") \(policy.assistantMin) \(policy.tailFloor) \(policy.tailMergeMax)")
        for (tag, d) in [("model", modelDir as String?), ("head", headDir)] {
            guard let d else { add("\(tag) none"); continue }
            add(tag)
            // Parsed per-tensor quant spec hash: a cached prefix from another quantization is never reused.
            add("quant \(((try? QuantConfig.load(dir: URL(fileURLWithPath: d))) ?? nil)?.fingerprint ?? "none")")
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: d)) ?? []).sorted()
            for n in names where n == "config.json" || n.hasSuffix(".safetensors") || n == "model.safetensors.index.json" {
                let p = d + "/" + n
                let attrs = try? fm.attributesOfItem(atPath: p)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                let mt = Int64(((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
                add("\(n) \(size) \(mt)")
                if n == "config.json", let c = fm.contents(atPath: p) { h.update(data: c) }
            }
        }
        return Data(h.finalize()).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public init(root: URL, fingerprint: String, budgetBytes: Int = defaultBudgetBytes,
                floorBytes: Int = defaultFloorBytes, pendingCap: Int = defaultPendingCap) throws {
        self.fingerprint = fingerprint
        self.fpData = Data(fingerprint.utf8)
        self.budgetBytes = budgetBytes; self.floorBytes = floorBytes; self.pendingCap = pendingCap
        try Self.secureDir(root)
        dir = root.appendingPathComponent(fingerprint, isDirectory: true)
        try Self.secureDir(dir)
        scan()
        lock.withLock { evictLocked(extra: 0) }
    }

    /// Creates `url` (0700) or verifies it is a real directory owned by us, then forces 0700.
    static func secureDir(_ url: URL) throws {
        let fm = FileManager.default
        var st = stat()
        if lstat(url.path, &st) != 0 {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileNoSuchFile) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw NSError(domain: "PrefixDisk", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a directory owned by the current user"])
        }
        if (st.st_mode & 0o777) != 0o700 { chmod(url.path, 0o700) }
    }

    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let now = Date()
        for n in names {
            let p = dir.appendingPathComponent(n).path
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if n.hasSuffix(".tmp") {
                if now.timeIntervalSince(mtime) > 600 { unlink(p) }   // leftover of a crashed write
                continue
            }
            guard let (key, parent) = Self.parseName(n) else { continue }
            index[key] = Entry(size: Int(st.st_size), mtime: mtime, parent: parent)
            total += Int(st.st_size)
        }
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func fileName(key: String, parent: String) -> String { "\(key)-\(parent.prefix(16)).spd" }
    static func parseName(_ n: String) -> (key: String, parent: String)? {
        guard n.hasSuffix(".spd") else { return nil }
        let parts = n.dropLast(4).split(separator: "-")
        guard parts.count == 2, parts[0].count == 64, parts[1].count == 16,
              parts.allSatisfy({ $0.allSatisfy { $0.isHexDigit } }) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
    private func path(_ key: String, parent: String) -> String { dir.appendingPathComponent(Self.fileName(key: key, parent: parent)).path }

    // MARK: keys

    public func key(parent: Data, tokens: ArraySlice<Int32>) -> Data {
        var h = SHA256()
        h.update(data: fpData); h.update(data: parent)
        tokens.withUnsafeBufferPointer { h.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        return Data(h.finalize())
    }

    /// True when the file for `key` exists in the index (written, not merely queued).
    public func has(_ key: Data) -> Bool { lock.withLock { index[Self.hex(key)] != nil } }

    func touch(_ key: Data) {
        let k = Self.hex(key)
        let p: String? = lock.withLock {
            guard var e = index[k] else { return nil }
            e.mtime = Date(); index[k] = e
            return path(k, parent: e.parent)
        }
        if let p { queue.async { utimes(p, nil) } }
    }

    /// Blocks until queued writes are on disk (tests, shutdown).
    public func flush() { queue.sync {} }

    // MARK: spill (write-behind)

    private static func dtypeName(_ d: DType) -> String? {
        switch d {
        case .bfloat16: return "bf16"; case .float16: return "f16"; case .float32: return "f32"
        case .uint8: return "u8"; case .int8: return "i8"; case .uint16: return "u16"; case .int16: return "i16"
        case .uint32: return "u32"; case .int32: return "i32"; case .int64: return "i64"; case .uint64: return "u64"
        default: return nil
        }
    }
    private static func dtype(_ n: String) -> DType? {
        switch n {
        case "bf16": return .bfloat16; case "f16": return .float16; case "f32": return .float32
        case "u8": return .uint8; case "i8": return .int8; case "u16": return .uint16; case "i16": return .int16
        case "u32": return .uint32; case "i32": return .int32; case "i64": return .int64; case "u64": return .uint64
        default: return nil
        }
    }

    private struct Job {
        var key: String, parent: String, header: Header
        var datas: [Data]
        var keep: [MLXArray]    // keeps the zero-copy bytes in `datas` alive until written
        var bytes: Int
    }

    /// Captures the node's evaluated tensors (zero-copy when contiguous) and writes them off-thread.
    /// Never blocks: if the writer is behind (`pendingCap`), the free-space floor would be hit, or the
    /// parent has no file, the node is skipped (it simply stays memory-only).
    func spill(_ node: PrefixStore.Node, key: Data, parentKey: Data, force: Bool = false) {
        guard node.hasState else { return }
        let k = Self.hex(key), pk = Self.hex(parentKey)
        var items: [(String, MLXArray)] = []
        for l in node.k.keys.sorted() { items.append(("k.\(l)", node.k[l]!)); items.append(("v.\(l)", node.v[l]!)) }
        for l in node.conv.keys.sorted() { items.append(("conv.\(l)", node.conv[l]!)) }
        for l in node.ssm.keys.sorted() { items.append(("ssm.\(l)", node.ssm[l]!)) }
        if let m = node.mtp { items += [("mtp.k", m.k), ("mtp.v", m.v), ("mtp.h", m.hidden)] }
        var infos: [TensorInfo] = []
        var datas: [Data] = []
        var off = 0
        for (n, a) in items {
            guard let d = Self.dtypeName(a.dtype) else { return }
            let raw = a.asData(access: .noCopyIfContiguous)
            infos.append(TensorInfo(n: n, d: d, s: raw.shape, o: off, l: raw.data.count))
            datas.append(raw.data); off += raw.data.count
        }
        let size = off
        // Bounded back-pressure: if the writer still holds more than `pendingCap`, wait for it (a node write is ~0.1-0.3 s)
        // rather than leave a hole in the chain; give up after `maxStall` and keep the node memory-only.
        let t0 = Date()
        var waited = false
        var admit = false
        while true {
            var retry = false
            admit = lock.withLock {
                if !force, index[k] != nil || inflight.contains(k) { return false }
                if parentKey != rootKey, index[pk] == nil, !inflight.contains(pk) { _stats.skippedOrphan += 1; return false }
                if pending > 0, pending + size > pendingCap {
                    if Date().timeIntervalSince(t0) > Self.maxStall { _stats.skippedBusy += 1; return false }
                    retry = true; return false
                }
                if waited { _stats.stalls += 1; _stats.stallSeconds += Date().timeIntervalSince(t0) }
                pending += size; inflight.insert(k)
                return true
            }
            if !retry { break }
            waited = true; usleep(2000)
        }
        guard admit else { return }
        let header = Header(v: Self.formatVersion, rev: Self.engineRev, fp: fingerprint, key: k, parent: pk,
                            depth: node.depth, end: node.end, mtpStart: node.mtp.map { $0.start }, tensors: infos)
        let job = Job(key: k, parent: pk, header: header, datas: datas, keep: items.map { $0.1 }, bytes: size)
        queue.async { [self] in
            write(job)
            lock.withLock { pending -= job.bytes; inflight.remove(job.key) }
        }
    }

    private func freeBytes() -> Int {
        var s = statfs()
        guard statfs(dir.path, &s) == 0 else { return 0 }
        return Int(s.f_bavail) * Int(s.f_bsize)
    }

    private func write(_ job: Job) {
        guard let hdr = try? JSONEncoder().encode(job.header) else { return }
        let size = 8 + 4 + hdr.count + job.bytes + 32
        // Budget, then free-space floor: evict our own LRU leaves first, never fill the disk.
        let ok: Bool = lock.withLock {
            if let old = index[job.key] { total -= old.size; index[job.key] = nil; unlink(path(job.key, parent: old.parent)) }
            evictLocked(extra: size)
            if total + size > budgetBytes { _stats.skippedFloor += 1; return false }
            while freeBytes() - size < floorBytes {
                if !evictOneLocked() { _stats.skippedFloor += 1; return false }
            }
            return true
        }
        guard ok else { return }
        let final = path(job.key, parent: job.parent)
        let tmp = dir.appendingPathComponent(".\(job.key.prefix(16))-\(UInt32.random(in: 0 ... .max)).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { lock.withLock { _stats.writeErrors += 1 }; return }
        var h = SHA256()
        var written = 0
        var good = true
        func put(_ d: Data) {
            guard good else { return }
            h.update(data: d)
            d.withUnsafeBytes { raw in
                var p = 0
                while p < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + p, min(raw.count - p, 16 << 20))
                    if n <= 0 { good = false; return }
                    p += n
                }
            }
            written += d.count
        }
        put(Data(Self.magic))
        var len = UInt32(hdr.count).littleEndian
        put(Data(bytes: &len, count: 4))
        put(hdr)
        for d in job.datas { put(d) }
        if good {
            let digest = Data(h.finalize())
            digest.withUnsafeBytes { raw in if Darwin.write(fd, raw.baseAddress!, 32) != 32 { good = false } }
            written += 32
        }
        close(fd)
        guard good, rename(tmp, final) == 0 else {
            unlink(tmp); lock.withLock { _stats.writeErrors += 1 }; return
        }
        lock.withLock {
            index[job.key] = Entry(size: written, mtime: Date(), parent: job.parent)
            total += written
            _stats.spilled += 1; _stats.spilledBytes += written
        }
    }

    // MARK: eviction (LRU, leaves first)

    @discardableResult
    private func evictOneLocked() -> Bool {
        var parents = Set<String>()
        for e in index.values { parents.insert(e.parent) }
        // A file is a leaf when no other file names it as parent (compared on the 16-hex prefix).
        var victim: (String, Entry)? = nil
        for (k, e) in index where !parents.contains(String(k.prefix(16))) {
            if victim == nil || e.mtime < victim!.1.mtime { victim = (k, e) }
        }
        if victim == nil { for (k, e) in index where victim == nil || e.mtime < victim!.1.mtime { victim = (k, e) } }
        guard let (k, e) = victim else { return false }
        unlink(path(k, parent: e.parent))
        index[k] = nil; total -= e.size; _stats.evicted += 1
        return true
    }

    private func evictLocked(extra: Int) {
        while total + extra > budgetBytes, evictOneLocked() {}
    }

    private func drop(_ key: String, corrupt: Bool) {
        lock.withLock {
            guard let e = index[key] else { return }
            unlink(path(key, parent: e.parent))
            index[key] = nil; total -= e.size
            if corrupt { _stats.corrupt += 1 }
        }
    }

    // MARK: load

    /// Reads and verifies the files for `keys` (in chain order), concurrently. Returns the longest verified prefix;
    /// a corrupt, truncated, or version-mismatched file is deleted and ends the chain.
    func readVerified(_ keys: [Data]) -> [VerifiedFile] {
        let hexes = keys.map(Self.hex)
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var r: [VerifiedFile?]
            init(r: [VerifiedFile?]) { self.r = r }
        }
        let box = Box(r: [VerifiedFile?](repeating: nil, count: hexes.count))
        DispatchQueue.concurrentPerform(iterations: hexes.count) { i in
            let f = verify(hexes[i])
            box.lock.withLock { box.r[i] = f }
        }
        var out: [VerifiedFile] = []
        for r in box.r { guard let r else { break }; out.append(r) }
        return out
    }

    private func verify(_ k: String) -> VerifiedFile? {
        guard let parent = lock.withLock({ index[k]?.parent }) else { return nil }
        let p = path(k, parent: parent)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p), options: .alwaysMapped) else {
            drop(k, corrupt: false); return nil
        }
        func bad() -> VerifiedFile? { drop(k, corrupt: true); return nil }
        let n = data.count
        guard n >= 8 + 4 + 32, data.prefix(8).elementsEqual(Self.magic) else { return bad() }
        let hlen = data.subdata(in: 8 ..< 12).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let payloadStart = 12 + hlen
        guard hlen > 0, payloadStart <= n - 32 else { return bad() }
        guard let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 12 ..< payloadStart)),
              header.v == Self.formatVersion, header.rev == Self.engineRev, header.fp == fingerprint,
              header.key == k, header.parent.hasPrefix(parent) else { return bad() }
        var h = SHA256()
        var off = 0
        while off < n - 32 {
            let e = min(off + (8 << 20), n - 32)
            h.update(data: data[off ..< e]); off = e
        }
        guard Data(h.finalize()) == data[(n - 32)...] else { return bad() }
        let payload = n - 32 - payloadStart
        for t in header.tensors {
            guard let dt = Self.dtype(t.d), t.o >= 0, t.l >= 0, t.o + t.l <= payload,
                  t.s.allSatisfy({ $0 >= 0 }), t.s.reduce(1, *) * dt.size == t.l else { return bad() }
        }
        return VerifiedFile(header: header, data: data, payloadStart: payloadStart)
    }

    /// Builds a trie node from a verified file (copies tensors into MLX memory). Caller attaches it.
    static func makeNode(_ f: VerifiedFile, tokens: [Int32], parent: PrefixStore.Node?, hash: UInt64, key: Data) -> PrefixStore.Node? {
        let node = PrefixStore.Node(tokens: tokens, parent: parent, depth: (parent?.depth ?? 0) + 1)
        guard node.end == f.header.end, node.depth == f.header.depth else { return nil }
        var mk: MLXArray?, mv: MLXArray?, mh: MLXArray?
        for t in f.header.tensors {
            guard let dt = dtype(t.d) else { return nil }
            let a = MLXArray(f.data[(f.payloadStart + t.o) ..< (f.payloadStart + t.o + t.l)], t.s, dtype: dt)
            let parts = t.n.split(separator: ".", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "k": node.k[Int(parts[1])!] = a
            case "v": node.v[Int(parts[1])!] = a
            case "conv": node.conv[Int(parts[1])!] = a; node.stateBytes += t.l
            case "ssm": node.ssm[Int(parts[1])!] = a; node.stateBytes += t.l
            case "mtp": if parts[1] == "k" { mk = a } else if parts[1] == "v" { mv = a } else { mh = a }
            default: return nil
            }
            node.bytes += t.l
        }
        if let k = mk, let v = mv, let h = mh { node.mtp = MTPBlock(k: k, v: v, hidden: h, start: f.header.mtpStart ?? -1) }
        node.hash = hash
        node.diskKey = key
        guard node.hasState else { return nil }
        return node
    }

    func recordLoad(nodes: Int, bytes: Int, seconds: Double) {
        lock.withLock { _stats.loadedNodes += nodes; _stats.loadedBytes += bytes; _stats.loadSeconds += seconds }
    }

    // MARK: clear

    /// Deletes this fingerprint's files.
    public func clear() {
        queue.sync {}
        lock.withLock {
            for (k, e) in index { unlink(path(k, parent: e.parent)) }
            index.removeAll(); total = 0
        }
    }

    /// Deletes every cache file under `root` (all fingerprints): only `*.spd` / `*.tmp` regular files in
    /// direct 16-byte-hex subdirectories, then the emptied subdirectories. Returns (files, bytes).
    @discardableResult
    public static func clearAll(root: String) -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        var files = 0, bytes = 0
        for sub in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            guard sub.count == 32, sub.allSatisfy({ $0.isHexDigit }) else { continue }
            let d = root + "/" + sub
            var dst = stat()
            guard lstat(d, &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR else { continue }
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where n.hasSuffix(".spd") || n.hasSuffix(".tmp") {
                let p = d + "/" + n
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                if unlink(p) == 0 { files += 1; bytes += Int(st.st_size) }
            }
            rmdir(d)   // only succeeds when empty
        }
        return (files, bytes)
    }

    /// (files, bytes) under `root` without changing anything.
    public static func usage(root: String) -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        var files = 0, bytes = 0
        for sub in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where sub.count == 32 {
            for n in (try? fm.contentsOfDirectory(atPath: root + "/" + sub)) ?? [] where n.hasSuffix(".spd") {
                var st = stat()
                if lstat(root + "/" + sub + "/" + n, &st) == 0 { files += 1; bytes += Int(st.st_size) }
            }
        }
        return (files, bytes)
    }
}

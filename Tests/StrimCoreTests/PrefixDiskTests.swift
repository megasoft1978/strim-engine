import Foundation
import MLX
import MLXRandom
import Testing
@testable import StrimCore

private let C = 4

private func tmpRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-pd-\(UUID().uuidString)")
}

/// Live cache at `blocks * C` tokens with bf16 KV, f32 GDN state (random, so equal bytes mean a real round trip).
private func randCache(blocks: Int, seed: UInt64) -> ModelCache {
    let n = blocks * C
    let c = ModelCache()
    let key = MLXRandom.key(seed)
    for l in [3, 7] {
        let a = c.attentionCache(l)
        let k = MLXRandom.normal([1, 2, n, 8], key: key).asType(.bfloat16)
        _ = a.append(k, (k * 2).asType(.bfloat16))
    }
    let s = c.gdnState(0)
    s.conv = MLXRandom.normal([1, 3, 16], key: key)
    s.ssm = MLXRandom.normal([1, 2, 4, 4], key: key)
    c.position = n
    eval(c)
    return c
}

private func mtpBlock(_ lo: Int) -> MTPBlock {
    let k = MLXRandom.normal([1, 1, C, 8], key: MLXRandom.key(UInt64(100 + lo))).asType(.bfloat16)
    return MTPBlock(k: k, v: k + 1, hidden: MLXRandom.normal([1, 1, 16], key: MLXRandom.key(7)).asType(.bfloat16), start: lo)
}

private let FP = "0123456789abcdef0123456789abcdef"
private func bytes(_ a: MLXArray) -> Data { a.asData(access: .copy).data }

private func fill(_ store: PrefixStore, _ t: [Int32], blocks: Int, mtp: Bool = true) throws {
    var node: PrefixStore.Node? = nil
    for b in 1 ... blocks {
        node = try store.insert(parent: node, tokens: Array(t[0 ..< b * C]), cache: randCache(blocks: b, seed: UInt64(b)),
                                mtp: mtp ? mtpBlock((b - 1) * C) : nil)
    }
}

private func diskStore(_ root: URL, budget: Int = 1 << 30, floor: Int = 0, mem: Int = 1 << 30, fp: String = FP) throws -> (PrefixStore, PrefixDisk) {
    let d = try PrefixDisk(root: root, fingerprint: fp, budgetBytes: budget, floorBytes: floor)
    let s = PrefixStore(budgetBytes: mem, chunk: C)
    s.disk = d
    return (s, d)
}

private func files(_ d: PrefixDisk) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: d.dir.path)) ?? []).sorted()
}

@Test func diskRoundTripIsBitIdentical() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let t: [Int32] = (0 ..< 4 * C).map { Int32($0) + 1000 }
    let (a, da) = try diskStore(root)
    try fill(a, t, blocks: 3)
    da.flush()
    #expect(da.stats.spilled == 3)

    let (b, db) = try diskStore(root)            // "restart": fresh trie, same dir
    let hit = b.lookup(t, maxTokens: 4 * C, requireMTP: true)
    #expect(hit?.depth == 3)
    #expect(db.stats.loadedNodes == 3)
    let ra = try a.restore(a.lookup(t, maxTokens: 4 * C)!), rb = try b.restore(hit!)
    #expect(rb.position == ra.position)
    for l in [3, 7] {
        #expect(bytes(rb.attention[l]!.keys!) == bytes(ra.attention[l]!.keys!))
        #expect(bytes(rb.attention[l]!.values!) == bytes(ra.attention[l]!.values!))
        #expect(rb.attention[l]!.keys!.dtype == .bfloat16)
    }
    #expect(bytes(rb.gdn[0]!.conv!) == bytes(ra.gdn[0]!.conv!))
    #expect(bytes(rb.gdn[0]!.ssm!) == bytes(ra.gdn[0]!.ssm!))
    let ma = try a.restoreMTP(a.lookup(t, maxTokens: 4 * C)!), mb = try b.restoreMTP(hit!)
    #expect(bytes(mb.state.attention.keys!) == bytes(ma.state.attention.keys!))
    #expect(bytes(mb.state.attention.values!) == bytes(ma.state.attention.values!))
    #expect(bytes(mb.carry) == bytes(ma.carry))
    #expect(b.totalBytes == a.totalBytes)
    // Loaded nodes are normal trie nodes: second lookup is a pure memory hit.
    #expect(b.lookup(t, maxTokens: 4 * C, requireMTP: true)?.depth == 3)
    #expect(db.stats.loadedNodes == 3)
    // A diverging prompt only reuses the common blocks.
    var u = t; u[2 * C + 1] = 77_777
    let (c, _) = try diskStore(root)
    #expect(c.lookup(u, maxTokens: 4 * C)?.depth == 2)
}

@Test func diskFilesArePrivateAndHoldNoTokens() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let t: [Int32] = (0 ..< 2 * C).map { Int32(0x5A5A_1200) + Int32($0) }
    let (a, d) = try diskStore(root)
    try fill(a, t, blocks: 2)
    d.flush()
    let names = files(d)
    #expect(names.count == 2 && names.allSatisfy { $0.hasSuffix(".spd") })   // no .tmp left behind
    func mode(_ p: String) -> Int { Int((try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? NSNumber)??.intValue ?? -1) }
    #expect(mode(d.dir.path) == 0o700 && mode(root.path) == 0o700)
    for n in names {
        #expect(mode(d.dir.appendingPathComponent(n).path) == 0o600)
        let data = try Data(contentsOf: d.dir.appendingPathComponent(n))
        for tok in t {
            var le = tok.littleEndian
            #expect(data.range(of: Data(bytes: &le, count: 4)) == nil)   // token ids never written
        }
        #expect(String(decoding: data.prefix(8), as: UTF8.self) == "STRIMPD1")
    }
}

@Test func diskCorruptAndTruncatedFilesAreIgnoredAndDeleted() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let t: [Int32] = (0 ..< 4 * C).map { Int32($0) + 5 }
    let (a, d) = try diskStore(root)
    try fill(a, t, blocks: 3)
    d.flush()
    // Corrupt the deepest node's payload (flip one byte): only that node is lost.
    let (probe, pd) = try diskStore(root)
    #expect(probe.lookup(t, maxTokens: 4 * C)?.depth == 3)
    #expect(pd.stats.corrupt == 0)
    // find third-block file by key chain
    var pk = d.rootKey
    var keys: [Data] = []
    for b in 1 ... 3 { pk = d.key(parent: pk, tokens: t[(b - 1) * C ..< b * C]); keys.append(pk) }
    func path(_ k: Data) -> URL { d.dir.appendingPathComponent(files(d).first { $0.hasPrefix(PrefixDisk.hex(k)) }!) }
    let p3 = path(keys[2])
    var bytes3 = try Data(contentsOf: p3); bytes3[bytes3.count / 2] ^= 0x01
    try bytes3.write(to: p3)
    let (b, db) = try diskStore(root)
    #expect(b.lookup(t, maxTokens: 4 * C)?.depth == 2)
    #expect(db.stats.corrupt == 1)
    #expect(!FileManager.default.fileExists(atPath: p3.path))
    // Truncated middle file: chain ends before it, file removed.
    let p2 = path(keys[1])
    let full = try Data(contentsOf: p2)
    try full.prefix(full.count / 2).write(to: p2)
    let (c, dc) = try diskStore(root)
    #expect(c.lookup(t, maxTokens: 4 * C)?.depth == 1)
    #expect(dc.stats.corrupt == 1)
    #expect(!FileManager.default.fileExists(atPath: p2.path))
}

@Test func diskFingerprintMismatchNeverHits() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let t: [Int32] = (0 ..< 3 * C).map { Int32($0) + 5 }
    let (a, d) = try diskStore(root)
    try fill(a, t, blocks: 2)
    d.flush()
    let (other, _) = try diskStore(root, fp: "ffffffffffffffffffffffffffffffff")
    #expect(other.lookup(t, maxTokens: 3 * C) == nil)
    // A file copied into another fingerprint's dir (same name) is rejected by its header and deleted.
    let od = root.appendingPathComponent("ffffffffffffffffffffffffffffffff")
    for n in files(d) { try FileManager.default.copyItem(at: d.dir.appendingPathComponent(n), to: od.appendingPathComponent(n)) }
    let (again, da) = try diskStore(root, fp: "ffffffffffffffffffffffffffffffff")
    #expect(again.lookup(t, maxTokens: 3 * C) == nil)
    _ = da
    let p1 = CutPolicy.fixed(1024), p2 = CutPolicy.fixed(1536)
    #expect(PrefixDisk.fingerprint(modelDir: "/nonexistent", headDir: nil, policy: p1)
            != PrefixDisk.fingerprint(modelDir: "/nonexistent", headDir: nil, policy: p2))
}

@Test func diskBudgetEvictsLeavesFirstAndLRU() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    // Size of one spilled node, then a budget for exactly 4 files.
    let probeRoot = tmpRoot(); defer { try? FileManager.default.removeItem(at: probeRoot) }
    let (p, pd) = try diskStore(probeRoot)
    try fill(p, (0 ..< C).map { Int32($0) }, blocks: 1)
    pd.flush()
    let one = pd.stats.bytes
    #expect(one > 0)
    let (a, d) = try diskStore(root, budget: one * 4 + one / 2)
    let t1: [Int32] = (0 ..< 3 * C).map { Int32($0) + 10 }
    let t2: [Int32] = (0 ..< 3 * C).map { Int32($0) + 5000 }
    try fill(a, t1, blocks: 3); d.flush()
    try fill(a, t2, blocks: 3); d.flush()
    #expect(d.stats.bytes <= d.budgetBytes)
    #expect(d.stats.files == 4)
    // Oldest chain (t1) lost its leaves first; its root block survives with the newest chain intact.
    let (b, _) = try diskStore(root)
    #expect(b.lookup(t2, maxTokens: 3 * C)?.depth == 3)
    #expect((b.lookup(t1, maxTokens: 3 * C)?.depth ?? 0) <= 1)
}

@Test func diskFreeSpaceFloorSkipsWrites() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, d) = try diskStore(root, floor: 1 << 60)
    try fill(a, (0 ..< 2 * C).map { Int32($0) }, blocks: 2)
    d.flush()
    #expect(files(d).isEmpty)
    #expect(d.stats.skippedFloor > 0 && d.stats.spilled == 0)
}

@Test func diskLoadStaysInsideMemoryBudget() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let t: [Int32] = (0 ..< 5 * C).map { Int32($0) + 9 }
    let (a, d) = try diskStore(root)
    try fill(a, t, blocks: 4); d.flush()
    let node = a.totalBytes / 4
    let (b, _) = try diskStore(root, mem: node * 2 + node / 2)   // room for 2 nodes
    let hit = b.lookup(t, maxTokens: 5 * C)
    #expect(b.totalBytes <= b.budgetBytes)
    #expect((hit?.depth ?? 0) >= 1 && (hit?.depth ?? 0) <= 2)
}

@Test func diskDisabledMakesNoFilesAndNoDisk() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(PrefixDisk.fromEnvironment(modelDir: "/x", headDir: nil, policy: .fixed(C), env: [:]) == nil)
    #expect(PrefixDisk.fromEnvironment(modelDir: "/x", headDir: nil, policy: .fixed(C),
                                       env: ["STRIM_PREFIX_DISK": "0", "STRIM_PREFIX_DISK_DIR": root.path]) == nil)
    let s = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    #expect(s.disk == nil)
    try fill(s, (0 ..< 2 * C).map { Int32($0) }, blocks: 2)
    #expect(s.lookup((0 ..< 2 * C).map { Int32($0) }, maxTokens: 2 * C)?.depth == 2)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func diskClearAllRemovesOnlyCacheFiles() throws {
    let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (a, d) = try diskStore(root)
    try fill(a, (0 ..< 2 * C).map { Int32($0) }, blocks: 2); d.flush()
    let stray = root.appendingPathComponent("keep.txt")
    try Data("x".utf8).write(to: stray)
    let u = PrefixDisk.usage(root: root.path)
    #expect(u.files == 2 && u.bytes > 0)
    let r = PrefixDisk.clearAll(root: root.path)
    #expect(r.files == 2 && r.bytes == u.bytes)
    #expect(FileManager.default.fileExists(atPath: stray.path))
    #expect(!FileManager.default.fileExists(atPath: d.dir.path))
}

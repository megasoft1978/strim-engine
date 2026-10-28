import Darwin
import Foundation
import MLX
import StrimCore

// Usage: strim checkprefixdisk <model dir> <mtp head dir> [N=16384] [--phase both|warm|restart] [--dir DIR] [--state FILE]
// Exactness + restart gate for the opt-in disk prefix cache (STRIM_PREFIX_DISK=1 behavior, forced on here).
//  warm:    miss reference (no store), then a cold run that populates the trie and spills to DIR; saves the
//           reference prints (cache/MTP/seed/logits hashes + 64 speculative tokens) to FILE.
//  restart: fresh trie (+ fresh PrefixDisk on DIR, i.e. a new process after a server restart): the same prompt
//           must hit from disk, report load ms/GB, TTFT vs the cold run, footprint delta, and print equal FILE.
//  both:    warm then restart in one process (in-memory trie dropped between).

private func synth(_ n: Int, seed: Int) -> [Int32] {
    (0 ..< n).map { Int32(((($0 &+ seed &* 104_729) &* 7919) &+ 17 &+ seed) % 150_000) }
}

private func fnv(_ h: inout UInt64, _ a: MLXArray) {
    for x in a.asType(.float32).asArray(Float.self) { h = (h ^ UInt64(x.bitPattern)) &* 0x0000_0100_0000_01b3 }
}

private struct Prints: Codable, Equatable {
    var cache: UInt64, mtp: UInt64, seed: UInt64, logits: UInt64, token: Int32, tokens: [Int32]
}

private func footprintGB() -> (cur: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_073_741_824, Double(info.ledger_phys_footprint_peak) / 1_073_741_824)
}

private struct RunOut { var prints: Prints; var prefill: Double; var matched: Int; var hit: Bool }

private func run(_ prompt: [Int32], model: WeightStore, head: WeightStore, store: PrefixStore?) throws -> RunOut {
    let t0 = Date()
    let o = try SpecPrefill.run(tokens: prompt, store: model, head: head, cache: store)
    eval(o.logits, o.seedHidden)
    let tp = Date().timeIntervalSince(t0)
    var hc: UInt64 = 0xcbf2_9ce4_8422_2325
    for l in o.cache.attention.keys.sorted() { fnv(&hc, o.cache.attention[l]!.keys!); fnv(&hc, o.cache.attention[l]!.values!) }
    for l in o.cache.gdn.keys.sorted() { fnv(&hc, o.cache.gdn[l]!.conv!); fnv(&hc, o.cache.gdn[l]!.ssm!) }
    var hm: UInt64 = 0xcbf2_9ce4_8422_2325
    fnv(&hm, o.mtp.attention.keys!); fnv(&hm, o.mtp.attention.values!)
    if let s = o.mtp.seedHidden { fnv(&hm, s) }
    if let t = o.mtp.seedTokenIndex { fnv(&hm, t.asType(.float32)) }
    var hs: UInt64 = 0xcbf2_9ce4_8422_2325; fnv(&hs, o.seedHidden)
    var hl: UInt64 = 0xcbf2_9ce4_8422_2325; fnv(&hl, o.logits)
    let stream = SpecStream(store: model, head: head, cache: o.cache, mtp: o.mtp, seedToken: o.seedToken, lastHidden: o.seedHidden)
    var out: [Int32] = []
    while out.count < 64 { out += try stream.step(remaining: 64 - out.count) }
    return RunOut(prints: Prints(cache: hc, mtp: hm, seed: hs, logits: hl, token: o.seedToken, tokens: out),
                  prefill: tp, matched: o.matchedTokens, hit: o.hit)
}

func runPrefixDiskCheck(_ args: [String]) {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
    var pos: [String] = []
    var phase = "both", dir = NSTemporaryDirectory() + "strim-prefix-disk-check", state: String?
    var i = 2
    while i < args.count {
        let a = args[i]
        if a == "--phase", i + 1 < args.count { phase = args[i + 1]; i += 1 }
        else if a == "--dir", i + 1 < args.count { dir = (args[i + 1] as NSString).expandingTildeInPath; i += 1 }
        else if a == "--state", i + 1 < args.count { state = args[i + 1]; i += 1 }
        else if a.hasPrefix("--") { fail("unknown option \(a)") }
        else { pos.append(a) }
        i += 1
    }
    guard pos.count >= 2, ["both", "warm", "restart"].contains(phase) else {
        fail("usage: strim checkprefixdisk <model dir> <mtp head dir> [N=16384] [--phase both|warm|restart] [--dir DIR] [--state FILE]")
    }
    let n = pos.count > 2 ? Int(pos[2]) ?? 16384 : 16384
    let statePath = state ?? dir + ".state.json"
    Memory.cacheLimit = 2 << 30
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  " + detail)")
        if !ok { failures += 1 }
    }
    do {
        let model = try WeightStore(dir: URL(fileURLWithPath: pos[0]))
        let head = try WeightStore(dir: URL(fileURLWithPath: pos[1]))
        head.useIntegratedMTPPrefixIfNeeded()
        let prompt = synth(n, seed: 1)
        let fp = PrefixDisk.fingerprint(modelDir: pos[0], headDir: pos[1], policy: PrefixPrefill.defaultPolicy)
        func makeStore() throws -> (PrefixStore, PrefixDisk) {
            let d = try PrefixDisk(root: URL(fileURLWithPath: dir), fingerprint: fp)
            let s = PrefixStore(budgetBytes: PrefixStore.defaultBudgetMB << 20)
            s.disk = d
            return (s, d)
        }
        print("checkprefixdisk N=\(n) phase=\(phase) dir=\(dir) footprint \(String(format: "%.2f", footprintGB().cur)) GB")
        _ = try run(Array(prompt[0 ..< 600]), model: model, head: head, store: nil)   // kernel warmup
        var coldSeconds = 0.0
        if phase == "both" || phase == "warm" {
            PrefixDisk.clearAll(root: dir)
            print("(a) miss reference (no store)")
            let ref = try run(prompt, model: model, head: head, store: nil)
            print("  prefill \(String(format: "%.2f", ref.prefill)) s")
            let (s, d) = try makeStore()
            let cold = try run(prompt, model: model, head: head, store: s)
            d.flush()
            coldSeconds = cold.prefill
            let st = d.stats
            print("  footprint after cold run \(String(format: "%.2f", footprintGB().cur)) GB, peak \(String(format: "%.2f", footprintGB().peak)) GB, trie \(String(format: "%.2f", Double(s.totalBytes) / 1e9)) GB, writer stalls \(d.stats.stalls) (\(String(format: "%.2f", d.stats.stallSeconds)) s)")
            print("(b) cold run populating disk: prefill \(String(format: "%.2f", cold.prefill)) s, spilled \(st.spilled) files \(String(format: "%.2f", Double(st.spilledBytes) / 1e9)) GB, skipped busy \(st.skippedBusy) floor \(st.skippedFloor) orphan \(st.skippedOrphan), write errors \(st.writeErrors)")
            check("cold-store (disk on) == reference", cold.prints == ref.prints && !cold.hit)
            check("every node spilled", st.spilled == s.nodeCount, "spilled \(st.spilled) nodes \(s.nodeCount)")
            try JSONEncoder().encode(ref.prints).write(to: URL(fileURLWithPath: statePath))
            try Data(String(coldSeconds).utf8).write(to: URL(fileURLWithPath: statePath + ".cold"))
        }
        if phase == "both" || phase == "restart" {
            guard let refData = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                  let ref = try? JSONDecoder().decode(Prints.self, from: refData) else { fail("no reference state at \(statePath); run --phase warm first") }
            if coldSeconds == 0, let c = try? String(contentsOfFile: statePath + ".cold", encoding: .utf8) { coldSeconds = Double(c) ?? 0 }
            let before = footprintGB()
            let (s, d) = try makeStore()
            print("(c) restart: fresh trie, \(d.stats.files) files / \(String(format: "%.2f", Double(d.stats.bytes) / 1e9)) GB on disk, footprint \(String(format: "%.2f", before.cur)) GB")
            let hit = try run(prompt, model: model, head: head, store: s)
            let ls = d.stats
            let gb = Double(ls.loadedBytes) / 1e9
            print("  TTFT (prefill) \(String(format: "%.2f", hit.prefill)) s vs cold \(String(format: "%.2f", coldSeconds)) s; matched \(hit.matched)/\(n)")
            print("  disk load: \(ls.loadedNodes) nodes, \(String(format: "%.2f", gb)) GB in \(String(format: "%.0f", ls.loadSeconds * 1000)) ms = \(String(format: "%.0f", ls.loadSeconds * 1000 / max(gb, 1e-9))) ms/GB (\(String(format: "%.2f", gb / max(ls.loadSeconds, 1e-9))) GB/s incl. SHA-256 verify + MLX copy)")
            let after = footprintGB()
            print("  footprint \(String(format: "%.2f", after.cur)) GB (trie \(String(format: "%.2f", Double(s.totalBytes) / 1e9)) GB), peak \(String(format: "%.2f", after.peak)) GB")
            check("restored run == miss reference (cache, MTP, seed, logits, token, 64 spec tokens)", hit.prints == ref,
                  "cache \(hit.prints.cache == ref.cache) mtp \(hit.prints.mtp == ref.mtp) seed \(hit.prints.seed == ref.seed) logits \(hit.prints.logits == ref.logits) tok \(hit.prints.tokens == ref.tokens)")
            check("hit from disk", hit.hit && ls.loadedNodes > 0 && hit.matched > 0)
            check("trie within budget", s.totalBytes <= s.budgetBytes)
        }
    } catch {
        print("error: \(error)"); exit(1)
    }
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

import Foundation
let root = "/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029"
let raw = root + "/raw/fin"
func readRows(_ path: String) throws -> [[String:Any]] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String:Any] }
}
func median(_ values: [Double]) -> Double {
    precondition(!values.isEmpty)
    let s = values.sorted(), n = s.count
    return n % 2 == 1 ? s[n/2] : (s[n/2-1] + s[n/2])/2
}
func number(_ row: [String:Any], _ key: String) -> Double { (row[key] as! NSNumber).doubleValue }
func pct(_ a: Double, _ b: Double) -> Double { (b/a-1)*100 }
func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) + "\n" }
var groups: [String:[[String:Any]]] = [:]
for cycle in 1...2 {
    for (index,arm) in ["base","fork","fork","base"].enumerated() {
        let name = "\(cycle)-\(index+1)-\(arm)", dir = raw + "/abba/" + name
        precondition(FileManager.default.fileExists(atPath: dir + "/end.txt"), "incomplete block \(name)")
        for cell in ["c1","c4","c8","verify"] {
            let rows = try readRows(dir + "/" + cell + ".jsonl").filter { $0["kind"] as? String != "meta" }
            let chunks = Dictionary(grouping: rows) { row in cell == "verify" ? "verify\(row["width"]!)" : cell }
            for (key,rs) in chunks {
                precondition(rs.compactMap { $0["rep"] as? Int }.sorted() == [-1,0,1,2])
                let measured = rs.filter { ($0["rep"] as! Int) >= 0 }
                let metric = cell == "verify" ? "ms" : "aggregate_tps"
                let sample = measured.map { number($0,metric) }
                let outputs = try rs.map { try json($0["hashes"] ?? [$0["hash"]!]) }
                precondition(Set(outputs).count == 1, "within-process output change \(name) \(key)")
                var block: [String:Any] = ["block": name, "cycle":cycle, "index":index+1, "arm":arm, "median":median(sample), "samples":sample, "output":outputs[0], "peak_bytes":measured.map { number($0,"mlx_peak_bytes") }.max()!]
                if cell != "verify" { block["request_tps"] = median(measured.map { number($0,"request_tps") }) }
                groups[key,default:[]].append(block)
            }
        }
    }
}
var table: [[String:Any]] = []
for key in ["c1","c4","c8","verify3","verify5","verify8"] {
    let bs = groups[key]!
    precondition(bs.count == 8 && Set(bs.map { $0["output"] as! String }).count == 1, "output mismatch \(key)")
    let a = bs.filter { $0["arm"] as! String == "base" }, b = bs.filter { $0["arm"] as! String == "fork" }
    let am = median(a.map { number($0,"median") }), bm = median(b.map { number($0,"median") })
    var cycles: [[String:Any]] = []
    for c in 1...2 {
        let aa = a.filter { $0["cycle"] as! Int == c }.map { number($0,"median") }
        let bb = b.filter { $0["cycle"] as! Int == c }.map { number($0,"median") }
        cycles.append(["cycle":c, "upstream":sqrt(aa[0]*aa[1]), "fork":sqrt(bb[0]*bb[1]), "change_pct":pct(sqrt(aa[0]*aa[1]),sqrt(bb[0]*bb[1])), "same_arm_noise_pct":max(abs(pct(aa[0],aa[1])),abs(pct(bb[0],bb[1])))])
    }
    var r: [String:Any] = ["workload":key, "unit":key.hasPrefix("c") ? "aggregate tok/s" : "ms/verify step", "upstream":am, "fork":bm, "change_pct":pct(am,bm), "cycles":cycles, "blocks":bs, "identical_outputs":true, "upstream_peak_bytes":a.map { number($0,"peak_bytes") }.max()!, "fork_peak_bytes":b.map { number($0,"peak_bytes") }.max()!]
    if key.hasPrefix("c") {
        r["upstream_request_tps"] = median(a.map { number($0,"request_tps") })
        r["fork_request_tps"] = median(b.map { number($0,"request_tps") })
    }
    table.append(r)
}
var batch: [[String:Any]] = []
for c in [6,7,8] {
    let a = try String(contentsOfFile: raw + "/parity/batch\(c)-base.txt", encoding:.utf8)
    let b = try String(contentsOfFile: raw + "/parity/batch\(c)-fork.txt", encoding:.utf8)
    precondition(a == b && !a.contains("SUSPECT") && a.contains("RESULT"), "unclassified batch difference")
    batch.append(["c":c, "identical":true, "summary":a.split(separator:"\n").filter { $0.hasPrefix("tokens:") || $0.hasPrefix("RESULT") }.map(String.init)])
}
let verify = try readRows(raw + "/parity/verify-fork.jsonl").filter { $0["kind"] as? String == "qualityverify" }
precondition(verify.compactMap { $0["size"] as? Int } == [3,5,8])
precondition(verify.allSatisfy { number($0,"different_float_bits") == 0 && number($0,"max_abs_diff") == 0 && number($0,"teacher_forced_agreement") == number($0,"tokens") && ($0["has_reference"] as? Bool) == true })
let c1 = table[0], c8 = table[2]
let noise = (c1["cycles"] as! [[String:Any]]).map { number($0,"same_arm_noise_pct") }.max()!
let c8pass = number(c8,"change_pct") >= 2, c1pass = number(c1,"change_pct") >= -noise
let keep = c8pass && c1pass
let result: [String:Any] = ["slice":"20261030-5-s4-fin", "parity":["batch":batch,"verify":verify,"engine_case_242":"pre-existing sampled B>1 nondeterminism; see divergence/control.json"], "abba_cycles":2, "abba_order":"upstream,fork,fork,upstream", "abba_table":table, "c1_noise_pct":noise,"c1_no_regression_beyond_noise":c1pass,"c8_at_least_2pct":c8pass,"keep":keep,"verdict":keep ? "KEEP" : "DO NOT KEEP"]
try json(result).write(toFile:raw + "/final-result.json", atomically:true, encoding:.utf8)
print(try json(result.filter { $0.key != "abba_table" && $0.key != "parity" }))
for r in table { print("\(r["workload"]!): \(r["upstream"]!) -> \(r["fork"]!) (\(r["change_pct"]!)%)") }
func f(_ value: Double, _ digits: Int = 2) -> String { String(format:"%.*f",digits,value) }
func signed(_ v: Double) -> String { String(format:"%+.2f%%",v) }
var report = """
# S4 remote-fork integration (2026-10-29; finalized 2026-10-30)

**\(keep ? "KEEP — the requested parity and performance gates pass." : "DO NOT KEEP — the performance keep rule failed.")** Two complete ABBA cycles compare the existing fresh upstream 0.32.3 build against remote fork `megasoft1978/mlx-swift` `0.32.3-strim.1` (qmv_wide tile cap 8). Decode c=8 aggregate changes **\(signed(number(c8,"change_pct")))**; c=1 changes **\(signed(number(c1,"change_pct")))**, against measured same-arm noise **\(f(noise))%**. No commit was made. This finishing slice did not change `Package.swift`, `Package.resolved`, or `docs/SWIFT-PERF.md`; their existing uncommitted edits remain for owner review.

The final machine-readable parity results, complete ABBA samples, block medians, per-cycle effects, output hashes, and peak MLX bytes are in [final-result.json](raw/fin/final-result.json). Commands and initial input/binary SHA-256 hashes are retained in [raw/fin](raw/fin/). The original [result.json](result.json) and `raw/gates.json` describe the historical stopped run and are superseded by this final report for the requested finishing gates.

## Parity results

| Gate | Result |
|---|---|
| Fork resolution / nested patch provenance | Prior PASS; existing binaries reused unchanged |
| Fresh release builds, upstream and fork | Prior PASS |
| gen 16 | Prior PASS, identical token IDs |
| depth-0 benchspec | Prior PASS, EXACT and identical verdict |
| checkprefix 4096 / 8192 + MTP | Prior PASS, identical hashes/tokens/margins/verdicts |
| Batched decode logits/hashes, c=1/4/6/7/8 | Prior PASS, 208 full-vocab rows and 1,664 choices |
| Verify logits/hashes, widths 3/5/8 | Prior PASS; fresh finishing check also PASS, 3,973,120 float32 values with zero different bits, max absolute difference 0, all 16 choices equal |
| Eight-prompt corpus | Prior PASS, 64 full-vocab rows, 512 choices, all 8 independent greedy outputs |
| Concurrent-decode engine case 242 | Pre-existing sampled B>1 nondeterminism; controlled upstream/fork variants match, see below |
| checkbatchparity c=6 | PASS, complete upstream/fork CLI logs identical; 93/96 B=1-vs-batch token choices equal, 3 existing explainable near-ties |
| checkbatchparity c=7 | PASS, complete upstream/fork CLI logs identical; 109/112 B=1-vs-batch token choices equal, 3 existing explainable near-ties |
| checkbatchparity c=8 | PASS, complete upstream/fork CLI logs identical; 124/128 B=1-vs-batch token choices equal, 4 existing explainable near-ties |
| Timed decode / verify outputs | PASS, every warmup and measured rep matches across all 8 ABBA blocks |

Fresh CLI checks use context 512 and 16 teacher-forced steps. They compare identical policies **between builds**: the reported B=1-versus-batch numerical drift and near-tie flips are the same in both arms. No fresh parity difference required an upstream repeat. CLI c=1/4 were outside this finishing request and were not run; their earlier in-process logit gates remain recorded above. The prior exact-logit total was 288 rows / 71,516,160 float32 values. These measurements establish equality only for the sampled rows and observed outputs.

## Known issue: pre-existing sampled B>1 nondeterminism

The original engine run stopped at zero-based case 242 (sampled / auto / B=3 / mixed prompts, seeds 100/101/102). The [determinism control](divergence/REPORT.md) subsequently reproduced the same two complete token-array variants in two upstream and two fork processes. Upstream differs from itself at exactly the original first differing indices (23/14/36); upstream 1 vs fork 2 and upstream 2 vs fork 1 each match **480/480 tokens**. This is classified as pre-existing run-to-run nondeterminism, not a fork regression. Its internal cause and frequency remain unmeasured. The full engine matrix was not replayed by this finishing slice, and the prior interrupted matrix is not represented as a new complete pass.

## ABBA performance

Each cycle runs upstream → fork → fork → upstream. Each cell uses a fresh existing release `S4IntegrationBench` process, one excluded warmup, and three measured reps. Decode uses 64 lockstep steps; verify widths 3/5/8 use 12 fixed-state target passes per rep with verify rollback state. Rates exclude model loading and initial prefill. Verify time is milliseconds per target verify pass; lower is better. Per-request decode rates are aggregate rates divided by concurrency, with all requests advancing in lockstep. This is in-process throughput.

The table uses the median of four block medians per arm (12 measured samples per arm/workload). Cycle effects use ratios of the geometric means of the two arm block medians. No additional prefill workload was requested or run in this finishing slice.

| Workload | Unit | Upstream | Fork | Change | Cycle 1 | Cycle 2 |
|---|---|---:|---:|---:|---:|---:|
"""
for r in table {
    let key = r["workload"] as! String, cs = r["cycles"] as! [[String:Any]]
    let label = key.hasPrefix("c") ? "decode c=" + key.dropFirst() : "verify width=" + key.dropFirst(6)
    report += "\n| \(label) | \(r["unit"]!) | \(f(number(r,"upstream"))) | \(f(number(r,"fork"))) | \(signed(number(r,"change_pct"))) | \(signed(number(cs[0],"change_pct"))) | \(signed(number(cs[1],"change_pct"))) |"
    if key.hasPrefix("c") {
        report += "\n| \(label), per request | tok/s | \(f(number(r,"upstream_request_tps"))) | \(f(number(r,"fork_request_tps"))) | \(signed(number(r,"change_pct"))) | \(signed(number(cs[0],"change_pct"))) | \(signed(number(cs[1],"change_pct"))) |"
    }
}
report += """


**Keep rule:** c=8 aggregate >= +2%: **\(c8pass ? "PASS" : "FAIL")** (\(signed(number(c8,"change_pct")))). c=1 regression no greater than measured noise: **\(c1pass ? "PASS" : "FAIL")** (\(signed(number(c1,"change_pct")))) versus \(f(noise))% noise. Noise is the maximum absolute within-cycle same-arm block change, across both cycles and both arms. All timed output hashes are identical. Final verdict: **\(keep ? "KEEP" : "DO NOT KEEP")**. Results apply to this measured M5 Max and these workloads.

## Existing full test result and execution safety

The prior full `swift test --package-path /tmp/s4/src-int --scratch-path /tmp/s4/build-int` run exited 0: **1,790 passed, 45 skipped, zero failures** (XCTest 113 passed/14 skipped; Swift Testing 1,677 passed/31 skipped). It used default debug configuration; the preceding failed release test-build preparation ran no tests. See [raw/tests.json](raw/tests.json) and [raw/swift-test.log](raw/swift-test.log). No test, threshold, oracle, skip condition, or golden was changed. Tests were not rerun for this benchmark/report-only finish.

Every fresh GPU invocation held `/tmp/strim-bench.lock` via `lockf -k`; it was retained. No HTTP servers or ports (including 8203), GUI sessions, or logins were used. Models were read-only; scratch helpers and saved verify tensors stayed under `/tmp/s4/fin`. All started GPU processes completed normally. No unowned process was stopped, no recursive delete was performed, and no commit was made. Initial and final hashes plus the owned-process cleanup check are retained under `raw/fin`. Checks were headless; GUI behavior was not tested by this slice.
"""
try (report + "\n").write(toFile:root + "/REPORT.md",atomically:true,encoding:.utf8)

import Foundation
let p="bench/results/speed-s5-20261030"
let j=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:p+"/result.json"))) as! [String:Any]
func n(_ r:[String:Any],_ k:String)->Double {(r[k] as! NSNumber).doubleValue}
func f(_ x:Double,_ digits:Int=3)->String {String(format:"%.*f",digits,x)}
let decode=j["decode"] as! [[String:Any]], stress=j["quality_stress"] as! [[String:Any]], verify=j["quality_verify"] as! [[String:Any]]
var text=try String(contentsOfFile:"/tmp/s5/protocol.md",encoding:.utf8)
let old="Experiment in progress. Final numbers and disposition will replace this paragraph after all eight ABBA blocks and quality gates finish."
let intro=decode.count==6 ? "**(a) SKIP: already one multi-query SDPA call. (b) Retained only as an opt-in experiment; default OFF.** The strict bit-identity gate fails: verify hashes differ, two of eight stress greedy outputs differ, and the hot continuation changes. No default proposal is eligible. Decode results below are measured on this shared machine and must be read against their same-arm noise." : "**PARTIAL — paired decode measurement blocked by the shared GPU lock.** An unowned Evolve search (PID 70044, --budget-minutes 720) holds the lock for its whole search. S5 completed the implementation and quality gates, but only the first two default timing cells ran. The queued S5 process was stopped to satisfy cleanup; no unowned process was signalled. The fusion remains opt-in, default OFF, with no validated speed claim and no default proposal."
text=text.replacingOccurrences(of:old,with:intro)
text=text.replacingOccurrences(of:"Final test verdict pending.",with:"Final headless focused rerun: **2 passed, zero failures**, 0.204 s. GUI checks were outside this slice.")
var tables="""
## Microbench and advance/kill decisions

Part (a) has no changed path to benchmark: the requested batching already exists. Part (b) advanced provisionally because the simple 16K projection crossed +1.5% in loaded runs; a lower-noise width-3 sample was below that threshold. This uncertainty is retained rather than claiming an unambiguous microbench pass.

The width-3 B=1 table uses one fresh 16K depth-2 control median of 45.17 ms/round (90 measured rounds, 43.78 ms minimum). Projection is `45.17/(45.17 - saved_eval_ms)-1`, assuming unchanged acceptance and all micrograph savings on the critical path. It is a projection, not observed decode throughput. Host construction savings are recorded separately in raw data because pipelining can hide them.

| Micro run | A eval ms/48 | Fused eval ms/48 | Saved ms | Simple projected decode gain | Same-arm micro noise |
|---|---:|---:|---:|---:|---:|
"""
for i in 2...4 {
    let rows=(try String(contentsOfFile:"/tmp/s5/micro\(i)-summary.jsonl",encoding:.utf8)).split(separator:"\n").map{try! JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
    let r=rows.first{($0["B"] as! Int)==1 && ($0["S"] as! Int)==3}!
    let saved=n(r,"saved_eval_ms48")
    tables += "\n| \(i) | \(f(n(r,"A_eval_ms48"))) | \(f(n(r,"B_eval_ms48"))) | \(f(saved)) | \(f((45.17/(45.17-saved)-1)*100,2))% | \(f(n(r,"same_arm_noise_pct"),2))% |"
}
tables += """


Run 1 included graph construction and a different dependency chain; it is exploratory only. Run 2 began at 1-minute load 179.6; run 3 ended at 48.3; run 4 began at 22.0 and experienced further load variation. All four runs, all B/S shapes, parity probes, samples, block loads, and build/eval splits are retained in raw. Synthetic Q/K/V/beta were equal on every tested shape; g differed by at most 2.98e-8. Real-model drift is much larger and is reported below.

## Decode ABBA results

| Context | c | Default aggregate tok/s | Opt-in aggregate tok/s | Change | Cycle 1 | Cycle 2 | Same-arm noise | Output-mismatch reps |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
"""
for r in decode {
    let cycles=r["cycle_effect_pct"] as! [Double]
    tables += "\n| \(r["ctx"]!) | \(r["c"]!) | \(f(n(r,"A_tps"),2)) | \(f(n(r,"B_tps"),2)) | \(f(n(r,"delta_pct"),2))% | \(f(cycles[0],2))% | \(f(cycles[1],2))% | \(f(n(r,"noise_pct"),2))% | \(r["output_mismatch_reps"]!) |"
}
if decode.count != 6 {
    let partial=j["partial_decode"] as? [[String:Any]] ?? []
    for ctx in [4096,16384,32768] {for c in [1,4] {
        let r=partial.first{($0["ctx"] as! Int)==ctx && ($0["c"] as! Int)==c}
        let a=r.map{f(n($0,"aggregate_tps_median"),2)+" (A1 only)"} ?? "pending"
        tables += "\n| \(ctx) | \(c) | \(a) | pending | — | — | — | unmeasured | — |"
    }}
    tables += "\n\nThese are partial baseline cells, **not** ABBA estimates. No candidate decode sample completed. The +2% at 16K c=1 beyond-noise gate cannot be assessed. After GPU availability is resolved, rerun the entire schedule with `bash /tmp/s5/abba.sh` (or the retained raw script); it intentionally restarts at A1."
}
tables += """


c=4 is four concurrent MTP streams under round-robin, not a batched plain-decode claim. Per-request rates, samples, load/swap snapshots, acceptance, pass counts and token IDs/hashes are in raw; aggregate rates are the metric above. A timing row with changed output/acceptance is not evidence of a like-for-like kernel speedup.

## Quality results

| Gate | Result |
|---|---|
| gen16, default 3-token prompt | Identical token IDs |
| checkprefix 4096 + MTP | Both internal ALL PASS; reported reference hash/16 IDs and MTP first 8 IDs match |
| checkprefix 8192 + MTP | Both internal ALL PASS; reported reference fields compared in result.json |
| Informational hot continuation, both prefix checks | FAIL: default hot/cold identical over 20 tokens; opt-in first diverges at index 6 (2064 vs 40, cold margin 0.125) |
| Verify widths 3/5/8, 16K | FAIL full-logit hashes; all 16 top-1 choices agree |
| Eight 4K prompts, independent greedy16 | 6/8 identical; csvpy and sql differ |
| Teacher-forced stress top-1 | 126/128 rows agree |

Prefix ALL PASS is an internal cache-consistency verdict, not proof of cross-arm bit identity. The full MTP reference arrays are not printed by that existing command; only its reported deterministic fields are compared across arms. Timed MTP generations provide additional complete output hashes. The hot-continuation divergence is not dismissed as the pre-existing sampled B>1 issue.

| 4K prompt | Max abs logit drift | Mean abs drift | Mean KL(ref || flag), nats | Top-1 agreement | Independent greedy16 identical |
|---|---:|---:|---:|---:|---|
"""
for r in stress {tables += "\n| \(r["prompt"]!) | \(f(n(r,"max_abs"),6)) | \(f(n(r,"mean_abs"),6)) | \(f(n(r,"kl_ref_to_flag_mean"),9)) | \(r["top1_agree"]!)/16 | \(r["greedy_exact"]!) |"}
tables += """


| Verify width at 16K | Max abs drift | Mean abs drift | Mean KL(ref || flag), nats | Top-1 agreement | Different float32 bit patterns |
|---:|---:|---:|---:|---:|---:|
"""
for r in verify {tables += "\n| \(r["width"]!) | \(f(n(r,"max_abs"),6)) | \(f(n(r,"mean_abs"),6)) | \(f(n(r,"kl_ref_to_flag_mean"),9)) | \(r["top1_agree"]!)/\(r["rows"]!) | \(r["different_bits"]!)/\(r["values"]!) |"}
tables += "\n\nAll full-vocabulary comparisons use the same reference token history. The stress corpus samples 31,784,960 float32 values; verify samples 3,973,120. Bit equality is checked without a tolerance. Large `.safetensors` remain in `/tmp/s5/quality`, not the repository.\n\n"
text=text.replacingOccurrences(of:"## Protocol",with:tables+"## Protocol")
try text.write(toFile:p+"/REPORT.md",atomically:true,encoding:.utf8)
print("report decode cells \(decode.count)")

import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let control = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("control.json"))) as! [String: Any]
let comparisons = control["comparisons"] as! [String: Any]
func write(_ value: Any, _ url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]); data.append(10)
    try data.write(to: url)
}
for key in ["upstream_self", "fork_self"] { precondition((comparisons[key] as! [String: Any])["identical"] as! Bool == false) }
for key in ["upstream_1_vs_fork_2", "upstream_2_vs_fork_1"] { precondition((comparisons[key] as! [String: Any])["identical"] as! Bool) }
let reason = "Stopped after control 1 per instruction: upstream is not self-consistent; fork reproduces exactly the same two complete output variants."
let perf: [[String: Any]] = [("decode",1),("decode",4),("decode",8),("verify",3),("verify",5),("verify",8),("prefill",4096),("prefill",16384)].map {
    ["workload": $0.0, "size": $0.1, "upstream": NSNull(), "fork": NSNull(), "change_pct": NSNull(), "status": "NOT_RUN", "reason": reason]
}
let quality: [String: Any] = ["status": "NOT_RUN", "arm": "H", "thinking": "off", "planned_task_count": 21, "tasks_run": 0,
    "table": [["both_pass": NSNull(), "only_upstream": NSNull(), "only_fork": NSNull(), "both_fail": NSNull()]],
    "gate": "NOT_EVALUATED", "planned_rule": "only_upstream <= only_fork AND pass-to-fail task drops <= 1", "reason": reason]
let result: [String: Any] = ["status": "DONE", "slice": "20261030-5-s4-div", "stopped_after_step": 1,
    "control_result": ["result": "PRE_EXISTING_NONDETERMINISM", "upstream_self": comparisons["upstream_self"]!, "fork_self": comparisons["fork_self"]!,
        "upstream_1_vs_fork_2": comparisons["upstream_1_vs_fork_2"]!, "upstream_2_vs_fork_1": comparisons["upstream_2_vs_fork_1"]!,
        "fresh_processes_per_build": 2, "target_tokens_per_run": 480, "unique_complete_output_variants": 2,
        "same_seed": [100,101,102], "case": 242],
    "classification": ["label": "bit-identical except nondeterminism", "scope": "Observed case-242 variants and the prior measured logit rows; not a claim about all tensors or all workloads.",
        "matched_cross_build_output_variants": 2, "matching_tokens_each_variant": 480, "same_arm_equal_positions": 85, "same_arm_total_positions": 480,
        "previous_integration_logit_rows": 288, "previous_integration_float32_values": 71516160, "previous_integration_different_float_bits": 0, "previous_integration_max_abs_diff": 0,
        "new_logit_metrics": "NOT_RUN: conditional step 2 not reached", "upstream_B1_vs_B3_reference_metrics": "NOT_RUN: conditional step 2 not reached"],
    "perf_table": perf, "perf_gate": "NOT_EVALUATED", "completed_abba_cycles": 0,
    "quality_gate": quality,
    "recommendation": ["decision": "keep", "scope": "Keep the uncommitted fork candidate; the sampled mismatch is not grounds to kill it.",
        "promotion_approved": false, "qualification": "Fresh performance and task-quality gates remain unevaluated under the explicit stop-after-control rule."],
    "method": ["binary_rebuilt": false, "engine_harness_modified": false, "gpu_lock": "/tmp/strim-bench.lock",
        "isolation": "Existing STRIM_CD_* filters select sampled/mixed/B=3/auto, one round, 160 tokens. Existing harness retains 3 solo references and 1 warmup per fresh process, resets prefix cache before every generation, and closes sessions afterward. No preceding full-matrix cases replayed.",
        "execution": "headless CLI", "servers_started": 0, "ports_used": [], "persistent_engine_state": "none; in-memory sessions only", "scratch_helpers": "/tmp/s4/divergence"],
    "cleanup": ["all_four_processes_exited_normally": true, "owned_processes_remaining": 0, "models_modified": false, "committed": false, "dependency_files_modified": false],
    "evidence": ["control.json", "raw/upstream-1.txt", "raw/upstream-2.txt", "raw/fork-1.txt", "raw/fork-2.txt", "raw/run-controls.log", "raw/provenance.txt"]]
try write(result, dir.appendingPathComponent("result.json"))
let qualityDir = dir.deletingLastPathComponent().appendingPathComponent("quality")
try FileManager.default.createDirectory(at: qualityDir, withIntermediateDirectories: true)
try write(quality, qualityDir.appendingPathComponent("result.json"))

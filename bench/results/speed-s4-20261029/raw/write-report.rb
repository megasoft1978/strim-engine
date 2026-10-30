require 'json'
root='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-20261029'
a=JSON.parse(File.read(root+'/raw/analysis.json'))
v=JSON.parse(File.read(root+'/raw/validation.json'))
cap=a['cap']; fuse=a['fuse']
c8=cap.find{|r|r['kind']=='decode' && r['size']==8}
c1=cap.find{|r|r['kind']=='decode' && r['size']==1}
noise=c1['cycles'].map{|c|c['same_arm_drift_pct']}.max
keep4a=c8['change_pct']>=2 && c1['change_pct']>=-noise && v['quality']['cap8']['greedy_prompts_identical']==8 && v['cap'].all?{|r|r['all_hashes_identical']}
raise 'cap did not pass expected keep rule; report must be reassessed' unless keep4a
raise 'expected two complete cycles' unless (cap+fuse).all?{|r|r['cycles'].size==2}
puts "cap keep #{keep4a}; c1 noise #{noise}"
def f(x,n=2); format("%.#{n}f",x); end
report="# S4 — qmv cap and GDN projection fusion (2026-10-29)\n\n"
report<<"**4a KEEP as a local patch and vendor plan only. 4b KILL; no engine code changed in the real repository.**\n\n"
report<<"Base a112d0d, mlx-swift exact 0.32.3, Apple M5 Max. Two independent ABBA cycles per part; three measured repetitions per block (12 per arm/cell), plus excluded warmups. All GPU runs held `/tmp/strim-bench.lock`. Headless in-process measurements; no servers or GUI actions. Models were read-only. See [method.md](method.md) and [raw/analysis.json](raw/analysis.json) for workload/timing definitions, every sample, noise and per-cycle ratios.\n\n"
report<<"## 4a — M5-family qmv_wide tile cap 5 → 8\n\n"
report<<"The cap is in `qmv_wide`'s tile calculation, **not** `get_qmv_batch_limit`; the latter's dispatch thresholds are unchanged. The predicate matches the M5 Max dispatch path (architecture generation >=17, size != 'd'); other paths retain cap 5. This reduces M=8 from two four-vector tiles to one eight-vector tile. Both arms keep Swift fusion OFF.\n\n"
report<<"| c | Base aggregate tok/s | Cap-8 aggregate tok/s | Change | Base per-request decode tok/s | Cap-8 per-request decode tok/s |\n|---:|---:|---:|---:|---:|---:|\n"
cap.select{|r|r['kind']=='decode'}.sort_by{|r|r['size']}.each{|r|report<<"| #{r['size']} | #{f(r['base'])} | #{f(r['candidate'])} | #{f(r['change_pct'])}% | #{f(r['request_base'])} | #{f(r['request_candidate'])} |\n"}
report<<"\nRates exclude prefill and count fixed 64-step lockstep decode. They are not HTTP request throughput.\n\n"
report<<"| Verify width | Base ms/pass | Cap-8 ms/pass | Time change |\n|---:|---:|---:|---:|\n"
cap.select{|r|r['kind']=='verify'}.sort_by{|r|r['size']}.each{|r|report<<"| #{r['size']} | #{f(r['base'])} | #{f(r['candidate'])} | #{f(r['change_pct'])}% |\n"}
report<<"\nVerify timing isolates the target pass with rollback-state recording, not drafting or MTP head replay. Widths 3/5 (normal depth 2/4) do not change tiles and show no supported improvement; width 8 exercises the patch.\n\n"
report<<"| Metric | ABBA cycle 1 change | Cycle 1 same-arm drift | ABBA cycle 2 change | Cycle 2 same-arm drift |\n|---|---:|---:|---:|---:|\n"
cap.each do |r|
  x,y=r['cycles'];report<<"| #{r['kind']} #{r['size']} | #{f(x['gain_pct'])}% | #{f(x['same_arm_drift_pct'])}% | #{f(y['gain_pct'])}% | #{f(y['same_arm_drift_pct'])}% |\n"
end
report<<"\nCycle changes are ratios of geometric arm means; main tables use medians of block medians. Drift is the maximum A-to-A or B-to-B change within the cycle. The initial c=4 control was noisy (unchanged kernel), so no c=4 benefit is inferred.\n\n"
report<<"Keep gate: c=8 aggregate **#{f(c8['change_pct'])}%**, above +2% in each cycle; c=1 **#{f(c1['change_pct'])}%**, within its measured **#{f(noise)}%** drift floor. Every c=1/4/8 timed row and every verify-width row has the same greedy hashes across both arms and all repeats. All eight corpus greedy outputs match (512 tokens), all 512 teacher-forced choices agree, and all 64 sampled full-vocab logit rows have zero bit differences. These sampled logit checks do not establish bit identity of every internal value in the changed c=8 kernel.\n\n"
report<<"Exact patch: [qmv-cap8.patch](qmv-cap8.patch). Source matched the pinned MLX submodule before editing; reverse dry-run succeeds ([patch validation](raw/patch-validation.txt)). [vendor-plan.md](vendor-plan.md) describes follow-up integration. **No fork, push, real Package.swift change or vendoring was performed.**\n\n"
report<<"## 4b — one qkv/z/b/a quantized projection\n\n"
report<<"Scratch-only, on the **unpatched cap-5** binary: concatenate 10240+6144+48+48 output rows, validate equal quantization specs, materialize once, replace original resident weights, run one quantized matmul and split.\n\n"
report<<"| Prefill | Base tok/s | Fused tok/s | Change | Cycle 1 change / drift | Cycle 2 change / drift |\n|---|---:|---:|---:|---:|---:|\n"
fuse.sort_by{|r|r['size']}.each do |r|
 x,y=r['cycles'];report<<"| #{r['size']/1024}K | #{f(r['base'])} | #{f(r['candidate'])} | #{f(r['change_pct'])}% | #{f(x['gain_pct'])}% / #{f(x['same_arm_drift_pct'])}% | #{f(y['gain_pct'])}% / #{f(y['same_arm_drift_pct'])}% |\n"
end
report<<"\nTarget prefill only, fixed 1024-token chunks, no MTP head seeding. The +0.3% beyond-noise speed gate is not met.\n\n"
report<<"| Bench prompt | Max absolute logit difference | Teacher-forced greedy agreement | Independent 64-token greedy output identical |\n|---|---:|---:|---|\n"
v['quality']['fuse']['rows'].each{|r|report<<"| #{r['prompt']} | #{r['max_abs_diff']} | #{r['teacher_forced_agreement']}/64 | #{r['free_greedy_identical'] ? 'yes' : 'no'} |\n"}
q=v['quality']['fuse']
report<<"\nOverall: max absolute logit difference **#{q['max_abs_diff']}**, **#{q['different_float_bits']}** differing float32 bit patterns across 64 sampled vocab rows; **#{q['teacher_forced_agreement']}/#{q['tokens']}** teacher-forced choices agree; only **#{q['greedy_prompts_identical']}/8** independent greedy outputs match. **Not exact.** The narrow reference b/a matmuls use split-K at prefill sizes; merging into the wide projection changes reduction association. This is consistent with the observed drift, rather than an exact-preserving dispatch reduction.\n\n"
report<<"**KILL**: speed gate fails and bit identity fails. No near-exact-tier claim or opt-in production flag is shipped; checkbatchparity/agentbench promotion gates were not run because the speed candidate is rejected. Scratch patches and harness remain in raw results for reproduction. No real Qwen/GDN/WeightStore source or tests were edited, so no new repository tests are needed for the rejected candidate.\n\n"
report<<"## Validation and artifacts\n\n"
report<<"Both release builds succeeded. [raw/validation.json](raw/validation.json) checks 24 measured rows per cell, complete two-cycle schedules, hash consistency and all eight quality prompts per arm. Token sequences, JSONL, system/load samples, compiler logs, source patches, harness and analysis scripts are retained under [raw/](raw/). Full reference/candidate logit tensors are scratch artifacts under `/tmp/s4/quality`; no large tensor binaries were added to the repo. No GPU processes or servers started by S4 remain after completion. No commits were made. Existing unrelated working-tree changes were left untouched.\n"
File.write(root+'/REPORT.md',report)
results={slice:'20261029-5-s4',parts:{'4a'=>{decision:'KEEP_PATCH_ONLY',c1_noise_floor_pct:noise,decode:cap.select{|r|r['kind']=='decode'},verify:cap.select{|r|r['kind']=='verify'},quality:v['quality']['cap8'].reject{|k,v|k=='rows'}},'4b'=>{decision:'KILL',prefill:fuse,quality:q}},engine_files_changed:[],tests_added:[],validation:'raw/validation.json',method:'method.md',raw:'raw/'}
File.write(root+'/results.json',JSON.pretty_generate(results)+"\n")

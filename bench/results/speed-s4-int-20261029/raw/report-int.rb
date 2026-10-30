require 'json'
require 'digest'
ROOT='/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029'
REPO=File.dirname(File.dirname(File.dirname(ROOT)))
def read(name);JSON.parse(File.read("#{ROOT}/raw/#{name}.json"));end
gates=read('gates');quality=read('quality');tests=read('tests');analysis=read('analysis')
expected=%w[gen16 benchspec0 prefix4096 prefix8192 engine batch1 batch4 batch6 batch7 batch8]
raise 'incomplete CLI gates' unless gates.keys.sort==expected.sort
raise 'quality gate differs' unless gates.values.all?{|g|g['identical']} && quality.values.all?{|q|q['different_float_bits']==0 && q['max_abs_diff']==0 && q['tokens']==q['argmax_agreement']}
raise 'test failures' unless tests['exit_code']==0 && tests['failures'].empty?
engine=gates['engine']['base'].grep(/^S4_ENGINE /).map{|l|JSON.parse(l.sub(/^S4_ENGINE /,''))}
raise "incomplete default engine matrix: #{engine.size}" unless engine.size==256
engine_info={runs_per_arm:engine.size,sequences_per_arm:engine.sum{|r|r['tokens'].size},generated_tokens_per_arm:engine.sum{|r|r['tokens'].sum(&:size)},all_tokens_identical:true}
order={'decode'=>0,'verify'=>1,'prefill'=>2}
rows=analysis['rows'].sort_by{|r|[order.fetch(r['kind']),r['size']]}
compact_rows=rows.map{|r|r.reject{|k,v|k=='blocks'}}
files=['Package.swift','Package.resolved','docs/SWIFT-PERF.md','bench/results/speed-s4-int-20261029/']
result={status:analysis['keep'] ? 'DONE' : 'BLOCKED',summary:analysis['keep'] ? 'Fork integrated; exact gates and performance keep rule pass.' : 'Performance keep rule failed.',
  revisions:{engine:'a112d0d16895d5612a3f86811ca9a368ca96ddaf',mlx_swift_fork:'d881bd905948fb3e5e46864dc47cf29a8b19fde4',mlx_fork:'575068a4fa263b16ac08921751e8a5257f3e80b9',upstream_mlx_swift:'19601207e9a0de51e03ee6ec0c3c5f3784275075',upstream_mlx:'1f8e74e3f12f31365464a6867c6579f0e9b29d85'},
  gates:gates.transform_values{|g|{identical:g['identical']}},quality:quality.transform_values{|v|v.reject{|k,v|k=='rows'}},engine:engine_info,
  abba:compact_rows,performance_keep:analysis['keep'],c1_noise_pct:analysis['c1_noise_pct'],tests:tests.reject{|k,v|k=='swift_testing'}.merge('swift_testing'=>tests['swift_testing'].reject{|k,v|%w[summary_runs skip_lines].include?(k)}),
  files_changed:files,committed:false,headless:true,live_gui:'not enabled',blockers:analysis['keep'] ? [] : ['Performance keep rule failed; see ABBA controls.']}
File.write("#{ROOT}/result.json",JSON.pretty_generate(result)+"\n")
c8=rows.find{|r|r['kind']=='decode'&&r['size']==8};c1=rows.find{|r|r['kind']=='decode'&&r['size']==1}
md="# S4 remote-fork integration (2026-10-29)\n\n"
md+="**#{result[:status]}** — #{result[:summary]} No commit was made.\n\n"
md+="Fresh upstream 0.32.3 and remote-fork `0.32.3-strim.1` release builds on M5 Max, both from HEAD archives. See [method.md](method.md), [result.json](result.json), and [raw/provenance.txt](raw/provenance.txt).\n\n"
md+="## Exact gates\n\nAll ten paired CLI gate cases passed: gen16, depth-0 benchspec EXACT, prefix 4096/8192 + MTP, the full concurrent-decode engine matrix, and checkbatchparity B=1/4/6/7/8. All tokens, hashes, margins and verdicts compared across identical policies match. Existing B=1 versus B>1 differences are retained unchanged in the raw parity logs.\n\n"
md+="Sampled full-vocab logits are bit-identical: 208 batched-decode rows at c=1/4/6/7/8, 16 verify rows at widths 3/5/8, and 64 corpus rows (288 rows total). Zero differing float32 bits and zero max absolute difference. All 2,192 checked argmax choices match; all eight independent 64-token corpus outputs match. This does not assert identity of every internal tensor or unmeasured state/device.\n\n"
md+="The engine matrix has #{engine_info[:runs_per_arm]} runs / #{engine_info[:sequences_per_arm]} sequences per arm, including #{engine_info[:generated_tokens_per_arm]} generated tokens per arm; every recorded output token matches. Raw command output and exact comparison rules are under [raw/gates/](raw/gates/) and [raw/gates-int.rb](raw/gates-int.rb).\n\n"
md+="## Two ABBA cycles\n\nMedians of block medians; 3 measured reps plus 1 excluded warmup per block/cell. Decode counts 64 lockstep steps; verify counts 12 fixed-state passes; prefill uses 1024-token chunks. Decode rates exclude prefill and are in-process aggregate throughput, not HTTP throughput.\n\n"
md+="| Workload | Unit | Upstream | Fork | Change | Cycle 1 change / noise | Cycle 2 change / noise | Peak active GiB upstream / fork |\n|---|---|---:|---:|---:|---:|---:|---:|\n"
rows.each do |r|
  cycles=r['cycles'].sort_by{|c|c['cycle']}.map{|c|format('%+.2f%% / %.2f%%',c['change_pct'],c['noise_pct'])}
  md+=format("| %s %d | %s | %.2f | %.2f | %+.2f%% | %s | %s | %.3f / %.3f |\n",r['kind'],r['size'],r['unit'],r['base'],r['fork'],r['change_pct'],*cycles,r['base_peak_bytes']/2.0**30,r['fork_peak_bytes']/2.0**30)
end
md+="\nVerify changes are changes in time (negative is faster); throughput changes are positive when faster. Noise is maximum within-cycle A-to-A or B-to-B drift. Full samples, block medians, controls and peak bytes are retained in [raw/analysis.json](raw/analysis.json). Every timed output hash (and prefill full-logit hash) matched across all blocks.\n\n"
md+=format("Keep rule: c=8 aggregate %+.2f%% (required >=+2%%); c=1 %+.2f%% versus %.2f%% measured noise; outputs identical. **%s**. Widths 3/5 do not support a promised normal-depth MTP speedup. Only this M5 Max was measured; other paths covered by the >=17 predicate remain unmeasured.\n\n",c8['change_pct'],c1['change_pct'],analysis['c1_noise_pct'],analysis['keep'] ? 'KEEP' : 'FAIL')
md+="## Full test run\n\n`swift test --package-path /tmp/s4/src-int --scratch-path /tmp/s4/build-int` ran once, under the GPU lock, and exited 0: **1,790 passed, 45 skipped, zero failures** (XCTest 113/14; Swift Testing 1,677/31). The failed release test-build preparation ran no tests; the completed suite used normal debug configuration. No tests, thresholds or goldens were changed. All executed checks were headless or windowless; live GUI smoke was not enabled. See [raw/tests.json](raw/tests.json) for skip details.\n\n"
md+="The three owned integration files and this result directory are the only task changes. Unrelated agentbench work was excluded from the archives and left untouched. No benchmark HTTP servers were started. Every GPU command held `/tmp/strim-bench.lock`, waiting for other work without breaking it. Models were read-only. Rollback is the original exact upstream 0.32.3 dependency plus a regenerated lockfile.\n"
File.write("#{ROOT}/REPORT.md",md)
puts result[:status]
puts engine_info
puts format('c8 %+.3f%%, c1 %+.3f%%, c1 noise %.3f%%',c8['change_pct'],c1['change_pct'],analysis['c1_noise_pct'])

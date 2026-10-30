import Foundation
let p="bench/results/speed-s5-20261030/result.json"
var j=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:p))) as! [String:Any]
var rows:[[String:Any]]=[]
for ctx in [4096,16384,32768] {for c in [1,4] {
    let path="/tmp/s5/abba/1-A/ctx\(ctx)-c\(c).jsonl"
    guard let s=try? String(contentsOfFile:path,encoding:.utf8) else{continue}
    let rs=s.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}.filter{($0["type"] as? String)=="decode"}
    if rs.count == 3 {
        let values=rs.map{($0["aggregate_tps"] as! NSNumber).doubleValue}.sorted()
        rows.append(["block":1,"arm":"A","ctx":ctx,"c":c,"aggregate_tps_median":values[1],"reps":3,"candidate_tps":NSNull(),"delta_pct":NSNull()])
    }
}}
j["partial_decode"]=rows
j["cleanup"]=["owned_processes_remaining":0,"unowned_processes_signalled":0,"ports_used":[],"recursive_deletes":0,"commit_made":false]
let stress=j["quality_stress"] as! [[String:Any]]
if stress.count==8 {
    func n(_ r:[String:Any],_ k:String)->Double {(r[k] as! NSNumber).doubleValue}
    var summary:[String:Any]=[:]
    summary["stress_greedy_identical"]=stress.filter{($0["greedy_exact"] as! Bool)}.count
    summary["stress_prompts"]=8
    summary["teacher_top1_agree"]=stress.reduce(0){$0+($1["top1_agree"] as! Int)}
    summary["teacher_rows"]=128
    summary["max_abs"]=stress.map{n($0,"max_abs")}.max()!
    summary["mean_abs"]=stress.map{n($0,"mean_abs")}.reduce(0.0,+)/8.0
    summary["mean_KL"]=stress.map{n($0,"kl_ref_to_flag_mean")}.reduce(0.0,+)/8.0
    j["quality_summary"]=summary
}
j["blocker"]="Unowned evolve PID 70044 holds /tmp/strim-bench.lock for a search with --budget-minutes 720. No unowned process was signalled. The S5 queued process was stopped under the requested cleanup rule; rerun /tmp/s5/abba.sh after the shared GPU becomes available."
try JSONSerialization.data(withJSONObject:j,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:p))
print(rows)

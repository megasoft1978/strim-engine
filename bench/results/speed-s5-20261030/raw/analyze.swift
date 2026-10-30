import Foundation
let root="/tmp/s5"
func read(_ path:String)->[[String:Any]] { guard let s=try? String(contentsOfFile:path,encoding:.utf8) else{return []}; return s.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]} }
func num(_ row:[String:Any],_ key:String)->Double { (row[key] as! NSNumber).doubleValue }
func med(_ xs:[Double])->Double { let s=xs.sorted(); return (s[(s.count-1)/2]+s[s.count/2])/2 }
let schedule=["A","B","B","A","A","B","B","A"]
var tables:[[String:Any]]=[]
for ctx in [4096,16384,32768] { for c in [1,4] {
    var blocks:[[String:Any]]=[], aa:[Double]=[],bb:[Double]=[], outputMismatch=0
    let ref=read("\(root)/abba/1-A/ctx\(ctx)-c\(c).jsonl")
    for (idx,arm) in schedule.enumerated() {
        let rows=read("\(root)/abba/\(idx+1)-\(arm)/ctx\(ctx)-c\(c).jsonl")
        let measured=rows.filter{($0["type"] as? String)=="decode"}
        if measured.count != 3 {continue}
        let m=med(measured.map{num($0,"aggregate_tps")})
        if arm=="A" {aa.append(m)} else {bb.append(m)}
        for r in rows where ["decode","warmup"].contains(r["type"] as? String ?? "") {
            if let expected=ref.first(where:{($0["rep"] as? Int)==(r["rep"] as? Int)}) {
                if (r["hashes"] as! [String]) != (expected["hashes"] as! [String]) {outputMismatch += 1}
            }
        }
        blocks.append(["index":idx+1,"arm":arm,"median_tps":m])
    }
    if aa.count != 4 || bb.count != 4 {continue}
    var noise=0.0
    for xs in [aa,bb] {for i in [0,2] {noise=max(noise,abs(xs[i+1]/xs[i]-1)*100)}}
    let effects=[0,2].map { i in (sqrt(bb[i]*bb[i+1]/(aa[i]*aa[i+1]))-1)*100 }
    tables.append(["ctx":ctx,"c":c,"A_tps":med(aa),"B_tps":med(bb),"delta_pct":(med(bb)/med(aa)-1)*100,
                   "cycle_effect_pct":effects,"noise_pct":noise,"output_mismatch_reps":outputMismatch,"blocks":blocks])
} }
let qa=read(root+"/quality/A/stress.jsonl"), qb=read(root+"/quality/B/stress.jsonl")
let va=read(root+"/quality/A/verify.jsonl"), vb=read(root+"/quality/B/verify.jsonl")
var quality:[[String:Any]]=[]
for var row in qb {row["baseline_hash"]=qa.first{($0["prompt"] as? String)==(row["prompt"] as? String)}?["hash"]; quality.append(row)}
var verify:[[String:Any]]=[]
for var row in vb {row["baseline_hash"]=va.first{($0["width"] as? Int)==(row["width"] as? Int)}?["hash"]; verify.append(row)}
let result:[String:Any]=["decode":tables,"quality_stress":quality,"quality_verify":verify,"completed_decode_cells":tables.count]
let d=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]); try d.write(to:URL(fileURLWithPath:root+"/analysis.json"))
print("decode cells \(tables.count)/6; stress \(qb.count)/8; verify \(vb.count)/3")
for r in tables {print(String(format:"ctx=%d c=%d A=%.3f B=%.3f delta=%+.3f%% noise=%.3f%%",r["ctx"] as! Int,r["c"] as! Int,num(r,"A_tps"),num(r,"B_tps"),num(r,"delta_pct"),num(r,"noise_pct")))}

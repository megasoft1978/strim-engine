import Foundation
let file=CommandLine.arguments[1]
let rows=try String(contentsOfFile:file,encoding:.utf8).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
func num(_ r:[String:Any],_ k:String)->Double { (r[k] as! NSNumber).doubleValue }
func med(_ x:[Double])->Double { let s=x.sorted(); return (s[(s.count-1)/2]+s[s.count/2])/2 }
for b in [1,4] { for s in [1,3,5,8] {
    let x=rows.filter { ($0["B"] as? Int)==b && ($0["S"] as? Int)==s }
    let blocks=x.filter { ($0["type"] as? String)=="block" }
    if blocks.count != 8 { continue }
    let aa=blocks.filter{($0["arm"] as? String)=="A"}.map{num($0,"ms48")}
    let bb=blocks.filter{($0["arm"] as? String)=="B"}.map{num($0,"ms48")}
    var noise=0.0
    for xs in [aa,bb] { for i in [0,2] { noise=max(noise,abs(xs[i+1]/xs[i]-1)*100) } }
    let samples=x.filter{ ($0["type"] as? String)=="sample" }
    var row:[String:Any]=["B":b,"S":s,"A_eval_ms48":med(aa),"B_eval_ms48":med(bb),"saved_eval_ms48":med(aa)-med(bb),"same_arm_noise_pct":noise]
    for arm in ["A","B"] {
        let ms=samples.filter{ ($0["arm"] as? String)==arm }.compactMap{($0["build_ms48"] as? NSNumber)?.doubleValue}
        if !ms.isEmpty {row[arm+"_build_ms48"]=med(ms)}
    }
    print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
} }

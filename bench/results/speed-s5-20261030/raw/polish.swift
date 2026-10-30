import Foundation
let root="bench/results/speed-s5-20261030"
let path=root+"/result.json"
var j=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
var parts=j["parts"] as! [[String:Any]]
parts[1]["decision"]="KEEP_OPT_IN_PROVISIONAL"
parts[1]["performance_status"]="ABBA_BLOCKED_UNVALIDATED"
j["parts"]=parts
try JSONSerialization.data(withJSONObject:j,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
let rp=root+"/REPORT.md"
var s=try String(contentsOfFile:rp,encoding:.utf8)
s=s.replacingOccurrences(of:"**(b) Pre-recurrence GDN fusion:**",with:"**(b) Pre-recurrence GDN fusion — KEEP provisionally as an opt-in experiment; speed unvalidated:**")
s=s.replacingOccurrences(of:"| 1 |\n",with:"| yes |\n").replacingOccurrences(of:"| 0 |\n",with:"| no |\n")
try s.write(toFile:rp,atomically:true,encoding:.utf8)

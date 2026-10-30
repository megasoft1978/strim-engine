import Foundation
let root="/tmp/s5", dest="bench/results/speed-s5-20261030"
func read(_ p:String)->String { (try? String(contentsOfFile:p,encoding:.utf8)) ?? "" }
func json(_ p:String)->[String:Any] { (try? JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:p)))) as? [String:Any] ?? [:] }
func rows(_ p:String)->[[String:Any]] {read(p).split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]} }
func line(_ s:String,_ prefix:String)->String {s.split(separator:"\n").map(String.init).first{$0.hasPrefix(prefix)} ?? ""}
var result=json(root+"/analysis.json")
result["status"]=(result["completed_decode_cells"] as? Int)==6 ? "DONE" : "PARTIAL"
let micros=(1...4).map { i -> [String:Any] in ["run":i,"summary":rows(root+"/micro\(i)-summary.jsonl"),"meta":rows(root+"/micro\(i).jsonl").first ?? [:]] }
result["microbench"]=micros
result["parts"]=[
    ["part":"a","decision":"SKIP_ALREADY_IMPLEMENTED","reason":"All verify queries already share one causal SDPA call per attention layer."],
    ["part":"b","decision":"IMPLEMENTED_OPT_IN_SPEED_NOT_VALIDATED","flag":"STRIM_GDN_PRE_FUSE=1","default":"OFF","micro_gate":"Marginal and load-dependent; advanced to full evaluation to avoid an unsupported kill based on noisy micrographs."]
]
result["default_proposal"]=false
result["default_rejection_reasons"]=["Strict bit-identity gate fails (stress generation, verify hashes and continuation).", "Complete paired ABBA speed comparison is unavailable."]
result["head"]="a03dc65fa6dbd916400b2264210a132cae018dc0"
result["slice"]="20261030-5-s5"
result["decode_policy"]="roundrobin (MTP retained at c=4)"
result["prior_s4_noise_pct"]=0.34
result["binary_sha256"]=read(root+"/binary-before.sha256").trimmingCharacters(in:.whitespacesAndNewlines)
let gA=line(read(root+"/quality/A/gen16.txt"),"ids:"),gB=line(read(root+"/quality/B/gen16.txt"),"ids:")
result["gen16"]=["A":gA,"B":gB,"identical":!gA.isEmpty && gA==gB]
var prefix:[[String:Any]]=[]
for n in [4096,8192] {
    let a=read(root+"/quality/A/prefix\(n).txt"),b=read(root+"/quality/B/prefix\(n).txt")
    // Deterministic fields printed by the existing check: reference hash+16 IDs and MTP's first 8 IDs.
    let fields: (String)->[String] = { s in s.split(separator:"\n").map(String.init).filter{$0.hasPrefix("  hash ") || $0.hasPrefix("  miss ref:")}.map { l in
        if l.hasPrefix("  hash ") {return l.replacingOccurrences(of:"\\s+[0-9]+\\.[0-9]+ s$",with:"",options:.regularExpression)}
        if let r=l.range(of:"  prefill ") {return String(l[..<r.lowerBound])}
        return l
    } }
    prefix.append(["ctx":n,"A_all_pass":a.contains("checkprefix: ALL PASS"),"B_all_pass":b.contains("checkprefix: ALL PASS"),"reported_reference_fields_identical":!fields(a).isEmpty && fields(a)==fields(b),"A_fields":fields(a),"B_fields":fields(b),"A_hot_continuation":line(a,"  hot-continue vs cold:"),"B_hot_continuation":line(b,"  hot-continue vs cold:"),"A_hot_tokens":line(a,"  hot: turn1"),"B_hot_tokens":line(b,"  hot: turn1")])
}
result["checkprefix_mtp"]=prefix
result["tests"]=["release_build":true,"release_test_preparation":"module-resolution failure; see raw/build-tests.log","debug_initial_gpu_test":"metallib lookup failed; see raw/tests-initial.log","debug_final_log":read(root+"/tests-final.log")]
result["files_changed"]=["Sources/StrimCore/GDN.swift","Sources/StrimCore/GDNPre.swift","Sources/StrimCLI/Cmd_SdpaMicro.swift","Sources/StrimCLI/Cmd_GDNPreMicro.swift","Sources/StrimCLI/Cmd_S5.swift","Tests/StrimCoreTests/GDNPreTests.swift",dest+"/"]
let d=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]); try d.write(to:URL(fileURLWithPath:dest+"/result.json"))
print("wrote \(dest)/result.json")

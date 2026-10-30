import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let originalPath = root.deletingLastPathComponent().appendingPathComponent("raw/gates/engine-live-diff.json")
let original = try JSONSerialization.jsonObject(with: Data(contentsOf: originalPath)) as! [String: Any]
let target = original["base"] as! [String: Any]
func rows(_ path: URL) throws -> [[String: Any]] {
    try String(contentsOf: path, encoding: .utf8).components(separatedBy: .newlines).filter { $0.hasPrefix("S4_ENGINE ") }.map {
        try JSONSerialization.jsonObject(with: Data($0.dropFirst(10).utf8)) as! [String: Any]
    }
}
func match(_ row: [String: Any]) -> Bool {
    (row["mode"] as? String) == (target["mode"] as? String) && (row["policy"] as? String) == (target["policy"] as? String) && (row["prompts"] as? [String]) == (target["prompts"] as? [String]) && (row["seeds"] as? [Int]) == (target["seeds"] as? [Int])
}
func digest(_ ids: [Int]) -> String {
    ids.map(Int32.init).withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
}
func compare(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
    let aa = a["tokens"] as! [[Int]], bb = b["tokens"] as! [[Int]]
    precondition(aa.count == bb.count)
    var sequences: [[String: Any]] = []
    var equalTokens = 0, totalTokens = 0
    for i in aa.indices {
        let n = min(aa[i].count, bb[i].count)
        let first = (0..<n).first { aa[i][$0] != bb[i][$0] } ?? (aa[i].count == bb[i].count ? nil : n)
        let eq = (0..<n).filter { aa[i][$0] == bb[i][$0] }.count
        equalTokens += eq; totalTokens += max(aa[i].count, bb[i].count)
        sequences.append(["sequence": i, "first_difference": first.map { $0 as Any } ?? NSNull(),
            "left_token": first.flatMap { $0 < aa[i].count ? aa[i][$0] : nil }.map { $0 as Any } ?? NSNull(),
            "right_token": first.flatMap { $0 < bb[i].count ? bb[i][$0] : nil }.map { $0 as Any } ?? NSNull(),
            "left_length": aa[i].count, "right_length": bb[i].count, "equal_token_positions": eq,
            "left_sha256": digest(aa[i]), "right_sha256": digest(bb[i])])
    }
    return ["identical": aa == bb, "equal_token_positions": equalTokens, "total_token_positions": totalTokens, "sequences": sequences]
}
var runs: [String: [String: Any]] = [:]
for arm in ["upstream", "fork"] {
    for rep in 1...2 {
        let key = "\(arm)-\(rep)"
        let path = root.appendingPathComponent("raw/\(key).txt")
        let text = try String(contentsOf: path, encoding: .utf8)
        precondition(text.contains("enginebench: ALL PASS"), "incomplete/failed run \(key)")
        let all = try rows(path)
        let selected = all.filter(match)
        precondition(all.count == 5 && selected.count == 1, "unexpected cases \(key)")
        precondition((selected[0]["tokens"] as! [[Int]]).allSatisfy { $0.count == 160 })
        runs[key] = selected[0]
    }
}
var comparisons: [String: Any] = [:]
for arm in ["upstream", "fork"] { comparisons["\(arm)_self"] = compare(runs["\(arm)-1"]!, runs["\(arm)-2"]!) }
comparisons["fresh_cross_1"] = compare(runs["upstream-1"]!, runs["fork-1"]!)
comparisons["fresh_cross_2"] = compare(runs["upstream-2"]!, runs["fork-2"]!)
comparisons["upstream_1_vs_fork_2"] = compare(runs["upstream-1"]!, runs["fork-2"]!)
comparisons["upstream_2_vs_fork_1"] = compare(runs["upstream-2"]!, runs["fork-1"]!)
comparisons["original_upstream_vs_fresh_1"] = compare(target, runs["upstream-1"]!)
comparisons["original_fork_vs_fresh_1"] = compare(original["fork"] as! [String: Any], runs["fork-1"]!)
let result: [String: Any] = ["case": 242, "runs": runs, "comparisons": comparisons]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("control.json"))
print(String(decoding: try JSONSerialization.data(withJSONObject: comparisons, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))

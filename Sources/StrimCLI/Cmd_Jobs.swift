import Foundation
import StrimHost
import StrimJobs

// strim jobs list | show <id> | cancel <id> [--port N=8203] [--token-file PATH]
// list/show read ~/.strim/jobs directly (no server needed). cancel is a tools/call of strim_cancel on the
// running server, because only the host process can stop a live job.

func runJobs(_ args: [String]) {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
    let usage = "usage: strim jobs list | show <id> | cancel <id> [--port N=8203] [--token-file PATH]"
    guard args.count >= 3 else { fail(usage) }
    var positional: [String] = []
    var port: UInt16 = 8203
    var tokenPath = HostPaths.default.token.path
    var i = 3
    while i < args.count {
        let a = args[i]
        func value() -> String {
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") { return String(a[a.index(after: eq)...]) }
            i += 1
            guard i < args.count else { fail("missing value for \(a)") }
            return args[i]
        }
        if a == "--port" || a.hasPrefix("--port=") { guard let p = UInt16(value()) else { fail("bad --port") }; port = p }
        else if a == "--token-file" || a.hasPrefix("--token-file=") { tokenPath = value() }
        else if a.hasPrefix("--") { fail("unknown option \(a)") }
        else { positional.append(a) }
        i += 1
    }
    let store = FileJobStore(root: HostPaths.default.jobs)
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var output = ""
    nonisolated(unsafe) var failure: String?
    let sub = args[2]
    Task {
        do {
            switch sub {
            case "list":
                let recs = try await store.list().sorted { $0.createdAt > $1.createdAt }
                let f = ISO8601DateFormatter()
                if recs.isEmpty { output = "no jobs\n" }
                for r in recs {
                    let task = r.task.replacingOccurrences(of: "\n", with: " ")
                    output += "\(r.id)  \(r.status.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0))  \(f.string(from: r.createdAt))  \(task.prefix(60))\n"
                }
            case "show":
                guard let id = positional.first else { failure = usage; break }
                guard let r = try await store.load(id) else { failure = "no such job: \(id)"; break }
                output += "id: \(r.id)\nstatus: \(r.status.rawValue)\(r.reason.map { " (\($0))" } ?? "")\naccess: \(r.access.rawValue)\ncwd: \(r.cwd)\n"
                output += "task: \(r.task)\nturns: \(r.turn)\n"
                if let res = r.result {
                    output += "summary: \(res.summary)\n"
                    for c in res.filesChanged { output += "  \(c.path) +\(c.added) -\(c.removed)\n" }
                    if let p = res.patchPath { output += "patch: \(p)\n" }
                    if let b = res.base { output += "base: \(b)\n" }
                    for c in res.commands { output += "  $ \(c.cmd) -> \(c.exit)\n" }
                }
            case "cancel":
                guard let id = positional.first else { failure = usage; break }
                guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else { failure = "cannot read token file \(tokenPath)"; break }
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
                req.httpMethod = "POST"
                req.timeoutInterval = 10
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                           "params": ["name": "strim_cancel", "arguments": ["job_id": id]]]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let result = obj?["result"] as? [String: Any]
                    let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                    if code != 200 { failure = "server answered HTTP \(code)" }
                    else if result?["isError"] as? Bool == true { failure = text.isEmpty ? "cancel failed" : text }
                    else { output = text.isEmpty ? "cancel requested\n" : text + "\n" }
                } catch {
                    failure = "no strim server on 127.0.0.1:\(port) (\(error.localizedDescription)); a job can only be cancelled while its host runs"
                }
            default:
                failure = usage
            }
        } catch {
            failure = "\(error)"
        }
        sem.signal()
    }
    sem.wait()
    if let failure { fail(failure) }
    print(output, terminator: "")
}

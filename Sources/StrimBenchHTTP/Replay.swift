import CryptoKit
import Foundation

public struct ReplayArm: Sendable, Equatable {
    public enum CacheMode: String, Sendable { case on, off, offByNonce = "off-by-nonce" }
    public var name: String
    public var url: String
    public var model: String
    public var cache: CacheMode = .on
    public var serverLog: String?

    public init(name: String, url: String, model: String, cache: CacheMode = .on, serverLog: String? = nil) {
        self.name = name; self.url = url; self.model = model; self.cache = cache; self.serverLog = serverLog
    }

    /// `NAME=URL,MODEL[,cache=on|off|off-by-nonce]`
    public static func parse(_ spec: String) throws -> ReplayArm {
        let bad = BenchError("bad --arm '\(spec)': want NAME=URL,MODEL[,cache=on|off|off-by-nonce]")
        guard let eq = spec.firstIndex(of: "=") else { throw bad }
        let name = String(spec[..<eq]).trimmingCharacters(in: .whitespaces)
        let parts = spec[spec.index(after: eq)...].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw bad }
        var arm = ReplayArm(name: name, url: parts[0], model: parts[1])
        for opt in parts.dropFirst(2) {
            let kv = opt.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard kv.count == 2, kv[0] == "cache", let m = CacheMode(rawValue: kv[1]) else {
                throw BenchError("bad --arm option '\(opt)' in '\(spec)': want cache=on|off|off-by-nonce")
            }
            arm.cache = m
        }
        return arm
    }

    var json: JSONValue {
        .obj(["name": .string(name), "url": .string(url), "model": .string(model), "cache": .string(cache.rawValue),
              "server_log": JSONValue(serverLog)])
    }
}

public struct ReplayConfig: Sendable {
    public var fixture: String
    public var arms: [ReplayArm]
    public var outDir: String
    public var reps = 2
    public var maxTokens = 48
    public var timeout = 900.0
    public var noSessionSalt = false
    /// final_replay.py behaviour (default): enable_thinking=false and tool_calls/reasoning count as first output.
    /// `classic` reproduces agent_replay.py as written.
    public var classic = false
    public var deadline: Date?

    public init(fixture: String, arms: [ReplayArm], outDir: String) {
        self.fixture = fixture; self.arms = arms; self.outDir = outDir
    }
}

public enum Replay {
    public static let turnRoles: Set<String> = ["user", "tool"]
    public static let minTurns = 3
    public static let maxTurns = 20

    public static func requestPoints(_ messages: [JSONValue]) -> [Int] {
        messages.enumerated().compactMap { turnRoles.contains($0.element["role"].string ?? "") ? $0.offset : nil }
    }

    public static func loadFixture(_ path: String) throws -> (messages: [JSONValue], sha16: String) {
        guard let raw = FileManager.default.contents(atPath: path) else { throw BenchError("fixture \(path): cannot read") }
        let parsed = try JSON.parse(raw)
        guard let messages = parsed.array, !messages.isEmpty else {
            throw BenchError("fixture \(path): want a non-empty JSON list of chat messages")
        }
        for (i, m) in messages.enumerated() {
            guard case .object = m, m["role"].string != nil else {
                throw BenchError("fixture \(path): message \(i) is not an object with a string role")
            }
        }
        let turns = requestPoints(messages).count
        guard (minTurns ... maxTurns).contains(turns) else {
            throw BenchError("fixture \(path): \(turns) turns (user/tool messages), want \(minTurns)-\(maxTurns)")
        }
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        return (messages, String(digest.prefix(16)))
    }

    /// Copy of messages with `tag` prepended to the system prompt (a system message is created if absent).
    public static func withHeadTag(_ messages: [JSONValue], tag: String) -> [JSONValue] {
        var out = messages
        if let first = out.first, first["role"].string == "system", case .object(var o) = first {
            let c = o["content"] ?? .null
            if case .array(let parts) = c {
                o["content"] = .array([.obj(["type": "text", "text": .string(tag)])] + parts)
            } else {
                let s = c.truthy ? pyStr(c) : ""
                o["content"] = .string(("\(tag) \(s)").trimmingTrailingWhitespace())
            }
            out[0] = .object(o)
        } else {
            out.insert(.obj(["role": "system", "content": .string(tag)]), at: 0)
        }
        return out
    }

    /// Head of the system prompt: for off-by-nonce arms a per-request nonce first, then a session tag.
    public static func replayMessages(_ history: [JSONValue], arm: ReplayArm, session: String?, nonce: String?) -> [JSONValue] {
        var tags: [String] = []
        if arm.cache == .offByNonce, let nonce { tags.append("[nonce \(nonce)]") }
        if let session { tags.append(session) }
        return tags.isEmpty ? history : withHeadTag(history, tag: tags.joined(separator: " "))
    }

    public static func requestBody(model: String, messages: [JSONValue], maxTokens: Int, classic: Bool) -> Data {
        var body = JSONObject()
        body["model"] = .string(model)
        body["messages"] = .array(messages)
        body["max_tokens"] = .int(maxTokens)
        body["temperature"] = .double(0.0)
        body["stream"] = .bool(true)
        body["stream_options"] = .obj(["include_usage": .bool(true)])
        body["ignore_eos"] = .bool(true)
        if !classic { body["chat_template_kwargs"] = .obj(["enable_thinking": .bool(false)]) }
        return Data(JSON.dumps(.object(body)).utf8)
    }

    public static func streamRequest(arm: ReplayArm, messages: [JSONValue], maxTokens: Int, timeout: Double, classic: Bool) async -> StreamResult {
        await ChatStreamer.post(url: chatEndpoint(arm.url),
                                body: requestBody(model: arm.model, messages: messages, maxTokens: maxTokens, classic: classic),
                                timeout: timeout, pieceKeys: classic ? PieceKeys.classic : PieceKeys.replay,
                                noOutputMessage: classic ? "no content chunk" : "no output chunk")
    }

    /// One request row (key order identical to agent_replay.py).
    public static func requestRow(arm: ReplayArm, rep: Int, orderPos: Int, turn: Int, msgIndex: Int, role: String, maxTokens N: Int,
                                  result res: StreamResult, logHits: Int?, nonce: String?, session: String?) -> JSONValue {
        let usage = res.usage ?? .null
        var n: Int?
        if case .int(let c) = usage["completion_tokens"] { n = c }
        var prompt: Int?
        if case .int(let p) = usage["prompt_tokens"] { prompt = p }
        let ttft = res.tFirst.map { $0 - res.tSend }
        var decode: Double?
        if let n, let tf = res.tFirst, let tl = res.tLast, n >= 2, tl > tf { decode = Double(n - 1) / (tl - tf) }
        var cached: Int?
        var info = "unknown"
        let det = usage["prompt_tokens_details"]
        if case .object = det, case .int(let c) = det["cached_tokens"] {
            cached = c; info = "usage"
        } else if let logHits {
            cached = logHits; info = "log"
        }
        var flag: String?
        if res.error != nil { flag = nil }
        else if n == nil { flag = "no_usage" }
        else if n! < N { flag = "short" }
        else if n! > N { flag = "mismatch" }
        else { flag = "ok" }
        if flag == "no_usage" || flag == "short" { decode = nil }
        var frac: Double?
        if let cached, let prompt, prompt != 0 { frac = Double(cached) / Double(prompt) }
        return .obj([
            "kind": "request", "arm": .string(arm.name), "cache": .string(arm.cache.rawValue), "rep": .int(rep),
            "order_pos": .int(orderPos), "turn": .int(turn), "msg_index": .int(msgIndex), "role": .string(role),
            "session": JSONValue(session), "nonce": JSONValue(nonce), "prompt_tokens": JSONValue(prompt),
            "cached_tokens": JSONValue(cached), "cache_info": .string(info), "cache_frac": JSONValue(frac),
            "completion_tokens": JSONValue(n), "max_tokens": .int(N), "ttft_s": JSONValue(ttft), "decode_tps": JSONValue(decode),
            "tokens_flag": JSONValue(flag), "stream_chunks": .int(res.chunks), "error": JSONValue(res.error),
        ])
    }

    static func hex(_ n: Int) -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(n)) }

    public static func runSession(arm: ReplayArm, messages: [JSONValue], points: [Int], rep: Int, orderPos: Int,
                                  cfg: ReplayConfig, session: String?, log: LogSink) async -> [JSONValue] {
        var rows: [JSONValue] = []
        for (k0, idx) in points.enumerated() {
            let k = k0 + 1
            if let d = cfg.deadline, Date() >= d { log("[\(arm.name) rep\(rep)] pass deadline reached"); break }
            let nonce: String? = arm.cache == .offByNonce ? hex(16) : nil
            let body = replayMessages(Array(messages[...idx]), arm: arm, session: session, nonce: nonce)
            let off = Scoreboard.fileSize(arm.serverLog)
            let res = await streamRequest(arm: arm, messages: body, maxTokens: cfg.maxTokens, timeout: cfg.timeout, classic: cfg.classic)
            let hits = Scoreboard.logHitsSince(path: arm.serverLog, offset: off)
            let row = requestRow(arm: arm, rep: rep, orderPos: orderPos, turn: k, msgIndex: idx,
                                 role: messages[idx]["role"].string ?? "", maxTokens: cfg.maxTokens, result: res,
                                 logHits: hits, nonce: nonce, session: session)
            rows.append(row)
            log("[\(arm.name) rep\(rep) turn \(k)/\(points.count)] ttft=\(row["ttft_s"].double.map { String(format: "%.3fs", $0) } ?? "n/a") "
                + "prompt=\(pyStr(row["prompt_tokens"])) cached=\(pyStr(row["cached_tokens"])) "
                + "flag=\(pyStr(row["tokens_flag"])) err=\(pyStr(row["error"]))")
        }
        return rows
    }

    /// Writes raw.jsonl + summary.md under `cfg.outDir`; returns the summary text.
    @discardableResult
    public static func run(cfg: ReplayConfig, log: LogSink) async throws -> String {
        let (messages, sha) = try loadFixture(cfg.fixture)
        let points = requestPoints(messages)
        let outURL = URL(fileURLWithPath: cfg.outDir)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let order: [[ReplayArm]] = (0 ..< cfg.reps).map { $0 % 2 == 0 ? cfg.arms : Array(cfg.arms.reversed()) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let meta: JSONValue = .obj([
            "kind": "meta", "fixture": .string(cfg.fixture), "fixture_sha256": .string(sha), "messages": .int(messages.count),
            "turns": .int(points.count), "turn_msg_index": .array(points.map { .int($0) }), "reps": .int(cfg.reps),
            "max_tokens": .int(cfg.maxTokens), "session_salt": .bool(!cfg.noSessionSalt),
            "arms": .array(cfg.arms.map(\.json)),
            "order_plan": .array(order.map { .array($0.map { .string($0.name) }) }),
            "started": .string(f.string(from: Date())),
        ])
        let rawPath = outURL.appendingPathComponent("raw.jsonl").path
        FileManager.default.createFile(atPath: rawPath, contents: nil)
        let raw = try FileHandle(forWritingTo: URL(fileURLWithPath: rawPath))
        defer { try? raw.close() }
        raw.write(Data((JSON.dumps(meta) + "\n").utf8))
        var rows: [JSONValue] = []
        outer: for (rep, arms) in order.enumerated() {
            for (pos, arm) in arms.enumerated() {
                if let d = cfg.deadline, Date() >= d { log("pass deadline reached"); break outer }
                let session: String? = cfg.noSessionSalt ? nil : "[session r\(rep)-\(arm.name)-\(hex(12))]"
                var la = [Double](repeating: 0, count: 3)
                let load: Double? = getloadavg(&la, 3) > 0 ? la[0] : nil
                let t0 = monotonicSeconds()
                let batch = await runSession(arm: arm, messages: messages, points: points, rep: rep, orderPos: pos,
                                             cfg: cfg, session: session, log: log)
                let wall = ((monotonicSeconds() - t0) * 1000).rounded() / 1000
                let repRow: JSONValue = .obj([
                    "kind": "rep", "arm": .string(arm.name), "rep": .int(rep), "order_pos": .int(pos), "wall_s": .double(wall),
                    "loadavg1": JSONValue(load), "errors": .int(batch.filter { !$0["error"].isNull }.count),
                ])
                for r in batch + [repRow] { raw.write(Data((JSON.dumps(r) + "\n").utf8)) }
                rows.append(contentsOf: batch + [repRow])
            }
        }
        let text = summarize(meta: meta, rows: rows)
        try text.write(toFile: outURL.appendingPathComponent("summary.md").path, atomically: false, encoding: .utf8)
        return text
    }

    /// Regenerates summary.md text from `<dir>/raw.jsonl`.
    public static func summarize(dir: String) throws -> String {
        let all = JSON.lines(dir + "/raw.jsonl")
        guard let meta = all.first(where: { $0["kind"].string == "meta" }) else { throw BenchError("\(dir)/raw.jsonl: no meta row") }
        return summarize(meta: meta, rows: all.filter { $0["kind"].string != "meta" })
    }

    /// agent_replay.py `summarize`.
    public static func summarize(meta: JSONValue, rows: [JSONValue]) -> String {
        let reqs = rows.filter { $0["kind"].string == "request" }
        let armRows = meta["arms"].array ?? []
        let arms = armRows.compactMap { $0["name"].string }
        let turns = Array(Set(reqs.compactMap { $0["turn"].int })).sorted()
        let reps = Array(Set(reqs.compactMap { $0["rep"].int })).sorted()
        struct K: Hashable { var arm: String; var turn: Int; var rep: Int }
        var idx: [K: JSONValue] = [:]
        var msgOf: [Int: Int] = [:]
        for r in reqs {
            idx[K(arm: r["arm"].string ?? "", turn: r["turn"].int ?? 0, rep: r["rep"].int ?? 0)] = r
            msgOf[r["turn"].int ?? 0] = r["msg_index"].int
        }
        func perRep(_ arm: String, _ turn: Int, _ key: String) -> [Double?] {
            reps.map { idx[K(arm: arm, turn: turn, rep: $0)]?[key].double }
        }
        func cachedCell(_ arm: String, _ turn: Int) -> String {
            var vals: [Double] = []
            for rep in reps {
                guard let r = idx[K(arm: arm, turn: turn, rep: rep)] else { return "n/a" }
                guard let f = r["cache_frac"].double else { return "unknown" }
                vals.append(f)
            }
            return String(format: "%.1f", Stats.median(vals)! * 100) + "%"
        }
        func f(_ v: Double?, _ dp: Int) -> String { v.map { String(format: "%.\(dp)f", $0) } ?? "n/a" }
        var out: [String] = ["# Agent replay summary", ""]
        let sessionSalt = meta["session_salt"].truthy
        out.append("- fixture: `\(meta["fixture"].string ?? "")` sha256:\(meta["fixture_sha256"].string ?? ""), \(pyStr(meta["turns"])) turns "
            + "(user/tool messages), \(pyStr(meta["messages"])) messages")
        out.append("- max_tokens \(pyStr(meta["max_tokens"])), ignore_eos, temperature 0, streamed; reps \(pyStr(meta["reps"])); "
            + "session tag \(sessionSalt ? "on" : "off")")
        let plan = (meta["order_plan"].array ?? []).enumerated().map { i, o in
            "rep\(i): " + (o.array ?? []).compactMap(\.string).joined(separator: " ")
        }
        out.append("- order per rep: " + plan.joined(separator: "; "))
        out.append("- all medians are over reps (one request per arm, turn and rep)")
        out += ["", "## Arms", "", "| arm | URL | model | cache | server log |", "| --- | --- | --- | --- | --- |"]
        for a in armRows {
            let sl = a["server_log"].truthy ? pyStr(a["server_log"]) : "-"
            out.append("| \(a["name"].string ?? "") | \(a["url"].string ?? "") | \(a["model"].string ?? "") | \(a["cache"].string ?? "") | \(sl) |")
        }
        out += ["", "## Per-turn TTFT (s, median over reps)", "",
                "| turn | msg | prompt tok | " + arms.joined(separator: " | ") + " |",
                "| --- | --- | --- | " + arms.map { _ in "---" }.joined(separator: " | ") + " |"]
        for t in turns {
            let pts = arms.flatMap { perRep($0, t, "prompt_tokens") }.compactMap { $0 }
            let pt = pts.isEmpty ? "n/a" : String(Int(Stats.median(pts)!.rounded(.toNearestOrEven)))
            let cells = arms.map { f(Stats.med(perRep($0, t, "ttft_s")), 3) }
            out.append("| \(t) | \(msgOf[t].map(String.init) ?? "None") | \(pt) | " + cells.joined(separator: " | ") + " |")
        }
        out += ["", "## Total prefill (sum of per-turn TTFT, s)", "",
                "| arm | prefill s (median) | per rep | incomplete reps |", "| --- | --- | --- | --- |"]
        for a in arms {
            var sums: [Double] = []
            var incomplete = 0
            for rep in reps {
                let ts = turns.map { idx[K(arm: a, turn: $0, rep: rep)]?["ttft_s"].double }
                if ts.allSatisfy({ $0 != nil }) { sums.append(pySum(ts.map { $0! })) } else { incomplete += 1 }
            }
            let detail = sums.isEmpty ? "n/a" : sums.map { String(format: "%.3f", $0) }.joined(separator: " / ")
            out.append("| \(a) | \(f(Stats.median(sums), 3)) | \(detail) | \(incomplete) |")
        }
        out += ["", "## Cached-token fraction per turn (cached / prompt tok, median over reps)", "",
                "| turn | " + arms.joined(separator: " | ") + " |", "| --- | " + arms.map { _ in "---" }.joined(separator: " | ") + " |"]
        for t in turns { out.append("| \(t) | " + arms.map { cachedCell($0, t) }.joined(separator: " | ") + " |") }
        out += ["", "## Decode tok/s per turn (median over reps)", "",
                "| turn | " + arms.joined(separator: " | ") + " |", "| --- | " + arms.map { _ in "---" }.joined(separator: " | ") + " |"]
        for t in turns { out.append("| \(t) | " + arms.map { f(Stats.med(perRep($0, t, "decode_tps")), 1) }.joined(separator: " | ") + " |") }
        let errors = reqs.filter { !$0["error"].isNull }.count
        let short = reqs.filter { ["short", "no_usage"].contains($0["tokens_flag"].string ?? "") }.count
        out += ["", "## Notes", "",
                "- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.",
                "- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.",
                "- request errors: \(errors); rows excluded from decode (short / no_usage): \(short)."]
        return out.joined(separator: "\n") + "\n"
    }
}

extension String {
    /// Python `rstrip()` of whitespace.
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let l = s.unicodeScalars.last, l.properties.isWhitespace { s.unicodeScalars.removeLast() }
        return s
    }
}

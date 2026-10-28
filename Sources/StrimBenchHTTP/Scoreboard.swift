import Foundation

public typealias LogSink = @Sendable (String) -> Void

public protocol TextTokenizer: Sendable {
    func encode(_ text: String) -> [Int]
    func decode(_ ids: [Int]) -> String
}

/// Builds the tokenizer for a model directory (supplied by the CLI, which links StrimTokenizer).
public typealias TokenizerFactory = @Sendable (String) throws -> TextTokenizer

public struct Arm: Sendable, Equatable {
    public var name: String
    public var url: String
    public var model: String
    public var pending = false
    public var pid: Int?

    public init(name: String, url: String, model: String, pending: Bool = false, pid: Int? = nil) {
        self.name = name; self.url = url; self.model = model; self.pending = pending; self.pid = pid
    }

    /// `NAME[:pending]=BASE_URL,MODEL` (scoreboard.py parse_arm).
    public static func parse(_ spec: String) throws -> Arm {
        guard let eq = spec.firstIndex(of: "=") else { throw BenchError("bad --arm '\(spec)': want NAME[:pending]=BASE_URL,MODEL") }
        var name = String(spec[..<eq])
        let rest = String(spec[spec.index(after: eq)...])
        guard let comma = rest.lastIndex(of: ",") else { throw BenchError("bad --arm '\(spec)': want NAME[:pending]=BASE_URL,MODEL") }
        let url = String(rest[..<comma]).trimmingCharacters(in: .whitespaces)
        let model = String(rest[rest.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || url.isEmpty || model.isEmpty { throw BenchError("bad --arm '\(spec)': want NAME[:pending]=BASE_URL,MODEL") }
        var pending = false
        if name.hasSuffix(":pending") { pending = true; name.removeLast(":pending".count) }
        return Arm(name: name, url: url, model: model, pending: pending)
    }

    var json: JSONValue {
        .obj(["name": .string(name), "url": .string(url), "model": .string(model), "pending": .bool(pending),
              "pid": JSONValue(pid)])
    }
}

/// Distinct long prompts from prompt_seed.txt, sized with a tokenizer when one is available.
public final class Prompter: @unchecked Sendable {
    let seedScalars: [Unicode.Scalar]
    let tok: TextTokenizer?
    let seedIds: [Int]
    public let note: String
    public var approx: Bool { tok == nil }

    public init(seed: String, tokenizer: TextTokenizer?, note: String) {
        seedScalars = Array(seed.unicodeScalars)
        tok = tokenizer
        seedIds = tokenizer?.encode(seed) ?? []
        self.note = note
    }

    /// `tokenizerPath`: a tokenizer.json path or its model dir; "" forces chars/4.
    public static func make(seed: String, tokenizerPath: String, factory: TokenizerFactory?) -> Prompter {
        if tokenizerPath.isEmpty { return Prompter(seed: seed, tokenizer: nil, note: "approx chars/4 (no tokenizer requested)") }
        var dir = tokenizerPath
        if dir.hasSuffix("tokenizer.json") { dir = (dir as NSString).deletingLastPathComponent }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return Prompter(seed: seed, tokenizer: nil, note: "approx chars/4 (tokenizer not found: \(tokenizerPath))")
        }
        guard let factory else { return Prompter(seed: seed, tokenizer: nil, note: "approx chars/4 (no tokenizer backend linked)") }
        do {
            let t = try factory(dir)
            return Prompter(seed: seed, tokenizer: t, note: "strim tokenizer: \(tokenizerPath)")
        } catch {
            return Prompter(seed: seed, tokenizer: nil, note: "approx chars/4 (\(type(of: error)): \(error))")
        }
    }

    public func text(_ n: Int, salt: String) -> String {
        let head = "[\(salt)] "  // unique head => no prefix-cache hits across salts
        if let tok {
            var ids = tok.encode(head)
            while ids.count < n, !seedIds.isEmpty { ids += seedIds }
            return tok.decode(Array(ids.prefix(n)))
        }
        let chars = n * 4
        var s = String.UnicodeScalarView()
        s.append(contentsOf: head.unicodeScalars)
        let reps = chars / max(seedScalars.count, 1) + 2
        for _ in 0 ..< reps { s.append(contentsOf: seedScalars) }
        return String(String.UnicodeScalarView(s.prefix(chars)))
    }

    public func count(_ text: String) -> Int {
        if let tok { return tok.encode(text).count }
        return text.unicodeScalars.count / 4
    }

    /// Exact token count of streamed text, or nil without a real tokenizer (chars/4 is not usable).
    public func retokenize(_ text: String) -> Int? { tok.map { $0.encode(text).count } }
}

public struct ScoreboardConfig: Sendable {
    public var arms: [Arm] = []
    public var workloads = ["W1", "W2", "W3", "W4", "W5"]
    public var reps = 5
    public var w1Tokens = [64, 256]
    public var w2Tokens = 256
    public var seed = 1234
    public var w3Sizes = [4096, 16384, 32768]
    public var w3Gen = 128
    public var w4Size = 4096
    public var w4Gen = 64
    public var conc = [2, 4]
    public var w5Prefix = 16384
    public var w5Suffix = 512
    public var w5Gen = 64
    /// W6 realistic agent prompts: JSON array of strings (distinct repo source heads + a coding question), run at each --conc level.
    public var w6PromptsFile: String?
    public var w6Gen = 128
    public var noThink = true
    /// Per-arm server log (hits when usage lacks cached_tokens). Key "" applies to every arm.
    public var serverLogs: [String: String] = [:]
    public var timeout = 900.0
    public var outDir: String
    public var benchDir = "bench"
    public var tokenizer = "models/qwen38-4bit/tokenizer.json"
    /// Stop starting new groups after this instant (pass deadline).
    public var deadline: Date?

    public init(outDir: String) { self.outDir = outDir }

    /// Prompts loaded from `w6PromptsFile` (empty when unset or unreadable).
    var w6Prompts: [String] {
        guard let f = w6PromptsFile, let d = FileManager.default.contents(atPath: f),
              case .array(let a)? = try? JSON.parse(d) else { return [] }
        return a.compactMap { $0.string }
    }

    func serverLog(for arm: Arm) -> String? { serverLogs[arm.name] ?? serverLogs[""] }
    var serverLogMeta: JSONValue {
        if serverLogs.isEmpty { return .null }
        if let g = serverLogs[""], serverLogs.count == 1 { return .string(g) }
        return .string(serverLogs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
    }
}

public struct Item: Sendable {
    public var item: String
    public var prompt: String
    public var maxTokens: Int
    public var temperature: Double
    public var seed: Int?
    public var target: Int?
}

public struct Group: Sendable {
    public var variant: String
    public var concurrent: Bool
    public var items: [Item]
}

public enum Scoreboard {
    public static let allWorkloads = ["W1", "W2", "W3", "W4", "W5", "W6"]
    /// no decode tok/s, no aggregate tok/s; still counted in the summary.
    public static let excludedFlags: Set<String> = ["no_usage", "short"]

    /// Groups for one (workload, rep). Built once and shared by all arms (ABAB).
    public static func buildGroups(workload wl: String, rep: Int, runID: String, cfg: ScoreboardConfig,
                                   prompter: Prompter, corpus: JSONObject) -> [Group] {
        func salt(_ tag: String) -> String { "\(runID)-\(wl)-r\(rep)-\(tag)" }
        func item(_ key: String, _ text: String, _ n: Int, temp: Double = 0.0, seed: Int? = nil, target: Int? = nil) -> Item {
            Item(item: key, prompt: text, maxTokens: n, temperature: temp, seed: seed, target: target)
        }
        var groups: [Group] = []
        switch wl {
        case "W1":  // corpus, greedy, short and medium outputs
            for n in cfg.w1Tokens {
                for m in corpus.members {
                    groups.append(Group(variant: "greedy-\(n)", concurrent: false, items: [item(m.key, m.value.string ?? "", n)]))
                }
            }
        case "W2":  // corpus, temperature 0.6, fixed seed
            for m in corpus.members {
                groups.append(Group(variant: "temp0.6-\(cfg.w2Tokens)", concurrent: false,
                                    items: [item(m.key, m.value.string ?? "", cfg.w2Tokens, temp: 0.6, seed: cfg.seed)]))
            }
        case "W3":  // single stream, long cold prompts
            for size in cfg.w3Sizes {
                let p = prompter.text(size, salt: salt("c\(size)"))
                groups.append(Group(variant: "ctx-\(size)", concurrent: false, items: [item(String(size), p, cfg.w3Gen, target: size)]))
            }
        case "W4":  // N concurrent DISTINCT cold ~4K prompts
            for c in cfg.conc {
                let items = (0 ..< c).map { i in
                    item("i\(i)", prompter.text(cfg.w4Size, salt: salt("c\(c)-i\(i)")), cfg.w4Gen, target: cfg.w4Size)
                }
                groups.append(Group(variant: "distinct-c\(c)", concurrent: true, items: items))
            }
        case "W5":  // 4 concurrent requests sharing a 16K prefix + unique suffix
            let prefix = prompter.text(cfg.w5Prefix, salt: salt("prefix"))
            let items = (0 ..< 4).map { i in
                item("s\(i)", prefix + "\n\n" + prompter.text(cfg.w5Suffix, salt: salt("s\(i)")), cfg.w5Gen,
                     target: cfg.w5Prefix + cfg.w5Suffix)
            }
            groups.append(Group(variant: "shared\(cfg.w5Prefix)-c4", concurrent: true, items: items))
        case "W6":  // N concurrent DISTINCT agent-style prompts (salted head => cold, no prefix-cache reuse across reps/arms)
            let pool = cfg.w6Prompts
            if !pool.isEmpty {
                for c in cfg.conc {
                    let items = (0 ..< c).map { i in
                        item("i\(i)", "[\(salt("c\(c)-i\(i)"))]\n" + pool[i % pool.count], cfg.w6Gen)
                    }
                    groups.append(Group(variant: "agent-c\(c)", concurrent: true, items: items))
                }
            }
        default: break
        }
        return groups
    }

    public static func requestBody(model: String, prompt: String, maxTokens: Int, temperature: Double, seed: Int?, noThink: Bool) -> Data {
        var body = JSONObject()
        body["model"] = .string(model)
        body["messages"] = .array([.obj(["role": .string("user"), "content": .string(prompt)])])
        body["max_tokens"] = .int(maxTokens)
        body["temperature"] = .double(temperature)
        body["stream"] = .bool(true)
        body["stream_options"] = .obj(["include_usage": .bool(true)])
        body["ignore_eos"] = .bool(true)
        if noThink { body["chat_template_kwargs"] = .obj(["enable_thinking": .bool(false)]) }
        if let seed { body["seed"] = .int(seed) }
        return Data(JSON.dumps(.object(body)).utf8)
    }

    public static func streamRequest(arm: Arm, item it: Item, timeout: Double, noThink: Bool) async -> StreamResult {
        let body = requestBody(model: arm.model, prompt: it.prompt, maxTokens: it.maxTokens, temperature: it.temperature,
                               seed: it.seed, noThink: noThink)
        return await ChatStreamer.post(url: chatEndpoint(arm.url), body: body, timeout: timeout,
                                       pieceKeys: PieceKeys.scoreboard, noOutputMessage: "no output chunk")
    }

    static func cacheFlag(_ wl: String, _ cached: Int?) -> String {
        guard let cached else { return wl == "W4" ? "unverified" : "unknown" }
        return cached > 0 ? "hit" : "ok_zero"
    }

    /// One request row (key order identical to scoreboard.py).
    public static func requestRow(workload wl: String, variant: String, concurrency: Int, arm: Arm, rep: Int, slot: Int,
                                  item it: Item, result res: StreamResult, prompter: Prompter) -> JSONValue {
        let usage = res.usage ?? .null
        let N = it.maxTokens
        var retok = false
        var n: Int?
        if case .int(let c) = usage["completion_tokens"] {
            n = c
        } else if res.error == nil {  // no usage block: recount streamed text
            n = prompter.retokenize(res.text)
            retok = n != nil
        }
        let ttft = res.tFirst.map { $0 - res.tSend }
        var decode: Double?
        if let n, let tf = res.tFirst, let tl = res.tLast, n >= 2, tl > tf { decode = Double(n - 1) / (tl - tf) }
        var cached: Int?
        var info = "unknown"
        let det = usage["prompt_tokens_details"]
        if case .object = det, case .int(let c) = det["cached_tokens"] { cached = c; info = "usage" }
        var flag: String?
        if res.error != nil { flag = nil }
        else if n == nil { flag = "no_usage" }
        else if n! < N { flag = "short" }
        else if retok { flag = "retokenized" }
        else if n! != N { flag = "mismatch" }
        else { flag = "ok" }
        if let f = flag, excludedFlags.contains(f) { decode = nil }
        var promptTokens: JSONValue = .null
        if case .int(let p) = usage["prompt_tokens"] { promptTokens = .int(p) } else if usage["prompt_tokens"].truthy { promptTokens = usage["prompt_tokens"] }
        return .obj([
            "kind": "request", "workload": .string(wl), "variant": .string(variant), "arm": .string(arm.name),
            "model": .string(arm.model), "rep": .int(rep), "slot": .int(slot), "item": .string(it.item),
            "concurrency": .int(concurrency), "max_tokens": .int(N), "completion_tokens": JSONValue(n),
            "stream_chunks": .int(res.chunks), "reasoning_chunks": .int(res.reasoningChunks),
            "prompt_tokens": promptTokens,
            "prompt_target": JSONValue(it.target), "ttft_s": JSONValue(ttft), "decode_tps": JSONValue(decode),
            "tokens_flag": JSONValue(flag),
            "cache_info": .string(info), "cached_tokens": JSONValue(cached), "cache_flag": .string(cacheFlag(wl, cached)),
            "approx_tokens": .bool(prompter.approx), "error": JSONValue(res.error),
        ])
    }

    /// Sum of all cache-hit counts in `path` since byte `offset`; nil when no recognizable line.
    public static func logHitsSince(path: String?, offset: Int) -> Int? {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(offset))
        let data = (try? h.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"(?i)cache[ _-]?hits?\D{0,40}?(\d+)"#) else { return nil }
        let ns = text as NSString
        var vals: [Int] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, let v = Int(ns.substring(with: m.range(at: 1))) { vals.append(v) }
        }
        return vals.isEmpty ? nil : vals.reduce(0, +)
    }

    static func fileSize(_ path: String?) -> Int {
        guard let path, let a = try? FileManager.default.attributesOfItem(atPath: path), let s = a[.size] as? NSNumber else { return 0 }
        return s.intValue
    }

    /// Runs one group on one arm; returns the request rows and the batch row.
    public static func runGroup(arm: Arm, workload wl: String, rep: Int, group: Group, cfg: ScoreboardConfig,
                                prompter: Prompter) async -> (rows: [JSONValue], batch: JSONValue) {
        let items = group.items
        let log = cfg.serverLog(for: arm)
        let off = (log != nil && FileManager.default.fileExists(atPath: log!)) ? fileSize(log) : 0
        var results = [StreamResult?](repeating: nil, count: items.count)
        if group.concurrent {
            let barrier = AsyncBarrier(count: items.count)
            await withTaskGroup(of: (Int, StreamResult).self) { tg in
                for i in 0 ..< items.count {
                    tg.addTask {
                        await barrier.wait()  // release all sends together
                        return (i, await streamRequest(arm: arm, item: items[i], timeout: cfg.timeout, noThink: cfg.noThink))
                    }
                }
                for await (i, r) in tg { results[i] = r }
            }
        } else {
            for i in 0 ..< items.count {
                results[i] = await streamRequest(arm: arm, item: items[i], timeout: cfg.timeout, noThink: cfg.noThink)
            }
        }
        let logVal = log != nil ? logHitsSince(path: log, offset: off) : nil
        var rows: [JSONValue] = []
        for (i, it) in items.enumerated() {
            var row = requestRow(workload: wl, variant: group.variant, concurrency: items.count, arm: arm, rep: rep, slot: i,
                                 item: it, result: results[i]!, prompter: prompter)
            if row["cache_info"].string == "unknown", let logVal {
                guard case .object(var o) = row else { continue }
                o["cache_info"] = .string(group.concurrent ? "log-batch" : "log")
                o["cached_tokens"] = .int(logVal)
                o["cache_flag"] = .string(cacheFlag(wl, logVal))
                row = .object(o)
            }
            rows.append(row)
        }
        let errors = rows.filter { !$0["error"].isNull }.count
        let excluded = rows.filter { excludedFlags.contains($0["tokens_flag"].string ?? "\u{0}") }.count
        var totalTokens: JSONValue = .null, wall: JSONValue = .null, agg: JSONValue = .null
        let ok = zip(rows, results).filter { $0.0["error"].isNull }
        // aggregate needs every request's token count: any excluded row voids the group's aggregate
        if !ok.isEmpty && excluded == 0 {
            let total = ok.reduce(0) { $0 + ($1.0["completion_tokens"].int ?? 0) }
            let start = results.compactMap { $0?.tSend }.min()!
            let w = ok.compactMap { $0.1?.tEnd }.max()! - start
            totalTokens = .int(total)
            wall = .double(w)
            agg = w > 0 ? .double(Double(total) / w) : .null
        }
        let batch: JSONValue = .obj([
            "kind": "batch", "workload": .string(wl), "variant": .string(group.variant), "arm": .string(arm.name), "rep": .int(rep),
            "concurrency": .int(items.count), "errors": .int(errors), "excluded": .int(excluded),
            "total_tokens": totalTokens, "wall_s": wall, "aggregate_tps": agg,
        ])
        return (rows, batch)
    }

    /// Writes raw.jsonl + summary.md under `cfg.outDir` and returns the summary text.
    @discardableResult
    public static func execute(cfg: ScoreboardConfig, factory: TokenizerFactory?, log: LogSink) async throws -> String {
        let active = cfg.arms.filter { !$0.pending }
        let skipped = cfg.arms.filter(\.pending).map(\.name)
        for n in skipped { log("skip \(n): :pending (no HTTP server yet)") }
        if active.isEmpty { throw BenchError("no active arms (all pending)") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let runID = f.string(from: Date())
        let outURL = URL(fileURLWithPath: cfg.outDir)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let seed = try String(contentsOfFile: cfg.benchDir + "/prompt_seed.txt", encoding: .utf8)
        let prompter = Prompter.make(seed: seed, tokenizerPath: cfg.tokenizer, factory: factory)
        guard case .object(let corpus) = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: cfg.benchDir + "/ab_prompts.json"))) else {
            throw BenchError("ab_prompts.json: want an object")
        }
        let rawPath = outURL.appendingPathComponent("raw.jsonl").path
        FileManager.default.createFile(atPath: rawPath, contents: nil)
        let raw = try FileHandle(forWritingTo: URL(fileURLWithPath: rawPath))
        defer { try? raw.close() }
        func emit(_ v: JSONValue) { raw.write(Data((JSON.dumps(v) + "\n").utf8)) }
        emit(.obj([
            "kind": "meta", "run_id": .string(runID), "arms": .array(cfg.arms.map(\.json)),
            "skipped": .array(skipped.map { .string($0) }), "workloads": .array(cfg.workloads.map { .string($0) }),
            "reps": .int(cfg.reps), "no_think": .bool(cfg.noThink), "approx_tokens": .bool(prompter.approx),
            "tokenizer_note": .string(prompter.note), "server_log": cfg.serverLogMeta, "timeout_s": .double(cfg.timeout),
        ]))
        outer: for wl in cfg.workloads {
            for rep in 0 ..< cfg.reps {
                let groups = buildGroups(workload: wl, rep: rep, runID: runID, cfg: cfg, prompter: prompter, corpus: corpus)
                let order = rep % 2 == 0 ? active : Array(active.reversed())  // ABAB
                for arm in order {
                    let snap = SystemSnapshot.env()
                    let t0 = Date()
                    var nreq = 0, nerr = 0
                    let rss = RSSSampler(pid: arm.pid)
                    await rss.start()
                    for g in groups {
                        if let d = cfg.deadline, Date() >= d {
                            log("[\(wl)] rep\(rep) \(arm.name): pass deadline reached, stopping")
                            _ = await rss.stop()
                            break outer
                        }
                        let (rows, batch) = await runGroup(arm: arm, workload: wl, rep: rep, group: g, cfg: cfg, prompter: prompter)
                        for r in rows {
                            emit(r)
                            nreq += 1
                            if !r["error"].isNull { nerr += 1 }
                        }
                        if g.concurrent { emit(batch) }
                    }
                    let peak = await rss.stop()
                    let el = Date().timeIntervalSince(t0)
                    emit(.obj([
                        "kind": "rep", "workload": .string(wl), "arm": .string(arm.name), "rep": .int(rep),
                        "uptime": JSONValue(snap.uptime), "loadavg": JSONValue(snap.loadavg),
                        "peak_rss_kb": JSONValue(peak), "requests": .int(nreq), "errors": .int(nerr),
                        "elapsed_s": .double((el * 100).rounded() / 100),
                    ]))
                    log("[\(wl)] rep\(rep) \(arm.name): \(nreq) req, \(nerr) err, \(String(format: "%.1f", el))s")
                }
            }
        }
        try? raw.synchronize()
        let text = try summarize(dir: cfg.outDir)
        try text.write(toFile: outURL.appendingPathComponent("summary.md").path, atomically: false, encoding: .utf8)
        log(text)
        return text
    }

    // MARK: summary

    /// summary.md text for `<dir>/raw.jsonl` (scoreboard.py `summarize`).
    public static func summarize(dir: String) throws -> String {
        let rows = JSON.lines(dir + "/raw.jsonl")
        guard let meta = rows.first(where: { $0["kind"].string == "meta" }) else { throw BenchError("\(dir)/raw.jsonl: no meta row") }
        let arms = (meta["arms"].array ?? []).filter { !$0["pending"].truthy }.compactMap { $0["name"].string }
        struct Key: Hashable { var wl: String, variant: String, metric: String, arm: String }
        var series: [Key: OrderedDict<Int, [Double]>] = [:]
        func add(_ k: Key, _ rep: Int, _ v: Double) {
            var d = series[k] ?? OrderedDict()
            var l = d[rep] ?? []
            l.append(v)
            d[rep] = l
            series[k] = d
        }
        for r in rows {
            switch r["kind"].string {
            case "request":
                if r["error"].isNull {
                    for m in ["ttft_s", "decode_tps"] {
                        if let v = r[m].double { add(Key(wl: r["workload"].string ?? "", variant: r["variant"].string ?? "", metric: m, arm: r["arm"].string ?? ""), r["rep"].int ?? 0, v) }
                    }
                }
            case "batch":
                if let v = r["aggregate_tps"].double {
                    add(Key(wl: r["workload"].string ?? "", variant: r["variant"].string ?? "", metric: "aggregate_tps", arm: r["arm"].string ?? ""), r["rep"].int ?? 0, v)
                }
            case "rep":
                if let v = r["peak_rss_kb"].double { add(Key(wl: "-", variant: "-", metric: "peak_rss_kb", arm: r["arm"].string ?? ""), r["rep"].int ?? 0, v) }
            default: break
            }
        }
        var cells: [Key: (med: Double, cv: Double?, n: Int)] = [:]
        for (k, perRep) in series {
            let meds = perRep.values.filter { !$0.isEmpty }.compactMap { Stats.median($0) }
            let vals = meds.filter { $0.isFinite }
            guard !vals.isEmpty else { continue }
            let med = Stats.median(vals)!
            if vals.count == 1 { cells[k] = (med, 0.0, 1); continue }
            let mean = Stats.mean(vals)!
            let cv: Double? = mean != 0 ? Stats.stdev(vals)! / abs(mean) * 100 : nil
            cells[k] = (med, cv, vals.count)
        }
        var tableKeys = Set<[String]>()
        for k in cells.keys { tableKeys.insert([k.wl, k.variant, k.metric]) }
        let sortedKeys = tableKeys.sorted { a, b in
            for i in 0 ..< 3 where a[i] != b[i] { return pyLess(a[i], b[i]) }
            return false
        }
        let approx = meta["approx_tokens"].truthy
        let noThink = meta["no_think"].isNull ? true : meta["no_think"].truthy
        let skippedNames = (meta["skipped"].array ?? []).compactMap { $0.string }
        var out: [String] = [
            "# Scoreboard \(meta["run_id"].string ?? "")", "",
            "- reps: \(pyStr(meta["reps"])); value = median over reps of per-rep median; cv = stdev/mean over reps",
            "- tokens: \(approx ? "APPROXIMATE chars/4" : "tokenizer") (\(meta["tokenizer_note"].string ?? ""))",
            "- skipped (pending): \(skippedNames.isEmpty ? "none" : skippedNames.joined(separator: ", "))",
            "- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown",
            "- thinking: \(noThink ? "disabled (chat_template_kwargs.enable_thinking=false)" : "server default")",
            "- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept",
            "", "| workload | variant | metric | " + arms.joined(separator: " | ") + " |",
            "|---|---|---|" + String(repeating: "---|", count: arms.count),
        ]
        for k in sortedKeys {
            var cs: [String] = []
            for a in arms {
                if let c = cells[Key(wl: k[0], variant: k[1], metric: k[2], arm: a)] {
                    let cvs = c.cv.map { " cv " + String(format: "%.1f", $0) + "%" } ?? ""
                    cs.append(String(format: "%.4g", c.med) + cvs + " (n=\(c.n))")
                } else {
                    cs.append("—")
                }
            }
            out.append("| \(k[0]) | \(k[1]) | \(k[2]) | " + cs.joined(separator: " | ") + " |")
        }
        out += ["", "## Flags per arm", ""]
        for a in arms {
            let reqs = rows.filter { $0["kind"].string == "request" && $0["arm"].string == a }
            var cacheInfo = OrderedDict<String, Int>()
            for r in reqs { let k = r["cache_info"].string ?? "None"; cacheInfo[k] = (cacheInfo[k] ?? 0) + 1 }
            let w4Bad = reqs.filter { $0["workload"].string == "W4" && $0["cache_flag"].string != "ok_zero" }.count
            func cnt(_ f: String) -> Int { reqs.filter { $0["tokens_flag"].string == f }.count }
            let excluded = reqs.filter { excludedFlags.contains($0["tokens_flag"].string ?? "\u{0}") }.count
            let ci = "{" + cacheInfo.items.map { "'\($0.0)': \($0.1)" }.joined(separator: ", ") + "}"
            out.append("- \(a): requests \(reqs.count), errors \(reqs.filter { !$0["error"].isNull }.count), "
                + "tokens mismatch \(cnt("mismatch")), short \(cnt("short")), no usage \(cnt("no_usage")), "
                + "retokenized \(cnt("retokenized")), excluded rows \(excluded) (decode/aggregate dropped), "
                + "cache_info \(ci), W4 rows not zero-hit/verified \(w4Bad)")
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// Python `str()` of a JSON scalar.
func pyStr(_ v: JSONValue) -> String {
    switch v {
    case .null: return "None"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return pyFloatRepr(d)
    case .string(let s): return s
    default: return JSON.dumps(v)
    }
}

/// All callers wait until `count` tasks arrived, then all continue together.
actor AsyncBarrier {
    private let count: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(count: Int) { self.count = count }
    func wait() async {
        arrived += 1
        if arrived >= count {
            let w = waiters
            waiters = []
            for c in w { c.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// Peak RSS (process plus direct children) sampled every 250 ms.
actor RSSSampler {
    private let pid: Int?
    private var peak: Int?
    private var task: Task<Void, Never>?
    init(pid: Int?) { self.pid = pid }

    func start() {
        guard let pid else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let v = await Task.detached { SystemSnapshot.rssKB(pid: pid) }.value
                if let v { await self?.record(v) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func record(_ v: Int) { peak = max(peak ?? 0, v) }

    func stop() async -> Int? {
        task?.cancel()
        await task?.value
        return peak
    }
}

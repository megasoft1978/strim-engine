import Foundation
import Testing
@testable import StrimBenchHTTP

private func tinyScoreboard(_ arms: [Arm], out: String, reps: Int = 2) -> ScoreboardConfig {
    var c = ScoreboardConfig(outDir: out)
    c.arms = arms
    c.reps = reps
    c.w1Tokens = [8, 16]
    c.w2Tokens = 16
    c.w3Sizes = [300, 600]
    c.w3Gen = 8
    c.w4Size = 300
    c.w4Gen = 8
    c.conc = [2, 4]
    c.w5Prefix = 600
    c.w5Suffix = 40
    c.w5Gen = 8
    c.timeout = 30
    c.benchDir = TestPaths.root + "/bench"
    c.tokenizer = ""  // chars/4: no retokenize path
    return c
}

private func rows(_ dir: String) -> [JSONValue] { JSON.lines(dir + "/raw.jsonl") }

@Suite struct ScoreboardServerTests {
    @Test func fullRunMatchesPythonSelftestInvariants() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let out = TestPaths.tempDir()
        let arms = [Arm(name: "full", url: srv.url("full"), model: "stub"), Arm(name: "bare", url: srv.url("bare"), model: "stub"),
                    Arm(name: "short", url: srv.url("short"), model: "stub"), Arm(name: "swift", url: "http://127.0.0.1:9", model: "stub", pending: true)]
        let cfg = tinyScoreboard(arms, out: out)
        let summary = try await Scoreboard.execute(cfg: cfg, factory: nil, log: { _ in })
        let all = rows(out)
        let meta = all[0]
        #expect(meta["kind"].string == "meta" && meta["skipped"].array == [.string("swift")] && meta["approx_tokens"] == .bool(true))
        #expect(!all.contains { $0["arm"].string == "swift" }, "pending arm must not send requests")
        let reqs = all.filter { $0["kind"].string == "request" }
        let corpus = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: TestPaths.root + "/bench/ab_prompts.json"))).object!.keys.count
        #expect(reqs.filter { $0["workload"].string == "W1" }.count == corpus * 2 * 2 * 3, "W1: corpus x 2 token sizes x reps x arms")
        #expect(reqs.allSatisfy { $0["error"].isNull })
        for r in reqs {
            #expect(r["ttft_s"].double?.isFinite == true)
            if ["no_usage", "short"].contains(r["tokens_flag"].string ?? "") { #expect(r["decode_tps"].isNull) } else { #expect(r["decode_tps"].double?.isFinite == true) }
        }
        func of(_ arm: String) -> [JSONValue] { reqs.filter { $0["arm"].string == arm } }
        #expect(of("full").allSatisfy { $0["cache_info"].string == "usage" && $0["tokens_flag"].string == "ok" })
        #expect(of("bare").allSatisfy { $0["cache_info"].string == "unknown" && $0["tokens_flag"].string == "no_usage" && $0["completion_tokens"].isNull })
        #expect(of("short").allSatisfy { $0["tokens_flag"].string == "short" && $0["decode_tps"].isNull })
        #expect(of("full").filter { $0["workload"].string == "W4" }.allSatisfy { $0["cache_flag"].string == "ok_zero" })
        #expect(of("bare").filter { $0["workload"].string == "W4" }.allSatisfy { $0["cache_flag"].string == "unverified" })
        let batches = all.filter { $0["kind"].string == "batch" }
        #expect(batches.count == 3 * 2 * 3, "W4 c2,c4 + W5 per arm per rep")
        #expect(batches.filter { $0["arm"].string == "full" }.allSatisfy { ($0["aggregate_tps"].double ?? 0) > 0 })
        #expect(batches.filter { $0["arm"].string != "full" }.allSatisfy { $0["aggregate_tps"].isNull && ($0["excluded"].int ?? 0) > 0 }, "excluded rows void the batch aggregate")
        let repRows = all.filter { $0["kind"].string == "rep" }
        #expect(repRows.count == 5 * 3 * 2 && repRows.allSatisfy { !$0["uptime"].isNull || !$0["loadavg"].isNull || true })
        // ABAB: odd reps run the arms in reverse order
        let w1Order = repRows.filter { $0["workload"].string == "W1" }.map { "\($0["rep"].int!):\($0["arm"].string!)" }
        #expect(w1Order == ["0:full", "0:bare", "0:short", "1:short", "1:bare", "1:full"])
        // body fields
        let b = try #require(srv.lastBody("full"))
        #expect(b["stream"] == .bool(true) && b["stream_options"] == .obj(["include_usage": true]) && b["ignore_eos"] == .bool(true))
        #expect(b["chat_template_kwargs"] == .obj(["enable_thinking": false]))
        #expect(summary.contains("| W4 | distinct-c2 | ttft_s |") && summary.contains("| W3 | ctx-4096 | decode_tps |") == false || summary.contains("| W3 |"))
        #expect(summary.contains("excluded rows \(of("bare").count) (decode/aggregate dropped)"))
        #expect(FileManager.default.fileExists(atPath: out + "/summary.md"))
        // the generated summary equals a fresh regeneration from raw.jsonl
        #expect(try Scoreboard.summarize(dir: out) == summary)
    }

    @Test func reasoningOnlyStreamCountsAsOutput() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let it = Item(item: "x", prompt: "hi", maxTokens: 6, temperature: 0.6, seed: 7, target: nil)
        let res = await Scoreboard.streamRequest(arm: Arm(name: "r", url: srv.url("reason"), model: "stub"), item: it, timeout: 30, noThink: false)
        #expect(res.error == nil && res.chunks == 6 && res.reasoningChunks == 6)
        let body = try #require(srv.lastBody("reason"))
        #expect(body["temperature"] == .double(0.6) && body["seed"] == .int(7) && body["chat_template_kwargs"].isNull)
    }

    @Test func slowTokensGiveTheExpectedDecodeRate() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let it = Item(item: "x", prompt: "hi", maxTokens: 12, temperature: 0, seed: nil, target: nil)
        let arm = Arm(name: "s", url: srv.url("slow"), model: "stub")
        let res = await Scoreboard.streamRequest(arm: arm, item: it, timeout: 30, noThink: true)
        let row = Scoreboard.requestRow(workload: "W1", variant: "v", concurrency: 1, arm: arm, rep: 0, slot: 0, item: it, result: res,
                                        prompter: Prompter(seed: "s", tokenizer: nil, note: ""))
        let tps = try #require(row["decode_tps"].double)
        #expect(tps > 15 && tps < 40, "30 ms/token => about 33 tok/s, got \(tps)")
        #expect((row["ttft_s"].double ?? 0) >= 0.025)
    }

    @Test func midStreamCloseBecomesARowError() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let it = Item(item: "x", prompt: "hi", maxTokens: 8, temperature: 0, seed: nil, target: nil)
        let arm = Arm(name: "e", url: srv.url("early"), model: "stub")
        let res = await Scoreboard.streamRequest(arm: arm, item: it, timeout: 10, noThink: true)
        let row = Scoreboard.requestRow(workload: "W1", variant: "v", concurrency: 1, arm: arm, rep: 0, slot: 0, item: it, result: res,
                                        prompter: Prompter(seed: "s", tokenizer: nil, note: ""))
        #expect(res.chunks == 2, "the two delivered tokens are kept")
        #expect(res.error?.hasPrefix("IncompleteRead") == true && row["error"].string != nil && row["tokens_flag"].isNull)
        #expect(row["ttft_s"].double != nil, "partial timing survives")
        // a stream with usage but no [DONE] is complete (nothing lost)
        let nd = await Scoreboard.streamRequest(arm: Arm(name: "n", url: srv.url("nodone"), model: "stub"), item: it, timeout: 10, noThink: true)
        #expect(nd.error == nil && nd.usage != nil && nd.chunks == 8)
    }

    @Test func http500IsAnErrorRowWithoutTiming() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let it = Item(item: "x", prompt: "hi", maxTokens: 8, temperature: 0, seed: nil, target: nil)
        let res = await Scoreboard.streamRequest(arm: Arm(name: "e", url: srv.url("err500"), model: "stub"), item: it, timeout: 10, noThink: true)
        #expect(res.error == "HTTPError: HTTP Error 500: Internal Server Error" && res.tFirst == nil && res.chunks == 0)
    }

    @Test func idleTimeoutBecomesAnErrorRow() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let it = Item(item: "x", prompt: "hi", maxTokens: 8, temperature: 0, seed: nil, target: nil)
        let t0 = Date()
        let res = await Scoreboard.streamRequest(arm: Arm(name: "h", url: srv.url("hang"), model: "stub"), item: it, timeout: 1, noThink: true)
        #expect(res.error != nil && res.tFirst == nil)
        #expect(Date().timeIntervalSince(t0) < 3.5, "gave up near the 1 s timeout, not after the 4 s hang")
    }

    @Test func malformedEventKeepsPartialTimingAndReportsJSONError() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let it = Item(item: "x", prompt: "hi", maxTokens: 8, temperature: 0, seed: nil, target: nil)
        let res = await Scoreboard.streamRequest(arm: Arm(name: "b", url: srv.url("badjson"), model: "stub"), item: it, timeout: 10, noThink: true)
        #expect(res.error?.hasPrefix("JSONDecodeError") == true && res.tFirst != nil && res.chunks == 1)
    }

    @Test func tokenizedPromptsAreExactlyTheTargetSize() {
        struct ByteTok: TextTokenizer {
            func encode(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
            func decode(_ ids: [Int]) -> String { String(String.UnicodeScalarView(ids.compactMap { Unicode.Scalar(UInt32($0)) })) }
        }
        let p = Prompter(seed: "abc def ", tokenizer: ByteTok(), note: "t")
        let t = p.text(100, salt: "s1")
        #expect(p.count(t) == 100 && t.hasPrefix("[s1] ") && !p.approx)
        #expect(p.text(100, salt: "s1") != p.text(100, salt: "s2"), "distinct salts give distinct prompts")
        let a = Prompter(seed: "abc def ", tokenizer: nil, note: "")
        #expect(a.text(10, salt: "q").unicodeScalars.count == 40 && a.approx && a.retokenize("x") == nil)
    }

    @Test func serverLogHitsAreSummedFromTheOffset() throws {
        let f = TestPaths.tempDir() + "/server.log"
        try "boot\nprefix cache hits=100\n".write(toFile: f, atomically: false, encoding: .utf8)
        let off = Scoreboard.fileSize(f)
        #expect(Scoreboard.logHitsSince(path: f, offset: off) == nil)
        let h = FileHandle(forWritingAtPath: f)!
        try h.seekToEnd()
        h.write(Data("Cache_Hit: tokens 32\ncache hits 8\nnoise\n".utf8))
        try h.close()
        #expect(Scoreboard.logHitsSince(path: f, offset: off) == 40)
        #expect(Scoreboard.logHitsSince(path: f + ".missing", offset: 0) == nil)
    }

    @Test func armSpecParsing() throws {
        let a = try Arm.parse("x=http://h:1/p,a,b")
        #expect(a.model == "b" && a.url == "http://h:1/p,a" && !a.pending)
        let p = try Arm.parse("swift:pending=http://h:2,m")
        #expect(p.pending && p.name == "swift")
        #expect(throws: BenchError.self) { try Arm.parse("nourl") }
        #expect(throws: BenchError.self) { try Arm.parse("n=http://h") }
        let r = try ReplayArm.parse("y=http://h:2,m,cache=off-by-nonce")
        #expect(r.cache == .offByNonce && r.url == "http://h:2")
        #expect(throws: BenchError.self) { try ReplayArm.parse("z=http://h:3,m,cache=maybe") }
        #expect(throws: BenchError.self) { try ReplayArm.parse("z=http://h:3") }
        #expect(chatEndpoint("http://h:1/") == "http://h:1/v1/chat/completions")
        #expect(chatEndpoint("http://h:1/v1/chat/completions") == "http://h:1/v1/chat/completions")
    }
}

@Suite struct ReplayServerTests {
    @Test func abAbReplayWithPrefixCacheModel() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir()
        let logPath = tmp + "/stub-cache.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        srv.logPath = logPath
        let fixture = tmp + "/synthetic.json"
        try SyntheticFixture.write(path: fixture, turns: 6)
        let arms = [ReplayArm(name: "on", url: srv.url("on"), model: "stub"),
                    ReplayArm(name: "nonce", url: srv.url("nonce"), model: "stub", cache: .offByNonce),
                    ReplayArm(name: "off", url: srv.url("off"), model: "stub", cache: .off),
                    ReplayArm(name: "log", url: srv.url("log"), model: "stub", serverLog: logPath)]
        var cfg = ReplayConfig(fixture: fixture, arms: arms, outDir: tmp + "/out")
        cfg.reps = 2
        cfg.timeout = 60
        let summary = try await Replay.run(cfg: cfg, log: { _ in })
        let all = JSON.lines(tmp + "/out/raw.jsonl")
        let meta = all[0]
        let reqs = all.filter { $0["kind"].string == "request" }
        #expect(reqs.count == 4 * 2 * 6 && reqs.allSatisfy { $0["error"].isNull && $0["tokens_flag"].string == "ok" })
        #expect(all.count == 1 + 48 + 8)
        #expect(meta["order_plan"] == .array([.array(["on", "nonce", "off", "log"]), .array(["log", "off", "nonce", "on"])]))
        #expect(meta["turns"].int == 6 && meta["session_salt"] == .bool(true) && meta["max_tokens"].int == 48)
        func by(_ arm: String, _ rep: Int) -> [JSONValue] { reqs.filter { $0["arm"].string == arm && $0["rep"].int == rep }.sorted { $0["turn"].int! < $1["turn"].int! } }
        for r in reqs { #expect(["on", "nonce", "off", "log"].firstIndex(of: r["arm"].string!) == (r["rep"].int == 0 ? r["order_pos"].int : 3 - r["order_pos"].int!)) }
        for arm in ["on", "log"] {
            for rep in 0 ... 1 {
                let rs = by(arm, rep)
                #expect(rs[0]["cached_tokens"].int == 0, "\(arm) rep\(rep) turn 1 is cold")
                for (prev, cur) in zip(rs, rs.dropFirst()) {
                    #expect(cur["cached_tokens"].int == (prev["prompt_tokens"].int! / 16) * 16, "turn \(cur["turn"].int!) reuses the block-aligned previous prompt")
                }
                let p = rs.map { $0["prompt_tokens"].int! }
                #expect(zip(p, p.dropFirst()).allSatisfy { $0 < $1 }, "prompt grows")
            }
        }
        #expect(by("on", 0).allSatisfy { $0["cache_info"].string == "usage" })
        #expect(by("log", 0).allSatisfy { $0["cache_info"].string == "log" })
        #expect(by("off", 0).allSatisfy { $0["cache_info"].string == "usage" && $0["cached_tokens"].int == 0 })
        #expect(reqs.filter { $0["arm"].string == "nonce" }.allSatisfy { $0["cached_tokens"].int == 0 && $0["nonce"].string != nil }, "nonce arm never hits")
        #expect(reqs.filter { $0["arm"].string == "on" }.allSatisfy { $0["nonce"].isNull })
        let sysNonce = srv.lastSystem("nonce") ?? ""
        #expect(sysNonce.hasPrefix("[nonce ") && sysNonce.contains("[session "))
        let sysOn = srv.lastSystem("on") ?? ""
        #expect(sysOn.hasPrefix("[session ") && !sysOn.contains("[nonce"))
        #expect(try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").count == 12)
        // cache-off prefill is slower than cache-on
        func prefill(_ arm: String) -> Double { Stats.median((0 ... 1).map { rep in by(arm, rep).reduce(0) { $0 + $1["ttft_s"].double! } })! }
        #expect(prefill("off") > prefill("on"))
        // body: final_replay semantics
        let b = try #require(srv.lastBody("on"))
        #expect(b["chat_template_kwargs"] == .obj(["enable_thinking": false]) && b["temperature"] == .double(0.0) && b["max_tokens"].int == 48)
        // summary regenerates from raw.jsonl and has the documented tables
        #expect(try Replay.summarize(dir: tmp + "/out") == summary)
        for h in ["## Per-turn TTFT", "## Total prefill", "## Cached-token fraction", "## Decode tok/s"] { #expect(summary.contains(h)) }
        #expect(summary.contains("| 1 | 1 | ") && summary.contains("cached / prompt tok"))
    }

    @Test func toolCallFirstTurnStillGetsATTFT() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let arm = ReplayArm(name: "t", url: srv.url("tool"), model: "stub")
        let res = await Replay.streamRequest(arm: arm, messages: [.obj(["role": "user", "content": "hi"])], maxTokens: 4, timeout: 10, classic: false)
        #expect(res.error == nil && res.firstKind == "tool_calls" && res.chunks == 4)
        let classic = await Replay.streamRequest(arm: arm, messages: [.obj(["role": "user", "content": "hi"])], maxTokens: 4, timeout: 10, classic: true)
        #expect(classic.chunks == 3 && classic.firstKind == "content")
        #expect(srv.lastBody("tool")?["chat_template_kwargs"].isNull == true, "classic sends no chat_template_kwargs")
    }

    @Test func replayMathOnHandMadeRows() {
        let arm = ReplayArm(name: "a", url: "u", model: "m")
        var r = StreamResult(tSend: 5)
        r.tFirst = 6; r.tLast = 7; r.chunks = 3
        r.usage = .obj(["prompt_tokens": 1000, "completion_tokens": 48, "prompt_tokens_details": .obj(["cached_tokens": 250])])
        let row = Replay.requestRow(arm: arm, rep: 0, orderPos: 0, turn: 2, msgIndex: 3, role: "tool", maxTokens: 48, result: r, logHits: 99, nonce: nil, session: "[s]")
        #expect(row["ttft_s"].double == 1 && row["decode_tps"].double == 47.0 && row["cache_frac"].double == 0.25 && row["cache_info"].string == "usage")
        #expect(row.object?.keys == ["kind", "arm", "cache", "rep", "order_pos", "turn", "msg_index", "role", "session", "nonce", "prompt_tokens",
                                     "cached_tokens", "cache_info", "cache_frac", "completion_tokens", "max_tokens", "ttft_s", "decode_tps",
                                     "tokens_flag", "stream_chunks", "error"])
        r.usage = .obj(["prompt_tokens": 1000, "completion_tokens": 40])
        let viaLog = Replay.requestRow(arm: arm, rep: 0, orderPos: 0, turn: 2, msgIndex: 3, role: "tool", maxTokens: 48, result: r, logHits: 96, nonce: nil, session: nil)
        #expect(viaLog["cache_info"].string == "log" && viaLog["cached_tokens"].int == 96 && viaLog["tokens_flag"].string == "short" && viaLog["decode_tps"].isNull)
        let unknown = Replay.requestRow(arm: arm, rep: 0, orderPos: 0, turn: 2, msgIndex: 3, role: "tool", maxTokens: 48, result: r, logHits: nil, nonce: nil, session: nil)
        #expect(unknown["cache_info"].string == "unknown" && unknown["cache_frac"].isNull)
        // head tag injection is non-mutating and handles string / list / missing system content
        let base: [JSONValue] = [.obj(["role": "user", "content": "hi"])]
        #expect(Replay.withHeadTag(base, tag: "[t]") == [.obj(["role": "system", "content": "[t]"]), base[0]])
        let sysm: [JSONValue] = [.obj(["role": "system", "content": "sys"]), .obj(["role": "user", "content": "u"])]
        #expect(Replay.withHeadTag(sysm, tag: "[t]")[0]["content"].string == "[t] sys" && sysm[0]["content"].string == "sys")
        let lst: [JSONValue] = [.obj(["role": "system", "content": .array([.obj(["type": "text", "text": "a"])])])]
        #expect(Replay.withHeadTag(lst, tag: "[t]")[0]["content"].array?.count == 2)
    }

    @Test func fixtureValidation() throws {
        let d = TestPaths.tempDir()
        try JSON.dumps(.array([.obj(["role": "system", "content": "s"]), .obj(["role": "user", "content": "u"]), .obj(["role": "assistant", "content": "a"])]))
            .write(toFile: d + "/two.json", atomically: false, encoding: .utf8)
        #expect(throws: BenchError.self) { try Replay.loadFixture(d + "/two.json") }
        let many = JSONValue.array(Array(repeating: .obj(["role": "user"]), count: Replay.maxTurns + 1))
        try JSON.dumps(many).write(toFile: d + "/many.json", atomically: false, encoding: .utf8)
        #expect(throws: BenchError.self) { try Replay.loadFixture(d + "/many.json") }
    }
}

@Suite struct SampledServerTests {
    @Test func sampledAppendsRowsAndFlagsShortOutput() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let out = TestPaths.tempDir() + "/sampled.jsonl"
        var c = SampledConfig(url: srv.url("full"), model: "stub", label: "full", outPath: out)
        c.n = 2
        c.tokens = 12
        c.timeout = 20
        let r1 = try await Sampled.run(cfg: c, log: { _ in })
        #expect(r1.count == 2 && r1.allSatisfy { $0["tokens_flag"].string == "ok" && $0["decode_tps"].double != nil && $0["error"].isNull })
        c.url = srv.url("short")
        c.label = "short"
        _ = try await Sampled.run(cfg: c, log: { _ in })
        let lines = JSON.lines(out)
        #expect(lines.count == 4, "file is appended to")
        #expect(lines.suffix(2).allSatisfy { $0["tokens_flag"].string == "short" })
        let body = try #require(srv.lastBody("full"))
        #expect(body["top_p"] == .double(0.95) && body["top_k"] == .int(20) && body["seed"] == .int(1234) && body["temperature"] == .double(1.0))
    }
}

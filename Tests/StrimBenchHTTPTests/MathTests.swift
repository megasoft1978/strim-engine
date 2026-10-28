import Foundation
import Testing
@testable import StrimBenchHTTP

@Suite struct JSONCompatTests {
    @Test func floatReprMatchesPython() {
        let cases: [(Double, String)] = [
            (63.28040249981089, "63.28040249981089"), (1.0, "1.0"), (100.0, "100.0"), (0.1, "0.1"), (0.0001, "0.0001"),
            (0.00001, "1e-05"), (1e16, "1e+16"), (1e15, "1000000000000000.0"), (123456789012345680.0, "1.2345678901234568e+17"),
            (5e-324, "5e-324"), (-2.5, "-2.5"), (0.0, "0.0"), (1.5e-7, "1.5e-07"), (12345.678, "12345.678"),
        ]
        for (d, s) in cases { #expect(pyFloatRepr(d) == s, "repr(\(d))") }
    }

    @Test func dumpsMatchesPythonLayout() throws {
        let v = JSONValue.obj(["a": 1, "b": .array([.double(1.5), "x\u{e9}\"\n", .null, true]), "c": .obj([:]), "d": .array([])])
        #expect(JSON.dumps(v) == #"{"a": 1, "b": [1.5, "x\u00e9\"\n", null, true], "c": {}, "d": []}"#)
        #expect(JSON.dumps(v, indent: 1) == "{\n \"a\": 1,\n \"b\": [\n  1.5,\n  \"x\\u00e9\\\"\\n\",\n  null,\n  true\n ],\n \"c\": {},\n \"d\": []\n}")
        #expect(JSON.dumps(.string("\u{1F600}\u{7F}")) == "\"\\ud83d\\ude00\\u007f\"")
        #expect(JSON.dumps(.string("\u{e9}"), ensureASCII: false) == "\"\u{e9}\"")
    }

    @Test func parseKeepsOrderAndIntFloatDistinction() throws {
        let v = try JSON.parse(#"{"z": 1, "a": 2.0, "m": [1e3, -0.5, 7], "s": "\ud83d\ude00\u00e9"}"#)
        #expect(v.object?.keys == ["z", "a", "m", "s"])
        #expect(v["z"] == .int(1) && v["a"] == .double(2.0))
        #expect(v["m"].array == [.double(1000), .double(-0.5), .int(7)])
        #expect(v["s"].string == "\u{1F600}\u{e9}")
        #expect(throws: (any Error).self) { try JSON.parse("{not json}") }
        #expect(throws: (any Error).self) { try JSON.parse("[1, 2") }
    }

    @Test func truthinessFollowsPython() {
        #expect(!JSONValue.string("").truthy && JSONValue.string("a").truthy && !JSONValue.array([]).truthy)
        #expect(!JSONValue.int(0).truthy && JSONValue.double(0.5).truthy && !JSONValue.null.truthy)
        #expect(!JSONValue.obj([:]).truthy && JSONValue.obj(["a": 1]).truthy)
    }
}

@Suite struct StatsTests {
    @Test func medianAndMean() {
        #expect(Stats.median([3, 1, 2]) == 2)
        #expect(Stats.median([4, 1, 2, 3]) == 2.5)
        #expect(Stats.median([]) == nil)
        #expect(Stats.med([nil, 5, nil, 7]) == 6)
        #expect(Stats.mean([0.1, 0.2, 0.3])! == 0.20000000000000001)
    }

    @Test func stdevMatchesExactArithmetic() {
        // Python: statistics.pstdev([63.75458507339427, 63.1546160910484, 63.406188908573384, 62.60736401454115])
        let v = [63.75458507339427, 63.1546160910484, 63.406188908573384, 62.60736401454115]
        let ps = Stats.pstdev(v)!
        let cv = ps / Stats.mean(v)! * 100
        #expect(cv == 0.6613988040806836, "cv_pct as committed in results.json")
        #expect(Stats.stdev([2, 4, 4, 4, 5, 5, 7, 9])! == (32.0 / 7).squareRoot())
        #expect(Stats.pstdev([2, 4, 4, 4, 5, 5, 7, 9]) == 2)
        #expect(Stats.stdev([1]) == nil)
    }

    @Test func neumaierSumMatchesPython312() {
        // sum([0.1]*10) == 1.0 under Neumaier; naive summation gives 0.9999999999999999
        #expect(pySum([Double](repeating: 0.1, count: 10)) == 1.0)
        #expect(pySum([1e100, 1.0, -1e100]) == 1.0)
    }

    @Test func stableSortKeepsTieOrderLikePythonReverse() {
        let items = [("a", 1.0), ("b", 2.0), ("c", 2.0), ("d", 0.5)]
        #expect(stableSorted(items, key: { $0.1 }, reverse: true).map(\.0) == ["b", "c", "a", "d"])
        #expect(stableSorted(items, key: { $0.1 }, reverse: false).map(\.0) == ["d", "a", "b", "c"])
    }
}

/// TTFT / decode / usage / flag math on hand-made SSE traces (no network).
@Suite struct SSETraceTests {
    func content(_ s: String) -> String { #"data: {"choices":[{"index":0,"delta":{"content":"\#(s)"}}]}"# }

    func run(_ lines: [(Double, String)], keys: [String] = PieceKeys.scoreboard, tSend: Double = 100.0) throws -> StreamResult {
        var p = SSEParser(tSend: tSend, pieceKeys: keys)
        for (t, l) in lines { if try p.feed(line: l, at: t) { break } }
        return p.finish(error: nil, noOutputMessage: "no output chunk", at: lines.last?.0 ?? tSend)
    }

    @Test func ttftAndDecodeFromTimestamps() throws {
        // send at 100.0; first token 100.5; last 102.5; 21 completion tokens => (21-1)/(102.5-100.5) = 10 tok/s
        let lines: [(Double, String)] = [
            (100.1, ": keep-alive"), (100.5, content("a")), (101.0, content("b")), (102.5, content("c")),
            (102.6, #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":21,"prompt_tokens_details":{"cached_tokens":4}}}"#),
            (102.7, "data: [DONE]"), (999, content("never read")),
        ]
        let res = try run(lines)
        #expect(res.tFirst == 100.5 && res.tLast == 102.5 && res.chunks == 3 && res.error == nil && res.text == "abc")
        let it = Item(item: "x", prompt: "p", maxTokens: 21, temperature: 0, seed: nil, target: nil)
        let row = Scoreboard.requestRow(workload: "W1", variant: "v", concurrency: 1, arm: Arm(name: "a", url: "u", model: "m"), rep: 0, slot: 0,
                                        item: it, result: res, prompter: Prompter(seed: "s", tokenizer: nil, note: ""))
        #expect(row["ttft_s"].double == 0.5)
        #expect(row["decode_tps"].double == 10.0)
        #expect(row["tokens_flag"].string == "ok" && row["cached_tokens"].int == 4 && row["cache_info"].string == "usage")
        #expect(row["cache_flag"].string == "hit" && row["prompt_tokens"].int == 10)
    }

    @Test func reasoningAndToolDeltasCountPerHarnessRules() throws {
        let reason = #"data: {"choices":[{"delta":{"reasoning_content":"think"}}]}"#
        let reason2 = #"data: {"choices":[{"delta":{"reasoning":"more"}}]}"#
        let tool = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0}]}}]}"#
        let empty = #"data: {"choices":[{"delta":{"content":""}}]}"#
        // scoreboard: reasoning is output, content keeps priority, tool_calls is not output
        var r = try run([(1, tool), (2, empty), (3, reason), (4, reason2), (5, content("x"))], tSend: 0)
        #expect(r.tFirst == 3 && r.chunks == 3 && r.reasoningChunks == 2 && r.text == "thinkmorex")
        // replay (final_replay.py): the first output may be a tool call
        r = try run([(1, tool), (2, content("x"))], keys: PieceKeys.replay, tSend: 0)
        #expect(r.tFirst == 1 && r.firstKind == "tool_calls" && r.chunks == 2)
        // classic agent_replay.py: content only, so a tool-call-first turn has TTFT from the first content chunk
        r = try run([(1, tool), (2, reason), (3, content("x"))], keys: PieceKeys.classic, tSend: 0)
        #expect(r.tFirst == 3 && r.chunks == 1)
    }

    @Test func noOutputAndBadJSON() throws {
        let r = try run([(1, ": ping"), (2, "data: [DONE]")], tSend: 0)
        #expect(r.error == "no output chunk" && r.tFirst == nil)
        var p = SSEParser(tSend: 0, pieceKeys: PieceKeys.scoreboard)
        _ = try p.feed(line: content("a"), at: 1)
        #expect(throws: (any Error).self) { try p.feed(line: "data: {oops", at: 2) }
        let done = p.finish(error: "JSONDecodeError: x", noOutputMessage: "no output chunk", at: 3)
        #expect(done.error == "JSONDecodeError: x" && done.tFirst == 1, "partial timing survives the error")
    }

    @Test func lastUsageWinsEmptyUsageIgnored() throws {
        let r = try run([(1, content("a")), (2, #"data: {"choices":[],"usage":{"completion_tokens":3}}"#), (3, #"data: {"choices":[],"usage":{}}"#)], tSend: 0)
        #expect(r.usage?["completion_tokens"].int == 3)
    }

    func row(_ res: StreamResult, N: Int = 8, tokenizer: TextTokenizer? = nil) -> JSONValue {
        Scoreboard.requestRow(workload: "W1", variant: "v", concurrency: 1, arm: Arm(name: "a", url: "u", model: "m"), rep: 0, slot: 0,
                              item: Item(item: "x", prompt: "p", maxTokens: N, temperature: 0, seed: nil, target: nil), result: res,
                              prompter: Prompter(seed: "s", tokenizer: tokenizer, note: ""))
    }

    struct FixedTok: TextTokenizer {
        let n: Int
        func encode(_ text: String) -> [Int] { Array(repeating: 1, count: n) }
        func decode(_ ids: [Int]) -> String { "" }
    }

    func base(usage: JSONValue?) -> StreamResult {
        var r = StreamResult(tSend: 0)
        r.tFirst = 0.1; r.tLast = 0.5; r.tEnd = 0.6; r.chunks = 2; r.text = "a b"; r.usage = usage
        return r
    }

    @Test func tokenFlagsAndIgnoreEosRule() {
        func flag(_ n: Int?, N: Int = 8, tok: TextTokenizer? = nil) -> JSONValue {
            row(base(usage: n.map { .obj(["completion_tokens": .int($0)]) }), N: N, tokenizer: tok)
        }
        #expect(flag(8)["tokens_flag"].string == "ok" && flag(8)["decode_tps"].double == 7 / 0.4)
        // ignore_eos not honoured => short => excluded from decode
        let s = flag(5)
        #expect(s["tokens_flag"].string == "short" && s["decode_tps"].isNull && s["ttft_s"].double == 0.1)
        #expect(flag(9)["tokens_flag"].string == "mismatch" && flag(9)["decode_tps"].double != nil)
        #expect(flag(nil)["tokens_flag"].string == "no_usage" && flag(nil)["decode_tps"].isNull && flag(nil)["completion_tokens"].isNull)
        let rt = flag(nil, tok: FixedTok(n: 8))
        #expect(rt["tokens_flag"].string == "retokenized" && rt["completion_tokens"].int == 8 && rt["decode_tps"].double != nil)
        #expect(flag(nil, tok: FixedTok(n: 3))["tokens_flag"].string == "short")
        var err = base(usage: nil)
        err.error = "boom"
        #expect(row(err)["tokens_flag"].isNull && row(err)["error"].string == "boom")
    }

    @Test func decodeNeedsTwoTokensAndPositiveSpan() {
        var one = base(usage: .obj(["completion_tokens": 1]))
        #expect(row(one, N: 1)["decode_tps"].isNull)
        one.tLast = one.tFirst
        #expect(row(one, N: 1)["decode_tps"].isNull)
        var same = base(usage: .obj(["completion_tokens": 8]))
        same.tLast = same.tFirst
        #expect(row(same)["decode_tps"].isNull, "zero span gives no decode")
    }

    @Test func cacheFlagByWorkload() {
        #expect(Scoreboard.cacheFlag("W4", nil) == "unverified" && Scoreboard.cacheFlag("W1", nil) == "unknown")
        #expect(Scoreboard.cacheFlag("W4", 0) == "ok_zero" && Scoreboard.cacheFlag("W5", 12) == "hit")
    }

    @Test func requestBodyKeyOrderAndFields() throws {
        let b = Scoreboard.requestBody(model: "m", prompt: "hi", maxTokens: 8, temperature: 0.6, seed: 7, noThink: true)
        #expect(String(decoding: b, as: UTF8.self) == #"{"model": "m", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, "temperature": 0.6, "stream": true, "stream_options": {"include_usage": true}, "ignore_eos": true, "chat_template_kwargs": {"enable_thinking": false}, "seed": 7}"#)
        let g = Scoreboard.requestBody(model: "m", prompt: "hi", maxTokens: 8, temperature: 0.0, seed: nil, noThink: false)
        #expect(!String(decoding: g, as: UTF8.self).contains("seed") && !String(decoding: g, as: UTF8.self).contains("chat_template_kwargs"))
        let s = Sampled.requestBody(model: "m", tokens: 256)
        let sj = try JSON.parse(s)
        #expect(sj["temperature"] == .double(1.0) && sj["top_p"] == .double(0.95) && sj["top_k"] == .int(20) && sj["seed"] == .int(1234))
        #expect(sj["ignore_eos"] == .bool(true) && sj["chat_template_kwargs"]["enable_thinking"] == .bool(false))
    }

    @Test func sampledRowMath() {
        var r = StreamResult(tSend: 10)
        r.tFirst = 10.2; r.tLast = 15.2; r.usage = .obj(["prompt_tokens": 47, "completion_tokens": 256, "prompt_tokens_details": .obj(["cached_tokens": 0])])
        r.text = String(repeating: "é", count: 200)
        let row = Sampled.row(label: "e", index: 0, tokens: 256, result: r)
        #expect(row["decode_tps"].double == 255.0 / 5.0 && row["ttft_s"].double == 10.2 - 10 && row["tokens_flag"].string == "ok")
        #expect(row["cached_tokens"].int == 0 && row["text_head"].string?.unicodeScalars.count == 120)
        #expect(row.object?.keys == ["label", "i", "t_first", "t_last", "usage", "error", "completion_tokens", "prompt_tokens", "cached_tokens",
                                     "decode_tps", "ttft_s", "tokens_flag", "text_head"])
        r.usage = .obj(["completion_tokens": 100])
        #expect(Sampled.row(label: "e", index: 0, tokens: 256, result: r)["tokens_flag"].string == "short")
        r.usage = nil
        let nu = Sampled.row(label: "e", index: 0, tokens: 256, result: r)
        #expect(nu["tokens_flag"].string == "no_usage" && nu["decode_tps"].isNull)
    }
}

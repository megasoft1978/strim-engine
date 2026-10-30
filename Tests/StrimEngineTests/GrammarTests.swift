import Foundation
import StrimTemplate
import Testing
@testable import StrimEngine

/// Fake vocabulary: 256 single bytes, a handful of multi-byte pieces (JSON punctuation, words, tool tags),
/// and one end-of-turn id that is never in the trie.
struct FakeVocab {
    var tokens: [[UInt8]] = (0 ..< 256).map { [UInt8($0)] }
    let eos: Int32
    init() {
        for s in ["{\"", "\":", "\",", "\"}", "\": ", "\", \"", "true", "false", "null", "[\"", "\"]", "{}", "[]",
                  "  ", "\n", "\n  ", "123", "12", "-1", "0.5", "e+", "name", "age", "Paris", "hello", " world",
                  "<tool_call>", "</tool_call>", "<function=", "<parameter=", "</parameter>", "</function>",
                  ">\n", "\n</parameter>\n", "é", "日本", "\\n", "\\\"",
                  "the", " the", "city", "get_weather", "<think>", "</think>", "<|im_end|>"] where !s.isEmpty {
            tokens.append(Array(s.utf8))
        }
        eos = Int32(tokens.count - 1)
    }
    func engine() -> GrammarEngine {
        let t = tokens
        let e = eos
        return GrammarEngine(vocabCount: t.count, tokenBytes: { t[Int($0)] }, eos: [e], skip: { $0 == Int(e) })
    }
}

struct Walk {
    var out: [UInt8] = []
    var ids: [Int32] = []
    var finished = false
    var steps = 0
}

/// Random walk through the mask: always picks an allowed token; ends on EOS.
private func randomWalk(_ rt: GrammarRuntime, _ v: FakeVocab, seed: UInt64, maxSteps: Int = 400, eosBias: Double = 0.5) -> Walk {
    var rng = SplitMix(seed)
    var s = rt.start
    var w = Walk()
    while w.steps < maxSteps {
        w.steps += 1
        let mask = rt.mask(s)
        var allowed: [Int] = []
        for id in 0 ..< v.tokens.count where mask[id >> 6] >> UInt64(id & 63) & 1 == 1 { allowed.append(id) }
        precondition(!allowed.isEmpty, "empty mask at state \(s)")
        if allowed.contains(Int(v.eos)) && (rng.unit() < eosBias || allowed.count == 1) { w.finished = true; break }
        // prefer closing structure as the walk gets long: pick uniformly from allowed (no EOS)
        let pool = allowed.filter { $0 != Int(v.eos) }
        let id = pool[Int(rng.next() % UInt64(pool.count))]
        w.out += v.tokens[id]
        w.ids.append(Int32(id))
        s = rt.advance(s, bytes: v.tokens[id])
        precondition(s >= 0, "allowed token killed the grammar")
    }
    return w
}

private struct SplitMix {
    var x: UInt64
    init(_ s: UInt64) { x = s }
    mutating func next() -> UInt64 {
        x &+= 0x9E37_79B9_7F4A_7C15
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

private func isNum(_ j: OrderedJSON?) -> Bool {
    switch j { case .int?, .bigInt?, .double?: return true; default: return false }
}
private func isInt(_ j: OrderedJSON?) -> Bool {
    switch j { case .int?, .bigInt?: return true; default: return false }
}

private func schema(_ text: String) -> OrderedJSON { try! OrderedJSON.parse(text) }

private func runtime(_ spec: ConstraintSpec, _ v: FakeVocab) throws -> GrammarRuntime {
    try v.engine().runtime(for: spec, logitsWidth: v.tokens.count + 8)
}

@Suite struct GrammarTests {
    let vocab = FakeVocab()

    @Test("every random walk over an object schema is valid JSON with the declared shape")
    func objectSchemaWalks() throws {
        let s = schema(#"""
        {"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"},
          "tags":{"type":"array","items":{"type":"string"},"maxItems":3},
          "kind":{"enum":["a","b"]},"ok":{"type":"boolean"},"note":{"type":["string","null"]},
          "pt":{"type":"object","properties":{"x":{"type":"number"}},"required":["x"]}},
         "required":["name","age","kind","ok"]}
        """#)
        let rt = try runtime(ConstraintSpec(json: .schema(s)), vocab)
        var finished = 0
        for seed in 0 ..< 200 {
            let w = randomWalk(rt, vocab, seed: UInt64(seed), maxSteps: 600, eosBias: 0.7)
            guard w.finished else { continue }
            finished += 1
            let text = String(decoding: w.out, as: UTF8.self)
            let o = try OrderedJSON.parse(text)
            let keys = try #require(o.members, "not an object: \(text)").map(\.key)
            if case .string = o["name"] {} else { Issue.record("name: \(text)") }
            #expect(isInt(o["age"]), "age: \(text)")
            #expect(o["kind"] == .string("a") || o["kind"] == .string("b"))
            if case .bool = o["ok"] {} else { Issue.record("ok: \(text)") }
            #expect(Set(keys).isSubset(of: ["name", "age", "tags", "kind", "ok", "note", "pt"]))
            if case let .array(t)? = o["tags"] { #expect(t.count <= 3 && t.allSatisfy { if case .string = $0 { return true }; return false }) }
            if let p = o["pt"] { #expect(p.members?.map(\.key) == ["x"] && isNum(p["x"])) }
        }
        #expect(finished > 20, "only \(finished) walks finished")
    }

    @Test("json_object mode produces objects only")
    func jsonObject() throws {
        let rt = try runtime(ConstraintSpec(json: .object), vocab)
        var finished = 0
        for seed in 0 ..< 150 {
            let w = randomWalk(rt, vocab, seed: UInt64(seed), maxSteps: 300, eosBias: 0.8)
            guard w.finished else { continue }
            finished += 1
            let text = String(decoding: w.out, as: UTF8.self)
            #expect(try OrderedJSON.parse(text).members != nil, "\(text)")
        }
        #expect(finished > 20)
    }

    @Test("string tokens split multi-byte characters but stay valid UTF-8")
    func utf8() throws {
        let rt = try runtime(ConstraintSpec(json: .schema(schema(#"{"type":"string"}"#))), vocab)
        var s = rt.start
        for b in Array("\"".utf8) { s = rt.dfa.next(s, b) }
        // lone continuation byte is not allowed in the body; a lead byte then a continuation is
        #expect(rt.dfa.next(s, 0x80) < 0)
        let lead = rt.dfa.next(s, 0xC3)
        #expect(lead >= 0 && rt.dfa.next(lead, 0xA9) >= 0 && rt.dfa.next(lead, 0x41) < 0)
        #expect(rt.dfa.next(s, 0x0A) < 0, "raw newline inside a string is invalid JSON")
        #expect(rt.dfa.next(s, 0x5C) >= 0)
    }

    @Test("enum, const, anyOf and nullable are exact")
    func choices() throws {
        func accepts(_ schemaText: String, _ text: String) throws -> Bool {
            let rt = try runtime(ConstraintSpec(json: .schema(schema(schemaText))), vocab)
            var s = rt.start
            for b in text.utf8 { s = rt.dfa.next(s, b); if s < 0 { return false } }
            return rt.dfa.accepting[Int(s)]
        }
        #expect(try accepts(#"{"enum":["red","green",3,null]}"#, "\"green\""))
        #expect(try accepts(#"{"enum":["red","green",3,null]}"#, "3"))
        #expect(try accepts(#"{"enum":["red","green",3,null]}"#, "null"))
        #expect(try !accepts(#"{"enum":["red","green",3,null]}"#, "\"blue\""))
        #expect(try accepts(#"{"const":{"a":1}}"#, #"{"a":1}"#))
        #expect(try !accepts(#"{"const":{"a":1}}"#, #"{"a":2}"#))
        #expect(try accepts(#"{"anyOf":[{"type":"integer"},{"type":"string"}]}"#, "42"))
        #expect(try accepts(#"{"anyOf":[{"type":"integer"},{"type":"string"}]}"#, "\"x\""))
        #expect(try !accepts(#"{"anyOf":[{"type":"integer"},{"type":"string"}]}"#, "4.5"))
        #expect(try accepts(#"{"type":"string","nullable":true}"#, "null"))
        #expect(try !accepts(#"{"type":"integer"}"#, "01"))
        #expect(try !accepts(#"{"type":"integer"}"#, "1.5"))
        #expect(try accepts(#"{"type":"number"}"#, "-1.5e+10"))
        #expect(try !accepts(#"{"type":"number"}"#, "1."))
        #expect(try accepts(#"{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":3}"#, "[1,2]"))
        #expect(try !accepts(#"{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":3}"#, "[1]"))
        #expect(try !accepts(#"{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":3}"#, "[1,2,3,4]"))
        #expect(try accepts(#"{"type":"array","items":{"type":"integer"}}"#, "[ 1 , 2,3 ]"))
        #expect(try accepts(#"{"type":"object","properties":{"a":{"type":"integer"}}}"#, "{}"))
        #expect(try !accepts(#"{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}"#, "{}"))
        #expect(try !accepts(#"{"type":"object","properties":{"a":{"type":"integer"}}}"#, #"{"b":1}"#))
        #expect(try accepts(#"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["b"]}"#, #"{"a":1,"b":2}"#))
        #expect(try accepts(#"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["b"]}"#, #"{"b":2}"#))
        #expect(try !accepts(#"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["b"]}"#, #"{"b":2,"a":1}"#), "declared order only")
    }

    @Test("$ref and recursive schemas")
    func refs() throws {
        let s = ##"{"$defs":{"node":{"type":"object","properties":{"v":{"type":"integer"},"next":{"anyOf":[{"$ref":"#/$defs/node"},{"type":"null"}]}},"required":["v","next"]}},"$ref":"#/$defs/node"}"##
        let rt = try runtime(ConstraintSpec(json: .schema(schema(s))), vocab)
        var st = rt.start
        for b in #"{"v":1,"next":{"v":2,"next":null}}"#.utf8 { st = rt.dfa.next(st, b); #expect(st >= 0) }
        #expect(rt.dfa.accepting[Int(st)])
    }

    @Test("unsupported keywords are rejected with a clear message")
    func rejects() throws {
        for (text, needle) in [
            (#"{"type":"string","pattern":"^a"}"#, "pattern"),
            (#"{"type":"string","format":"date-time"}"#, "format"),
            (#"{"type":"integer","minimum":1}"#, "minimum"),
            (#"{"oneOf":[{"type":"string"}]}"#, "oneOf"),
            (#"{"allOf":[{"type":"string"}]}"#, "allOf"),
            (#"{"type":"object","properties":{"a":{"type":"string","maxLength":3}}}"#, "maxLength"),
            (#"{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":true}"#, "additionalProperties"),
            (#"{"type":"object","properties":{"a":{"type":"string"}},"required":["b"]}"#, "required"),
            (#"{"$ref":"http://x/y"}"#, "$ref"),
            (#"{"type":"wat"}"#, "wat"),
        ] {
            do {
                _ = try GrammarProgram.compile(ConstraintSpec(json: .schema(schema(text))))
                Issue.record("accepted \(text)")
            } catch let e as GrammarError {
                #expect(e.message.contains(needle), "\(e.message) lacks \(needle)")
            }
        }
    }

    @Test("terminal state allows only end-of-turn; accepting state allows it")
    func terminal() throws {
        let rt = try runtime(ConstraintSpec(json: .schema(schema(#"{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}"#))), vocab)
        var s = rt.start
        for b in #"{"a":1}"#.utf8 { s = rt.dfa.next(s, b) }
        #expect(rt.dfa.accepting[Int(s)])
        // trailing whitespace is still possible, so not terminal, but EOS is in the mask
        let m = rt.mask(s)
        let eos = Int(vocab.eos)
        #expect(m[eos >> 6] >> UInt64(eos & 63) & 1 == 1)
        let mid = rt.advance(rt.start, bytes: Array("{\"a\":".utf8))
        let mm = rt.mask(mid)
        #expect(mm[eos >> 6] >> UInt64(eos & 63) & 1 == 0)
    }

    @Test("forced tool call: random walks parse as tool calls with valid arguments")
    func toolCalls() throws {
        let params = schema(#"{"type":"object","properties":{"city":{"type":"string","enum":["Paris","Oslo"]},"days":{"type":"integer"},"unit":{"type":"string","enum":["c","f"]},"deep":{"type":"boolean"}},"required":["city","days"]}"#)
        let tool = ToolSpec(name: "get_weather", description: "", parameters: params)
        let other = ToolSpec(name: "ping", description: "", parameters: schema(#"{"type":"object","properties":{}}"#))
        let spec = ConstraintSpec(toolCalls: .init(tools: [tool, other], name: "get_weather", parallel: false, forced: true))
        let rt = try runtime(spec, vocab)
        var finished = 0
        for seed in 0 ..< 120 {
            let w = randomWalk(rt, vocab, seed: UInt64(seed), maxSteps: 300, eosBias: 0.9)
            guard w.finished else { continue }
            finished += 1
            var parser = ToolCallParser(tools: [tool, other])
            var evs = parser.feed(String(decoding: w.out, as: UTF8.self))
            evs += parser.finish()
            var begins = 0, ends = 0
            var keys: [String] = []
            for e in evs.coalesced() {
                switch e {
                case let .toolCallBegin(name): begins += 1; #expect(name == "get_weather")
                case let .toolCallArg(k, v):
                    keys.append(k)
                    if k == "days" { switch v { case .int, .bigInt: break; case let .string(d): #expect(d.allSatisfy { $0.isNumber }); default: Issue.record("days not int: \(v)") } }
                    if k == "deep" { if case .bool = v {} else { Issue.record("deep not bool: \(v)") } }
                    if k == "unit" { #expect(v == .string("c") || v == .string("f")) }
                case .toolCallEnd: ends += 1
                case .text, .reasoning, .toolCallError: Issue.record("stray text in forced tool call: \(String(decoding: w.out, as: UTF8.self))")
                }
            }
            #expect(begins == 1 && ends == 1)
            #expect(keys.starts(with: ["city", "days"]) && Set(keys).isSubset(of: ["city", "days", "unit", "deep"]))
        }
        #expect(finished > 20, "only \(finished) walks finished")
    }

    @Test("required tool call with several tools allows any of them, auto+json allows either")
    func toolChoiceSets() throws {
        let a = ToolSpec(name: "a", description: "", parameters: schema(#"{"type":"object","properties":{}}"#))
        let b = ToolSpec(name: "b", description: "", parameters: schema(#"{"type":"object","properties":{}}"#))
        let rt = try runtime(ConstraintSpec(toolCalls: .init(tools: [a, b])), vocab)
        for name in ["a", "b"] {
            var s = rt.start
            for byte in "<tool_call>\n<function=\(name)>\n</function>\n</tool_call>".utf8 { s = rt.dfa.next(s, byte); #expect(s >= 0) }
            #expect(rt.dfa.accepting[Int(s)])
        }
        var s = rt.start
        for byte in "hello".utf8.prefix(1) { s = rt.dfa.next(s, byte) }
        #expect(s < 0, "free text is not allowed when a tool call is required")
        // unknown function name
        #expect(rt.advance(rt.start, bytes: Array("<tool_call>\n<function=c>".utf8)) < 0)
        // auto + json_object
        let both = try runtime(ConstraintSpec(json: .object, toolCalls: .init(tools: [a], forced: false)), vocab)
        #expect(both.advance(both.start, bytes: Array("{\"x\":1}".utf8)) >= 0)
        #expect(both.advance(both.start, bytes: Array("<tool_call>\n<function=a>\n</function>\n</tool_call>".utf8)) >= 0)
        #expect(both.advance(both.start, bytes: Array("hi".utf8)) < 0)
        // named function that does not exist
        #expect(throws: GrammarError.self) {
            _ = try GrammarProgram.compile(ConstraintSpec(toolCalls: .init(tools: [a], name: "zzz")))
        }
    }

    @Test("raw string parameter ends only at the terminator and may contain angle brackets")
    func rawParam() throws {
        let tool = ToolSpec(name: "w", description: "", parameters: schema(#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#))
        let rt = try runtime(ConstraintSpec(toolCalls: .init(tools: [tool], parallel: false)), vocab)
        let text = "<tool_call>\n<function=w>\n<parameter=text>\na < b </x> \nline2\n</parameter>\n</function>\n</tool_call>"
        let s = rt.advance(rt.start, bytes: Array(text.utf8))
        #expect(s >= 0 && rt.dfa.accepting[Int(s)])
    }

    @Test("raw parameter text and strings only admit valid UTF-8")
    func rawUTF8() throws {
        let tool = ToolSpec(name: "w", description: "", parameters: schema(#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#))
        let rt = try runtime(ConstraintSpec(toolCalls: .init(tools: [tool], parallel: false)), vocab)
        let head = rt.advance(rt.start, bytes: Array("<tool_call>\n<function=w>\n<parameter=text>\n".utf8))
        #expect(rt.dfa.next(head, 0x80) < 0, "lone continuation")
        #expect(rt.dfa.next(head, 0xC0) < 0, "overlong lead")
        let e0 = rt.dfa.next(head, 0xE0)
        #expect(e0 >= 0 && rt.dfa.next(e0, 0x80) < 0 && rt.dfa.next(e0, 0xA0) >= 0, "E0 80 is overlong")
        let f4 = rt.dfa.next(head, 0xF4)
        #expect(f4 >= 0 && rt.dfa.next(f4, 0x90) < 0, "beyond U+10FFFF")
        let cjk = rt.advance(head, bytes: Array("日本".utf8))
        #expect(cjk >= 0)
        #expect(rt.advance(cjk, bytes: Array("\n</parameter>\n</function>\n</tool_call>".utf8)) >= 0)
    }

    @Test("masks are cached and cheap on repeat")
    func maskCache() throws {
        let rt = try runtime(ConstraintSpec(json: .object), vocab)
        _ = rt.mask(rt.start)
        let n = rt.maskBuilds
        _ = rt.mask(rt.start)
        #expect(rt.maskBuilds == n)
    }
}


import MLX
import StrimCore

@Suite struct ConstraintRowTests {
    @Test("verify rows: valid draft keeps its mask, rows after an invalid draft are unconstrained, greedy masked argmax rejects it")
    func verifyRows() throws {
        let v = FakeVocab()
        let eng = v.engine()
        let spec = ConstraintSpec(json: .schema(try OrderedJSON.parse(#"{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}"#)))
        let width = v.tokens.count + 8
        let rt = try eng.runtime(for: spec, logitsWidth: width)
        let c = RequestConstraint(rt: rt, engine: eng, masks: DeviceMasks(), width: width, budget: nil, closeId: -1, startsInThink: false)
        let open = v.tokens.firstIndex(of: Array("{".utf8))!, quote = v.tokens.firstIndex(of: Array("\"".utf8))!, x = v.tokens.firstIndex(of: Array("x".utf8))!
        // state: nothing emitted yet. Drafts: "{" (valid), "x" (invalid after "{"), "{" (after the violation)
        let m = try #require(c.verifyMask(drafts: [Int32(open), Int32(x), Int32(open)]))
        let rows = m.asType(.int32).reshaped([4, width])
        eval(rows)
        func allowed(_ r: Int, _ id: Int) -> Bool { rows[r, id].item(Int32.self) == 1 }
        #expect(allowed(0, open) && !allowed(0, x))
        #expect(allowed(1, quote) && !allowed(1, x))
        #expect((0 ..< width).allSatisfy { allowed(2, $0) } && (0 ..< width).allSatisfy { allowed(3, $0) })
        // masked greedy: a logit peak on a forbidden token must not win
        var peak = [Float](repeating: 0, count: width); peak[x] = 10; peak[quote] = 1
        let l = MLXArray(peak).reshaped([1, width])
        let masked = maskLogits(l, m[1 ..< 2])
        #expect(argMax(masked, axis: -1).item(Int32.self) == Int32(quote))
        // sampled verify: the forbidden draft is rejected with probability 1
        let (n, _) = SpecSampling.verify(logits: maskLogits(MLXArray(peak + peak).reshaped([2, width]), m[1 ..< 3]).asType(.float32), drafts: [Int32(x)],
                                         config: SamplingConfig(temperature: 1, seed: 3), firstIndex: 1)
        #expect(n.item(Int32.self) == 0)
        // unconstrained: no mask object
        let free = RequestConstraint(rt: nil, engine: eng, masks: DeviceMasks(), width: width, budget: nil, closeId: -1, startsInThink: false)
        #expect(free.verifyMask(drafts: [1, 2]) == nil && free.nextMask() == nil)
    }

    @Test("thinking budget forces the close token only once the budget is spent")
    func budget() throws {
        let v = FakeVocab()
        let eng = v.engine()
        let close = Int32(v.tokens.firstIndex(of: Array("</think>".utf8))!)
        let c = RequestConstraint(rt: nil, engine: eng, masks: DeviceMasks(), width: v.tokens.count + 8, budget: 3, closeId: close, startsInThink: true)
        #expect(c.nextMask() == nil)
        c.advance(65); c.advance(66)
        #expect(c.verifyMask(drafts: []) == nil)
        c.advance(67)
        let m = try #require(c.nextMask())
        eval(m)
        #expect(m.asType(.int32).sum().item(Int32.self) == 1 && m[Int(close)].item(Bool.self))
        c.advance(close)
        #expect(c.nextMask() == nil)
    }
}

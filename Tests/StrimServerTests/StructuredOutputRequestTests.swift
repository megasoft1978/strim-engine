import Foundation
import Testing
import StrimEngine
import StrimTemplate
@testable import StrimServer

private let tool = #"{"type":"function","function":{"name":"get_weather","description":"w","parameters":{"type":"object","properties":{"city":{"type":"string"},"days":{"type":"integer","minimum":1}},"required":["city"]}}}"#

private func chat(_ extra: String, tools: Bool = true) throws -> ChatRequest {
    let t = tools ? #","tools":[\#(tool)]"# : ""
    let body = #"{"messages":[{"role":"user","content":"hi"}]\#(t),\#(extra)}"#
    return try ChatRequest.parse(Data(body.utf8), headerPriority: nil, defaults: SamplingDefaults())
}

private func badRequest(_ extra: String, tools: Bool = true, contains needle: String) {
    do {
        _ = try chat(extra, tools: tools)
        Issue.record("accepted \(extra)")
    } catch let e as APIError {
        #expect(e.status == 400 && e.message.contains(needle), "\(e.message) lacks \(needle)")
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Suite("Structured output request fields")
struct StructuredOutputRequestTests {
    @Test("no new fields: no constraint")
    func plain() throws {
        #expect(try chat(#""temperature":0"#).params.constraint == nil)
        #expect(try chat(#""tool_choice":"auto""#).params.constraint?.hasGrammar != true)
    }

    @Test("response_format json_object / json_schema / text")
    func responseFormat() throws {
        #expect(try chat(#""response_format":{"type":"json_object"}"#, tools: false).params.constraint?.json == .object)
        let r = try chat(#""response_format":{"type":"json_schema","json_schema":{"name":"x","strict":true,"schema":{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}}}"#, tools: false)
        guard case let .schema(s)? = r.params.constraint?.json else { Issue.record("no schema"); return }
        #expect(s["type"]?.stringValue == "object")
        #expect(try chat(#""response_format":{"type":"text"}"#, tools: false).params.constraint == nil)
        badRequest(#""response_format":{"type":"xml"}"#, tools: false, contains: "response_format.type")
        badRequest(#""response_format":{"type":"json_schema","json_schema":{"name":"x"}}"#, tools: false, contains: "schema")
        badRequest(#""response_format":{"type":"json_schema","json_schema":{"schema":{"type":"string","pattern":"^a"}}}"#, tools: false, contains: "pattern")
        badRequest(#""response_format":{"type":"json_schema","json_schema":{"schema":{"oneOf":[{"type":"string"}]}}}"#, tools: false, contains: "oneOf")
    }

    @Test("tool_choice required and named are enforced, none hides tools")
    func toolChoice() throws {
        let req = try chat(#""tool_choice":"required""#)
        #expect(req.params.constraint?.toolCalls?.forced == true && req.params.constraint?.toolCalls?.name == nil)
        let named = try chat(#""tool_choice":{"type":"function","function":{"name":"get_weather"}},"parallel_tool_calls":false"#)
        #expect(named.params.constraint?.toolCalls?.name == "get_weather" && named.params.constraint?.toolCalls?.parallel == false)
        #expect(named.config.toolChoice == "required")
        let none = try chat(#""tool_choice":"none""#)
        #expect(none.params.constraint == nil && none.config.tools.isEmpty)
        let auto = try chat(#""tool_choice":"auto""#)
        #expect(auto.params.constraint?.hasGrammar != true)
        badRequest(#""tool_choice":"required""#, tools: false, contains: "at least one tool")
        badRequest(#""tool_choice":{"type":"function","function":{"name":"nope"}}"#, contains: "not in tools")
        badRequest(#""tool_choice":"sometimes""#, contains: "unsupported")
        badRequest(#""tool_choice":{"type":"allowed_tools"}"#, contains: "unsupported")
    }

    @Test("tool parameter schemas ignore value-narrowing keywords but response_format does not")
    func lenientTools() throws {
        // `minimum` inside the tool's parameters must not make a forced tool call fail
        _ = try chat(#""tool_choice":"required""#)
        // auto tools + json_object: both are allowed at once
        let both = try chat(#""response_format":{"type":"json_object"}"#)
        #expect(both.params.constraint?.json == .object && both.params.constraint?.toolCalls?.forced == false)
    }

    @Test("thinking_budget")
    func thinkingBudget() throws {
        #expect(try chat(#""thinking_budget":128"#, tools: false).params.constraint?.thinkingBudget == 128)
        #expect(try chat(#""thinking_token_budget":0"#, tools: false).params.constraint?.thinkingBudget == 0)
        #expect(try chat(#""chat_template_kwargs":{"thinking_budget":7}"#, tools: false).params.constraint?.thinkingBudget == 7)
        badRequest(#""thinking_budget":-1"#, tools: false, contains: "non-negative")
        badRequest(#""thinking_budget":"many""#, tools: false, contains: "non-negative")
    }

    // MARK: adapters

    private func anthropic(_ extra: String) throws -> ChatRequest {
        let body = #"{"model":"m","max_tokens":50,"messages":[{"role":"user","content":"hi"}],"tools":[{"name":"get_weather","description":"w","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}],\#(extra)}"#
        let t = try AnthropicAdapter.translate(Data(body.utf8), requireMaxTokens: true)
        return try ChatRequest.parse(Data(t.chat.serialized().utf8), headerPriority: nil, defaults: SamplingDefaults())
    }

    @Test("Anthropic tool_choice any/tool/none, parallel flag, budget_tokens, output_config")
    func anthropicParity() throws {
        let any = try anthropic(#""tool_choice":{"type":"any"}"#)
        #expect(any.params.constraint?.toolCalls?.forced == true && any.params.constraint?.toolCalls?.name == nil)
        let one = try anthropic(#""tool_choice":{"type":"tool","name":"get_weather","disable_parallel_tool_use":true}"#)
        #expect(one.params.constraint?.toolCalls?.name == "get_weather" && one.params.constraint?.toolCalls?.parallel == false)
        let none = try anthropic(#""tool_choice":{"type":"none"}"#)
        #expect(none.params.constraint == nil)
        let th = try anthropic(#""thinking":{"type":"enabled","budget_tokens":2048}"#)
        #expect(th.params.constraint?.thinkingBudget == 2048)
        let fmt = try anthropic(#""output_config":{"format":{"type":"json_schema","schema":{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}}}"#)
        guard case .schema? = fmt.params.constraint?.json else { Issue.record("no schema"); return }
        #expect(throws: APIError.self) { _ = try self.anthropic(#""tool_choice":{"type":"tool"}"#) }
    }

    @Test("Responses tool_choice function, text.format, thinking budget")
    func responsesParity() throws {
        func resp(_ extra: String) throws -> ChatRequest {
            let body = #"{"model":"m","input":"hi","tools":[{"type":"function","name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}],\#(extra)}"#
            let t = try ResponsesAdapter.translate(Data(body.utf8), store: ResponseStore())
            return try ChatRequest.parse(Data(t.chat.serialized().utf8), headerPriority: nil, defaults: SamplingDefaults())
        }
        let named = try resp(#""tool_choice":{"type":"function","name":"get_weather"}"#)
        #expect(named.params.constraint?.toolCalls?.name == "get_weather" && named.params.constraint?.toolCalls?.forced == true)
        #expect(try resp(#""tool_choice":"required""#).params.constraint?.toolCalls?.forced == true)
        let f = try resp(#""text":{"format":{"type":"json_schema","name":"o","strict":true,"schema":{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}}}"#)
        guard case .schema? = f.params.constraint?.json else { Issue.record("no schema"); return }
        #expect(try resp(#""text":{"format":{"type":"json_object"}}"#).params.constraint?.json == .object)
        #expect(try resp(#""thinking_budget":64"#).params.constraint?.thinkingBudget == 64)
        #expect(throws: APIError.self) { _ = try resp(#""text":{"format":{"type":"json_schema","schema":{"type":"string","format":"email"}}}"#) }
    }
}

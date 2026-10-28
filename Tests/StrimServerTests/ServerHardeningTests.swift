import Foundation
import Testing
import StrimEngine
import StrimHTTP
@testable import StrimServer

private func body(_ extra: String) -> Data {
    Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}],\#(extra)}"#.utf8)
}

/// F1 (parsers clamp), F7 (class ceiling, background clamps), F4 (/health).
@Suite("StrimServer hardening", .serialized) struct ServerHardeningTests {
    @Test func chatMaxTokensIsClamped() throws {
        for raw in ["200000000000000", "9223372036854775807", "1073741824"] {
            let r = try ChatRequest.parse(body(#""max_tokens":\#(raw)"#), headerPriority: nil, defaults: SamplingDefaults())
            #expect(r.params.maxTokens == 1 << 20, "max_tokens \(raw)")
        }
        let r = try ChatRequest.parse(body(#""max_completion_tokens":300"#), headerPriority: nil, defaults: SamplingDefaults())
        #expect(r.params.maxTokens == 300)
    }

    @Test func anthropicAndResponsesMaxTokensAreClamped() throws {
        let a = try AnthropicAdapter.translate(
            Data(#"{"model":"m","max_tokens":200000000000000,"messages":[{"role":"user","content":"hi"}]}"#.utf8), requireMaxTokens: true)
        let ac = try ChatRequest.parse(Data(a.chat.serialized().utf8), headerPriority: nil, defaults: SamplingDefaults())
        #expect(ac.params.maxTokens == 1 << 20)
        let t = try ResponsesAdapter.translate(
            Data(#"{"model":"m","max_output_tokens":9223372036854775807,"input":"hi"}"#.utf8), store: ResponseStore())
        let rc = try ChatRequest.parse(Data(t.chat.serialized().utf8), headerPriority: nil, defaults: SamplingDefaults())
        #expect(rc.params.maxTokens == 1 << 20)
        #expect((t.maxOutputTokens ?? Int.max) <= 1 << 20)
    }

    @Test func stopListIsBounded() throws {
        let many = (0..<40).map { "\"s\($0)\"" }.joined(separator: ",")
        #expect(throws: APIError.self) {
            try ChatRequest.parse(body(#""stop":[\#(many)]"#), headerPriority: nil, defaults: SamplingDefaults())
        }
        let long = String(repeating: "x", count: 5000)
        #expect(throws: APIError.self) {
            try ChatRequest.parse(body(#""stop":"\#(long)""#), headerPriority: nil, defaults: SamplingDefaults())
        }
    }

    @Test func backgroundClassOutputIsCapped() throws {
        let r = try ChatRequest.parse(body(#""ignore_eos":true,"max_tokens":9000000"#), headerPriority: "background",
                                      defaults: SamplingDefaults())
        #expect(r.params.ignoreEOS == true)   // honoured, but bounded by the background cap
        #expect(r.params.maxTokens == 32768)
        let i = try ChatRequest.parse(body(#""ignore_eos":true,"max_tokens":9000000"#), headerPriority: nil,
                                      defaults: SamplingDefaults())
        #expect(i.params.ignoreEOS == true)
    }

    @Test func healthDoesNotLeakTheUnhealthyReason() async throws {
        let engine = FakeEngine()
        engine.unhealthy = "model at /Users/x/secret-model failed"
        let server = StrimOpenAIServer(engine: engine, config: ServerConfig(modelId: "m", bearerToken: "tok"))
        let port = try await server.start(port: 0); defer { server.stop() }
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        #expect((resp as? HTTPURLResponse)?.statusCode == 503)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-model"))
    }
}

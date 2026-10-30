import Foundation
import Testing
import StrimEngine
import StrimTemplate
@testable import StrimServer

@Suite struct QwenPresetRequestTests {
    @Test func supportedEffortPreservationAndLargeOutputRenderWithoutModel() throws {
        for thinking in [true, false] {
            let root: [String: Any] = [
                "messages": [["role": "system", "content": "SYS"], ["role": "user", "content": "first"],
                             ["role": "assistant", "content": "answer", "reasoning_content": "prior-plan"], ["role": "user", "content": "next"]],
                "chat_template_kwargs": ["enable_thinking": thinking, "reasoning_effort": "xhigh", "preserve_thinking": true],
                "temperature": thinking ? 1.0 : 0.7, "top_p": thinking ? 0.95 : 0.8, "top_k": 20,
                "seed": 42, "max_tokens": 16_384
            ]
            let request = try ChatRequest.parse(JSONSerialization.data(withJSONObject: root), headerPriority: "background", defaults: SamplingDefaults())
            #expect(request.params.maxTokens == 16_384 && request.params.seed == 42 && request.params.topK == 20)
            #expect(request.params.temperature == (thinking ? 1 : 0.7) && request.params.topP == (thinking ? 0.95 : 0.8))
            let config = request.config
            let rendered = try ChatTemplate.renderSegments(messages: request.messages, enableThinking: config.enableThinking,
                                                           reasoningPolicy: config.reasoningPolicy, reasoningEffort: config.reasoningEffort,
                                                           preserveThinking: config.preserveThinking).map(\.text).joined()
            #expect(rendered.contains("prior-plan"))
            #expect(rendered.contains("Reasoning effort is set to xhigh") == thinking)
        }
    }

    @Test func outputCeilingClampsAndHighIsUnsupported() throws {
        var defaults = SamplingDefaults(); defaults.maxOutputTokens = 7000
        let request = try ChatRequest.parse(Data(#"{"messages":[{"role":"user","content":"hi"}],"max_tokens":16384}"#.utf8), headerPriority: nil, defaults: defaults)
        #expect(request.params.maxTokens == 7000)
        #expect(throws: (any Error).self) {
            try ChatTemplate.renderSegments(messages: [.user("hi")], enableThinking: true, reasoningEffort: "high")
        }
    }

    @Test func conservativeContextFitsHybridRequestReserve() {
        let long = MemoryModel.requestBytes(tokens: 65_536, mtp: true)
        let xlong = MemoryModel.requestBytes(tokens: 131_072, mtp: true)
        #expect(long == (4 << 30) + (256 << 20) + (147 << 20))
        #expect(long < MemoryModel.requestReserveBytes)
        #expect(xlong > MemoryModel.requestReserveBytes)
        // A 64 GiB host's default plan for the engine's 16 GiB reference weights accepts long but not xlong.
        let plan = MemoryModel.plan(physicalMemory: 64 << 30, weightFileBytes: 16 << 30)
        let fixed = MemoryModel.fixedBytes(weightFileBytes: 16 << 30, prefixBytes: plan.prefix, mlxCacheBytes: plan.mlxCache)
        #expect(Admission.decide(budget: plan.budget, fixed: fixed, active: 0, hot: [], needed: long).outcome == .admit)
        if case .reject = Admission.decide(budget: plan.budget, fixed: fixed, active: 0, hot: [], needed: xlong).outcome {} else {
            Issue.record("128K unexpectedly fits the reference default plan; revisit context clamp")
        }
    }
}

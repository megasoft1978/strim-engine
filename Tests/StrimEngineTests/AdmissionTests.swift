import Testing
@testable import StrimEngine

@Suite struct AdmissionTests {
    @Test func requestBytesMath() {
        let kv = 4096 * 64 * 1024
        #expect(MemoryModel.requestBytes(tokens: 4096, mtp: false) == kv + 147 * 1024 * 1024)
        #expect(MemoryModel.requestBytes(tokens: 4096, mtp: true) == kv + 4096 * 4096 + 147 * 1024 * 1024)
    }

    private let GB = 1 << 30

    @Test func fixedBytesFormula() {
        // 15538 MiB of safetensors (weights + MTP head) -> 0.95x resident, + trie + cache limit.
        let w = 15538 << 20
        #expect(MemoryModel.fixedBytes(weightFileBytes: w, prefixBytes: 12 * GB, mlxCacheBytes: 4 * GB)
                == Int(Double(w) * 0.95) + 16 * GB)
        // nil cache limit counts the 4 GiB default
        #expect(MemoryModel.fixedBytes(weightFileBytes: 0, prefixBytes: 0, mlxCacheBytes: nil) == 4 * GB)
        #expect(MemoryModel.workspaceBytes == 800 << 20)
    }

    @Test func defaultsFit64GBMachine() {
        let ram: UInt64 = 64 << 30
        let budget = MemoryModel.defaultBudgetBytes(physicalMemory: ram)
        #expect(budget == Int(Double(ram) * 0.50))
        let plan = MemoryModel.plan(physicalMemory: ram, weightFileBytes: 15538 << 20)
        #expect(plan.budget == budget)
        let fixed = MemoryModel.fixedBytes(weightFileBytes: 15538 << 20, prefixBytes: plan.prefix,
                                           mlxCacheBytes: plan.mlxCache)
        // 4-way cold 4K worst case: fixed + chunk transient + 4 requests.
        let four = 4 * MemoryModel.requestBytes(tokens: 4096, mtp: true)
        #expect(fixed + MemoryModel.workspaceBytes + four < 45 * GB)
        #expect(fixed + MemoryModel.workspaceBytes + four <= budget)
        let d = Admission.decide(budget: budget, fixed: fixed, active: 3 * MemoryModel.requestBytes(tokens: 4096, mtp: true),
                                 hot: [], needed: MemoryModel.requestBytes(tokens: 4096, mtp: true))
        #expect(d.outcome == .admit)
        // trie capacity: a 40K-token chain is 64 KiB/token KV plus the GDN state at every 4th block (stride 4)
        let chain40k = 40_000 * MemoryModel.kvBytesPerToken + (40_000 / 1024 / 4) * MemoryModel.gdnBytesPerSequence
        #expect(plan.prefix >= chain40k)
        #expect(plan.mlxCache >= 1 << 30 && plan.prefix + plan.mlxCache + Int(Double(15538 << 20) * 0.95) < budget)
    }

    @Test func admitsWhenItFits() {
        let d = Admission.decide(budget: 50 * GB, fixed: 20 * GB, active: 0, hot: [], needed: 1 * GB)
        #expect(d.outcome == .admit)
        #expect(d.evictHot.isEmpty)
    }

    @Test func rejectsInsteadOfOOM() {
        let d = Admission.decide(budget: 24 * GB, fixed: 20 * GB, active: 2 * GB, hot: [], needed: 4 * GB)
        guard case let .reject(needed, available) = d.outcome else { Issue.record("expected reject"); return }
        #expect(needed == 4 * GB)
        #expect(available < needed)
    }

    @Test func demotesOldestHotSessionsFirstUntilItFits() {
        let hot = [(id: UInt64(1), bytes: 3 * GB), (id: UInt64(2), bytes: 3 * GB), (id: UInt64(3), bytes: 3 * GB)]
        // used = 20 + 9 hot + 0.5 workspace = 29.5; +6 needed = 35.5 > 35: evicting #1 suffices
        let d = Admission.decide(budget: 35 * GB, fixed: 20 * GB, active: 0, hot: hot, needed: 6 * GB)
        #expect(d.outcome == .admit)
        #expect(d.evictHot == [1])
        let d2 = Admission.decide(budget: 30 * GB, fixed: 20 * GB, active: 0, hot: hot, needed: 6 * GB)
        #expect(d2.evictHot == [1, 2])
    }

    @Test func protectedHotSessionIsNeverEvicted() {
        let hot = [(id: UInt64(1), bytes: 8 * GB)]
        let d = Admission.decide(budget: 30 * GB, fixed: 20 * GB, active: 0, hot: hot, needed: 4 * GB, protect: 1)
        guard case .reject = d.outcome else { Issue.record("expected reject"); return }
        #expect(d.evictHot.isEmpty)
    }

    @Test func errorMessageIsClear() {
        let e = EngineError.insufficientMemory(needed: 5 << 30, available: 1 << 30)
        #expect("\(e)".contains("insufficient memory"))
        #expect("\(e)".contains("5120 MB"))
    }

    @Test func greedyIsTemperatureZero() {
        #expect(GenParams().isGreedy)
        #expect(!GenParams(temperature: 0.7).isGreedy)
    }
}

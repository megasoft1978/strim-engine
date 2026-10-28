import Foundation
import Testing
import StrimHarness
@testable import StrimJobs

/// F8: unfinished jobs are capped; finished ones free their place.
@Suite struct JobQueueLimitTests {
    @Test func submitIsRejectedOnceTheQueueIsFull() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        var ids: [String] = []
        for i in 0..<64 { ids.append(try await m.submit(spec("block-\(i)"))) }
        await #expect(throws: JobError.self) { _ = try await m.submit(spec("one-too-many")) }
        // Releasing the gate lets jobs finish; submit works again.
        ex.open()
        let first = ids[0]
        #expect(await waitFor(10) { await state(m, first) == .done })
        #expect(await waitFor(10) { (try? await m.submit(spec("instant"))) != nil })
    }
}

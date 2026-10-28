import Testing
@testable import StrimJobs

@Suite struct JobsSmokeTests {
    @Test func statesAndTerminality() {
        #expect(JobStatus.pausedInteractive.rawValue == "paused_interactive")
        #expect(JobStatus.awaitingApproval.rawValue == "awaiting_approval")
        #expect(JobStatus.running.isTerminal == false)
        for s in [JobStatus.done, .failed, .cancelled, .limit] { #expect(s.isTerminal) }
    }
}

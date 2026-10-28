import Testing
@testable import StrimAdmission

private func parsed(_ args: [String], next: [String] = []) throws -> AdmissionOptions {
    var o = AdmissionOptions()
    var rest = next
    for a in args { try o.parse(a, value: { rest.isEmpty ? "" : rest.removeFirst() }) }
    return o
}

/// The parse error for `args`, or nil when they parse.
private func failure(_ args: [String], next: [String] = []) -> AdmissionOptions.ParseError? {
    do { _ = try parsed(args, next: next); return nil } catch { return error as? AdmissionOptions.ParseError }
}

@Suite struct AdmissionOptionsTests {
    @Test func defaultsAreOnAndFollowTheServerConcurrency() {
        let o = AdmissionOptions()
        #expect(o.enabled && o.maxInflight == nil && o.maxBackground == nil)
        #expect(o.limits(defaultInflight: 8) == AdmissionLimits(maxInflight: 8, maxBackground: 7))
        #expect(o.limits(defaultInflight: 1) == AdmissionLimits(maxInflight: 1, maxBackground: 1))
        #expect(o.limits(defaultInflight: 0) == AdmissionLimits(maxInflight: 1, maxBackground: 1))
    }

    @Test func noAdmissionDisables() throws {
        let o = try parsed(["--no-admission"])
        #expect(!o.enabled)
        #expect(o.limits(defaultInflight: 8) == nil)
    }

    @Test func valuedFlagsAcceptSpaceAndEqualsForms() throws {
        let spaced = try parsed(["--max-inflight", "--max-background"], next: ["4", "2"])
        let joined = try parsed(["--max-inflight=4", "--max-background=2"])
        #expect(spaced == joined)
        #expect(joined.limits(defaultInflight: 8) == AdmissionLimits(maxInflight: 4, maxBackground: 2))
    }

    @Test func backgroundDefaultsBelowInflightAndIsClamped() throws {
        #expect(try parsed(["--max-inflight=4"]).limits(defaultInflight: 8) == AdmissionLimits(maxInflight: 4, maxBackground: 3))
        // Background above inflight - 1 is clamped, so an arriving interactive request always finds a slot.
        #expect(try parsed(["--max-inflight=4", "--max-background=9"]).limits(defaultInflight: 8)
                == AdmissionLimits(maxInflight: 4, maxBackground: 3))
    }

    @Test func badValuesAndUnknownFlagsThrow() {
        #expect(failure(["--max-inflight=0"]) == .badValue(flag: "--max-inflight", value: "0"))
        #expect(failure(["--max-inflight", "x"], next: ["x"]) == .badValue(flag: "--max-inflight", value: "x"))
        #expect(failure(["--max-background"]) == .badValue(flag: "--max-background", value: ""))
        #expect(failure(["--no-admission=1"]) == .unknown("--no-admission=1"))
        #expect(failure(["--max-inflight=4"]) == nil)
    }

    @Test func ownsOnlyAdmissionFlags() {
        for a in ["--no-admission", "--max-inflight", "--max-inflight=3", "--max-background", "--max-background=1"] {
            #expect(AdmissionOptions.owns(a), "\(a)")
        }
        for a in ["--port", "--max-inflightx", "--max-sessions", "--no-auth"] {
            #expect(!AdmissionOptions.owns(a), "\(a)")
        }
    }
}

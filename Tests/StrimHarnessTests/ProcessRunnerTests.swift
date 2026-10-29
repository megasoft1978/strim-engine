import Testing
import Foundation
@testable import StrimHarness

@Suite struct ProcessRunnerTests {
    @Test func hostMarkerCannotBeOverriddenByJobEnvironment() async throws {
        let base = NSTemporaryDirectory() + "strim-marker-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let runner = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [base], jobTmp: base + "/tmp"),
                                   sandboxed: false, hostID: "owner-a")
        let result = try await runner.run("printf '%s %s' \"$STRIM_HOST\" \"$STRIM_JOB\"", cwd: base,
                                          env: ["STRIM_HOST": "other", "STRIM_JOB": "forged"], timeout: 5, outputCap: 1024)
        #expect(result.exitCode == 0 && result.output.hasPrefix("owner-a ") && !result.output.contains("forged"))
    }
    private func makeRunner(sandboxed: Bool = true) throws -> (ProcessRunner, String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("strim-pr-\(UUID().uuidString)").path
        let work = base + "/work", tmp = base + "/tmp"
        for d in [work, tmp] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let r = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [work], jobTmp: tmp, home: base + "/home"),
                              killGrace: 0.5, sandboxed: sandboxed)
        return (r, work)
    }

    private func pgrepCount(_ marker: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", marker]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    private func settle(_ marker: String) async -> Int {
        for _ in 0..<20 { if pgrepCount(marker) == 0 { return 0 }; try? await Task.sleep(nanoseconds: 100_000_000) }
        return pgrepCount(marker)
    }

    private func survivorCmd(_ marker: String) -> String {
        "perl -e 'use POSIX; fork or do { setsid(); exec(\"sh\", \"-c\", \"sleep 25\", \"\(marker)\") }'; echo parent-done"
    }

    @Test(arguments: [false, true]) func setsidSurvivorKilledAndRunReturns(sandboxed: Bool) async throws {
        let (r, work) = try makeRunner(sandboxed: sandboxed)
        let marker = "strimmark\(UUID().uuidString.prefix(8))"
        let t0 = Date()
        let o = try await r.run(survivorCmd(marker), cwd: work, env: [:], timeout: 10, outputCap: 10_000)
        #expect(Date().timeIntervalSince(t0) < 8, "run must not wait for the survivor")
        #expect(o.output.contains("parent-done") && !o.timedOut)
        #expect(await settle(marker) == 0, "setsid survivor still alive")
    }

    @Test func timeoutKillsSetsidSurvivorPromptly() async throws {
        let (r, work) = try makeRunner()
        let marker = "strimmark\(UUID().uuidString.prefix(8))"
        let t0 = Date()
        let o = try await r.run("perl -e 'use POSIX; fork or do { setsid(); exec(\"sh\", \"-c\", \"sleep 25\", \"\(marker)\") }'; sleep 25",
                                cwd: work, env: [:], timeout: 1, outputCap: 10_000)
        #expect(o.timedOut)
        #expect(Date().timeIntervalSince(t0) < 1 + 3)
        #expect(await settle(marker) == 0)
    }

    @Test func cancellationKillsSetsidSurvivor() async throws {
        let (r, work) = try makeRunner()
        let marker = "strimmark\(UUID().uuidString.prefix(8))"
        let task = Task {
            try await r.run("perl -e 'use POSIX; fork or do { setsid(); exec(\"sh\", \"-c\", \"sleep 25\", \"\(marker)\") }'; sleep 25",
                            cwd: work, env: [:], timeout: 30, outputCap: 10_000)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let t0 = Date()
        task.cancel()
        _ = try await task.value
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(await settle(marker) == 0)
    }

    @Test func outputCapKeepsHeadAndTail() async throws {
        let (r, work) = try makeRunner(sandboxed: false)
        let o = try await r.run("seq 1 200000", cwd: work, env: [:], timeout: 20, outputCap: 1000)
        #expect(o.truncated)
        #expect(o.output.hasPrefix("1\n2\n"))
        #expect(o.output.hasSuffix("200000\n"))
        #expect(o.output.utf8.count < 1200)
    }

    @Test func childGetsSigtermEvenIfParentIgnoresIt() async throws {
        let (r0, work) = try makeRunner(sandboxed: false)
        var r = r0; r.killGrace = 15
        let old = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, old) }
        let t0 = Date()
        let o = try await r.run("sleep 30", cwd: work, env: [:], timeout: 1, outputCap: 1000)
        #expect(o.timedOut && o.exitCode == 143, "exit \(o.exitCode)")
        #expect(Date().timeIntervalSince(t0) < 5, "SIGTERM was ignored by the child")
    }

    // Second review H1: survivors that leave the group, drop the env marker and orphan themselves.
    private func survivorScript(_ kind: String, _ marker: String) -> String {
        let ex = "%ENV=(); open STDOUT,\">/dev/null\"; open STDERR,\">/dev/null\"; exec {\"/bin/sh\"} \"sh\",\"-c\",\"sleep 25; true\",\"\(marker)\""
        switch kind {
        case "direct": return "perl -e 'fork or do { \(ex) }'; echo done"
        case "double": return "perl -e 'use POSIX; fork or do { fork and exit 0; setsid(); \(ex) }'; echo done"
        default: return "perl -e 'use POSIX; fork or do { setsid(); \(ex) }'; echo done"  // emptyEnvSetsid
        }
    }

    @Test(arguments: ["direct", "double", "emptyEnvSetsid"]) func envlessSurvivorsKilled(kind: String) async throws {
        let (r, work) = try makeRunner()
        let marker = "strimmark\(UUID().uuidString.prefix(8))"
        let t0 = Date()
        let o = try await r.run(survivorScript(kind, marker), cwd: work, env: [:], timeout: 10, outputCap: 10_000)
        #expect(o.output.contains("done") && !o.timedOut, "\(o.output)")
        #expect(Date().timeIntervalSince(t0) < 8)
        #expect(await settle(marker) == 0, "\(kind) survivor still alive")
        _ = Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-f", marker])
    }

    @Test func envlessSurvivorKilledOnTimeoutAndCancel() async throws {
        let (r, work) = try makeRunner()
        let m1 = "strimmark\(UUID().uuidString.prefix(8))", m2 = "strimmark\(UUID().uuidString.prefix(8))"
        let o = try await r.run(survivorScript("emptyEnvSetsid", m1) + "; sleep 25", cwd: work, env: [:], timeout: 1, outputCap: 1000)
        #expect(o.timedOut)
        #expect(await settle(m1) == 0)
        let task = Task { try await r.run(survivorScript("emptyEnvSetsid", m2) + "; sleep 25", cwd: work, env: [:], timeout: 30, outputCap: 1000) }
        try await Task.sleep(nanoseconds: 800_000_000)
        task.cancel()
        _ = try await task.value
        #expect(await settle(m2) == 0)
    }

    // Second review M3: resource limits.
    @Test func ulimitsApplyAndCannotBeRaised() async throws {
        let (r, work) = try makeRunner()
        let o = try await r.run("ulimit -f; ulimit -u unlimited 2>/dev/null; echo raise=$?; ulimit -f unlimited 2>/dev/null; echo raisef=$?; ulimit -u",
                                cwd: work, env: [:], timeout: 20, outputCap: 10_000)
        let lines = o.output.split(separator: "\n").map(String.init)
        #expect(lines.first == "524288", "\(o.output)")
        #expect(lines.contains { $0.hasPrefix("raise=") && $0 != "raise=0" }, "\(o.output)")
        #expect(lines.contains { $0.hasPrefix("raisef=") && $0 != "raisef=0" }, "\(o.output)")
        #expect((Int(lines.last ?? "") ?? Int.max) < 100_000, "\(o.output)")
    }

    @Test func fileSizeLimitStopsBigWrites() async throws {
        var (r, work) = try makeRunner()
        r.maxFileSizeKB = 1024
        let o = try await r.run("dd if=/dev/zero of=big bs=1048576 count=5 2>&1; ls -l big | awk '{print \"size=\" $5}'",
                                cwd: work, env: [:], timeout: 20, outputCap: 10_000)
        #expect(o.output.contains("size=1048576"), "\(o.output)")
    }

    @Test func forkBombIsCappedAndCleanedUp() async throws {
        var (r, work) = try makeRunner()
        r.processMargin = 48
        let marker = "strimmark\(UUID().uuidString.prefix(8))"
        let t0 = Date()
        let o = try await r.run("for i in $(seq 1 400); do sh -c 'sleep 60; true' \(marker) & done 2>&1; echo spawned",
                                cwd: work, env: [:], timeout: 6, outputCap: 20_000)
        #expect(o.output.contains("Resource temporarily unavailable") || o.timedOut, "\(o.output.prefix(300))")
        #expect(Date().timeIntervalSince(t0) < 14)
        #expect(await settle(marker) == 0)
    }
}

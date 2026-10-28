import Foundation
import Testing
import StrimHarness
@testable import StrimJobs

// MARK: - helpers

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

/// Fake executor. Behaviour is chosen by `spec.task`:
/// "instant" returns done, "block" waits for `open()` (or cancellation), "emit" emits events then blocks,
/// "oom" fails with insufficient_memory `oomFailures` times then succeeds, "oom-always" always fails.
final class FakeExec: @unchecked Sendable {
    let started = Box<[String]>([])
    let running = Box(0)
    let maxRunning = Box(0)
    let calls = Box(0)
    let gateOpen = Box(false)
    let cancelled = Box<[String]>([])
    let oomFailures = Box(2)

    func open() { gateOpen.value = true }

    var executor: JobExecutor {
        { [self] spec, id, onEvent in
            started.mutate { $0.append(spec.task) }
            calls.mutate { $0 += 1 }
            running.mutate { $0 += 1 }
            maxRunning.mutate { $0 = max($0, running.value) }
            defer { running.mutate { $0 -= 1 } }
            switch spec.task {
            case "instant":
                return HarnessJobResult(status: .done, summary: "ok \(spec.task)")
            case "oom", "oom-always":
                let n = calls.value
                if spec.task == "oom-always" || n <= oomFailures.value {
                    return HarnessJobResult(status: .failed, summary: "insufficient_memory: no room")
                }
                return HarnessJobResult(status: .done, summary: "ok after retry")
            case "emit":
                onEvent(.turn(1))
                onEvent(.toolCall(name: "read_file", args: "{\"path\":\"a.swift\"}"))
                onEvent(.toolResult(name: "read_file", output: "contents", isError: false))
                onEvent(.textDelta("ignored"))
                onEvent(.turn(2))
                for i in 0..<6 { onEvent(.toolCall(name: "bash", args: "echo \(i)")) }
                onEvent(.finished(.done))
            default: break
            }
            while !gateOpen.value {
                if Task.isCancelled { cancelled.mutate { $0.append(spec.task) }; return HarnessJobResult(status: .cancelled, summary: "stopped") }
                try? await Task.sleep(for: .milliseconds(3))
            }
            return HarnessJobResult(status: .done, summary: "ok \(spec.task)")
        }
    }
}

func spec(_ task: String, maxSeconds: Double = 900) -> HarnessJobSpec {
    var l = HarnessLimits(); l.maxSeconds = maxSeconds
    return HarnessJobSpec(task: task, cwd: "/tmp/proj", limits: l)
}

func waitFor(_ timeout: Double = 3, _ cond: @Sendable () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await cond()
}

func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("strim-jobs-test-\(UUID().uuidString)")
    return u
}

func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
}

func fastManager(_ ex: FakeExec, store: JobStore = InMemoryJobStore(), maxConcurrent: Int = 1,
                 requireApproval: Bool = false, busy: Box<Bool>? = nil,
                 retentionAge: TimeInterval = 7 * 86400, retentionCount: Int = 50,
                 now: @escaping @Sendable () -> Date = { Date() }) -> JobManager {
    JobManager(executor: ex.executor, store: store, maxConcurrent: maxConcurrent, requireApproval: requireApproval,
               interactiveBusy: { busy?.value ?? false }, pollInterval: .milliseconds(10),
               admissionRetryDelay: .milliseconds(20), retentionAge: retentionAge, retentionCount: retentionCount, now: now)
}

func state(_ m: JobManager, _ id: String) async -> JobStatus? { try? await m.status(id, waitS: 0).status }

// MARK: - tests

@Suite struct JobManagerTests {
    @Test func idFormat() async throws {
        let m = fastManager(FakeExec())
        let id = try await m.submit(spec("instant"))
        #expect(isValidJobID(id))
        let ids = Set((0..<200).map { _ in JobManager.newID() })
        #expect(ids.count == 200)
    }

    @Test func submitLatency() async throws {
        let ex = FakeExec()
        let m = fastManager(ex, store: FileJobStore(root: tmpDir()))
        let t0 = Date()
        _ = try await m.submit(spec("block"))
        #expect(Date().timeIntervalSince(t0) < 0.05)
        ex.open()
    }

    @Test func stateTransitionsAndProgress() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("emit"))
        #expect(await waitFor { await state(m, id) == .finalizing })
        let s = try await m.status(id, waitS: 0)
        #expect(s.progress.turn == 2)
        #expect(s.progress.maxTurns == 40)
        #expect(s.progress.lastSteps.count == 5)
        #expect(s.progress.lastSteps.last == "bash echo 5")
        #expect(s.result == nil)
        ex.open()
        let done = try await m.status(id, waitS: 5)
        #expect(done.status == .done)
        #expect(done.result?.summary == "ok emit")
        let ev = try await m.eventsSince(id, index: 0)
        #expect(ev.map(\.kind).first == "turn")
        #expect(ev.last?.kind == "finished")
        #expect(ev.map(\.index) == Array(0..<ev.count))
        let tail = try await m.eventsSince(id, index: ev.count - 1)
        #expect(tail.count == 1)
    }

    @Test func queuedThenPreparingThenRunning() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let a = try await m.submit(spec("block"))
        let b = try await m.submit(spec("block-2"))
        #expect(await waitFor { await state(m, a) == .running })
        #expect(await state(m, b) == .queued)
        ex.open()
        #expect(try await m.status(b, waitS: 5).status == .done)
    }

    @Test func fifoAndSingleSlot() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        var ids: [String] = []
        for i in 0..<4 { ids.append(try await m.submit(spec("job\(i)"))) }
        ex.open()
        for id in ids { #expect(try await m.status(id, waitS: 5).status == .done) }
        #expect(ex.started.value == ["job0", "job1", "job2", "job3"])
        #expect(ex.maxRunning.value == 1)
    }

    @Test func maxConcurrentTwo() async throws {
        let ex = FakeExec()
        let m = fastManager(ex, maxConcurrent: 2)
        for i in 0..<4 { _ = try await m.submit(spec("job\(i)")) }
        #expect(await waitFor { ex.running.value == 2 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(ex.maxRunning.value == 2)
        ex.open()
    }

    @Test func quickJumpsQueue() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let first = try await m.submit(spec("first"))
        #expect(await waitFor { await state(m, first) == .running })
        _ = try await m.submit(spec("n1"))
        let n2 = try await m.submit(spec("n2"))
        let q1 = try await m.submit(spec("q1"), priority: .quick)
        let q2 = try await m.submit(spec("q2"), priority: .quick)
        ex.open()
        #expect(try await m.status(n2, waitS: 5).status == .done)
        #expect(try await m.status(q1, waitS: 0).status == .done)
        #expect(try await m.status(q2, waitS: 0).status == .done)
        #expect(ex.started.value == ["first", "q1", "q2", "n1", "n2"])
    }

    @Test func longPollReturnsEarlyOnCompletion() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("block"))
        Task { try? await Task.sleep(for: .milliseconds(100)); ex.open() }
        let t0 = Date()
        let s = try await m.status(id, waitS: 10)
        #expect(s.status == .done)
        #expect(Date().timeIntervalSince(t0) < 3)
    }

    @Test func longPollTimesOutWhenNotDone() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("block"))
        let t0 = Date()
        let s = try await m.status(id, waitS: 0.15)
        let dt = Date().timeIntervalSince(t0)
        #expect(!s.status.isTerminal)
        #expect(dt >= 0.14 && dt < 2)
        ex.open()
    }

    @Test func unknownJobThrows() async throws {
        let m = fastManager(FakeExec())
        await #expect(throws: JobError.notFound("j_zzzzzzzzzz")) { try await m.status("j_zzzzzzzzzz", waitS: 0) }
        await #expect(throws: JobError.notFound("x")) { try await m.cancel("x") }
    }

    @Test func cancelQueued() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let a = try await m.submit(spec("block"))
        let b = try await m.submit(spec("never"))
        #expect(await waitFor { await state(m, a) == .running })
        let s = try await m.cancel(b)
        #expect(s.status == .cancelled)
        #expect(s.result?.status == .cancelled)
        ex.open()
        #expect(try await m.status(a, waitS: 5).status == .done)
        #expect(!ex.started.value.contains("never"))
    }

    @Test func cancelRunningAndIdempotent() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let a = try await m.submit(spec("block"))
        let b = try await m.submit(spec("next"))
        #expect(await waitFor { await state(m, a) == .running })
        let s1 = try await m.cancel(a)
        #expect(s1.status == .cancelled)
        let s2 = try await m.cancel(a)
        #expect(s2.status == .cancelled)
        #expect(await waitFor { ex.cancelled.value == ["block"] })
        ex.open()
        // slot is freed after the cancelled executor returns, next job runs
        #expect(try await m.status(b, waitS: 5).status == .done)
        #expect(try await m.status(a, waitS: 0).status == .cancelled)
    }

    @Test func cancelTerminalIsNoOp() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("instant"))
        #expect(try await m.status(id, waitS: 5).status == .done)
        let s = try await m.cancel(id)
        #expect(s.status == .done)
        #expect(s.result?.summary == "ok instant")
    }

    @Test func pauseResumeAccounting() async throws {
        let ex = FakeExec()
        let busy = Box(false)
        let m = fastManager(ex, busy: busy)
        let id = try await m.submit(spec("block"))
        #expect(await waitFor { await state(m, id) == .running })
        busy.value = true
        #expect(await waitFor { await state(m, id) == .pausedInteractive })
        try? await Task.sleep(for: .milliseconds(150))
        let mid = try await m.status(id, waitS: 0)
        #expect(mid.progress.pausedS >= 0.1)
        busy.value = false
        #expect(await waitFor { await state(m, id) == .running })
        ex.open()
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .done)
        #expect(s.progress.pausedS >= 0.14)
        #expect(s.progress.elapsedS >= s.progress.pausedS)
    }

    @Test func pausedTimeExcludedFromWallClockLimit() async throws {
        let ex = FakeExec()
        let busy = Box(false)
        let m = fastManager(ex, busy: busy)
        let id = try await m.submit(spec("block", maxSeconds: 0.5))
        #expect(await waitFor { await state(m, id) == .running })
        busy.value = true
        #expect(await waitFor { await state(m, id) == .pausedInteractive })
        try? await Task.sleep(for: .milliseconds(900))   // longer than the limit, all paused
        #expect(await state(m, id) == .pausedInteractive)
        busy.value = false
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .limit)
        #expect(s.result?.status == .limit)
        #expect(s.progress.pausedS >= 0.8)
        #expect(await waitFor { ex.cancelled.value == ["block"] })
    }

    @Test func restartRecoveryMarksFailedHostRestart() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileJobStore(root: dir)
        let ex1 = FakeExec()
        let m1 = fastManager(ex1, store: store)
        let running = try await m1.submit(spec("block"))
        let queued = try await m1.submit(spec("later"))
        let ex0 = FakeExec()
        let m0 = fastManager(ex0, store: store)
        let done = try await m0.submit(spec("instant"))
        _ = try await m0.status(done, waitS: 5)
        await m0.flush()
        #expect(await waitFor { await state(m1, running) == .running })
        await m1.flush()
        try await Task.sleep(for: .milliseconds(100))

        let m2 = fastManager(FakeExec(), store: store)
        await m2.recover()
        for id in [running, queued] {
            let s = try await m2.status(id, waitS: 0)
            #expect(s.status == .failed)
            #expect(s.reason == "host_restart")
            #expect(s.result?.status == .failed)
        }
        #expect(try await m2.status(done, waitS: 0).status == .done)
        let persisted = try await store.load(running)
        #expect(persisted?.status == .failed)
        ex1.open()
    }

    @Test func recoveryKeepsTerminalJobsQueryable() async throws {
        let store = InMemoryJobStore()
        let m1 = fastManager(FakeExec(), store: store)
        let id = try await m1.submit(spec("instant"))
        _ = try await m1.status(id, waitS: 5)
        await m1.flush()
        let m2 = fastManager(FakeExec(), store: store)
        await m2.recover()
        let s = try await m2.status(id, waitS: 0)
        #expect(s.status == .done)
        #expect(s.result?.summary == "ok instant")
        #expect(s.spec.task == "instant")
    }

    @Test func retentionByCount() async throws {
        let store = InMemoryJobStore()
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        let m = fastManager(FakeExec(), store: store, retentionCount: 3, now: { clock.value })
        var ids: [String] = []
        for _ in 0..<5 {
            let id = try await m.submit(spec("instant"))
            _ = try await m.status(id, waitS: 5)
            ids.append(id)
            clock.mutate { $0 = $0.addingTimeInterval(10) }
        }
        await m.flush()
        let left = Set(try await store.list().map(\.id))
        #expect(left == Set(ids.suffix(3)))
        await #expect(throws: JobError.self) { try await m.status(ids[0], waitS: 0) }
    }

    @Test func retentionByAge() async throws {
        let store = InMemoryJobStore()
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        let m = fastManager(FakeExec(), store: store, now: { clock.value })
        let old = try await m.submit(spec("instant"))
        _ = try await m.status(old, waitS: 5)
        clock.mutate { $0 = $0.addingTimeInterval(8 * 86400) }
        let fresh = try await m.submit(spec("instant"))
        _ = try await m.status(fresh, waitS: 5)
        await m.flush()
        let left = Set(try await store.list().map(\.id))
        #expect(left == [fresh])
    }

    @Test func persistenceFileModesAndRedaction() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Redactor.register(secret: "tok-SuperSecretValue-98765")
        let ex = FakeExec()
        let m = fastManager(ex, store: FileJobStore(root: dir))
        var sp = spec("emit")
        sp.context = "use token tok-SuperSecretValue-98765 please"
        let id = try await m.submit(sp)
        #expect(await waitFor { await state(m, id) == .finalizing })
        ex.open()
        _ = try await m.status(id, waitS: 5)
        await m.flush()
        let jobDir = dir.appendingPathComponent(id)
        #expect(mode(dir) == 0o700)
        #expect(mode(jobDir) == 0o700)
        #expect(mode(jobDir.appendingPathComponent("job.json")) == 0o600)
        #expect(mode(jobDir.appendingPathComponent("events.jsonl")) == 0o600)
        let json = try String(contentsOf: jobDir.appendingPathComponent("job.json"), encoding: .utf8)
        #expect(!json.contains("SuperSecretValue"))
        #expect(json.contains("\"done\""))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: jobDir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
        let store = FileJobStore(root: dir)
        let events = try await store.events(id)
        #expect(events.count == (try await m.eventsSince(id, index: 0)).count)
        #expect(events.last?.kind == "finished")
    }

    @Test func verifyAndDeclinedArePersistedAndRedacted() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "ghp_" + "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0FeDcBa"
        let verifyCmd = "swift test --filter X"
        let store = FileJobStore(root: dir)
        let vr = VerifyResult(status: .failed, exitCode: 2, outputTail: "boom \(secret)", touchedSensitive: ["tests/a.py"])
        let declined = Box(false)
        let m = JobManager(executor: { sp, _, _ in
            if declined.value { return HarnessJobResult(status: .declined, summary: "too vague") }
            return HarnessJobResult(status: .done, summary: "ok", verify: vr)
        }, store: store, pollInterval: .milliseconds(5))
        var sp = spec("v")
        sp.verify = verifyCmd
        let id = try await m.submit(sp)
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .done && s.spec.verify == verifyCmd)
        #expect(s.result?.verify.status == .failed && s.result?.verify.exitCode == 2)
        #expect(s.result?.verify.outputTail.contains(secret) == false)
        await m.flush()
        let rec = try #require(try await store.load(id))
        #expect(rec.verify == verifyCmd && rec.result?.verify?.status == .failed && rec.result?.verify?.exitCode == 2)
        #expect(rec.result?.verify?.touchedSensitive == ["tests/a.py"])
        let json = try String(contentsOf: dir.appendingPathComponent(id).appendingPathComponent("job.json"), encoding: .utf8)
        #expect(!json.contains(secret) && json.contains("\"verify\""))

        declined.value = true
        let id2 = try await m.submit(spec("d"))
        let s2 = try await m.status(id2, waitS: 5)
        #expect(s2.status == .declined && s2.status.isTerminal && s2.result?.status == .declined)
        #expect(s2.result?.verify == .unverified)
        await m.flush()
        #expect(try await store.load(id2)?.status == .declined)
    }

    @Test func oldRecordsWithoutVerifyStillDecode() throws {
        let json = #"{"status":"done","summary":"s","filesChanged":[],"commands":[],"usage":{"promptTokens":0,"cachedTokens":0,"completionTokens":0,"turns":0,"seconds":0}}"#
        let r = try JSONDecoder().decode(JobRecordResult.self, from: Data(json.utf8))
        #expect(r.verify == nil)
    }

    @Test func fileStoreRejectsBadIDs() async throws {
        let store = FileJobStore(root: tmpDir())
        await #expect(throws: (any Error).self) { _ = try await store.load("../etc") }
        await #expect(throws: (any Error).self) { try await store.remove("j_../../x") }
    }

    @Test func approvalApprove() async throws {
        let ex = FakeExec()
        let m = fastManager(ex, requireApproval: true)
        let id = try await m.submit(spec("instant"))
        #expect(await waitFor { await state(m, id) == .awaitingApproval })
        #expect(ex.calls.value == 0)
        try await m.approve(id)
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .done)
        await #expect(throws: JobError.notAwaitingApproval(id)) { try await m.approve(id) }
    }

    @Test func approvalReject() async throws {
        let ex = FakeExec()
        let m = fastManager(ex, requireApproval: true)
        let id = try await m.submit(spec("instant"))
        let next = try await m.submit(spec("instant"))
        #expect(await waitFor { await state(m, id) == .awaitingApproval })
        try await m.reject(id)
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .cancelled)
        #expect(s.result?.summary == "rejected")
        #expect(ex.calls.value == 0)
        // slot is released, next job reaches approval
        #expect(await waitFor { await state(m, next) == .awaitingApproval })
        try await m.reject(next)
    }

    @Test func cancelWhileAwaitingApproval() async throws {
        let m = fastManager(FakeExec(), requireApproval: true)
        let id = try await m.submit(spec("instant"))
        #expect(await waitFor { await state(m, id) == .awaitingApproval })
        #expect(try await m.cancel(id).status == .cancelled)
        await #expect(throws: JobError.notAwaitingApproval(id)) { try await m.reject(id) }
    }

    @Test func longPollWakesWhenAwaitingApproval() async throws {
        let m = fastManager(FakeExec(), requireApproval: true)
        let id = try await m.submit(spec("instant"))
        let s = try await m.status(id, waitS: 0)
        _ = s
        #expect(await waitFor { await state(m, id) == .awaitingApproval })
        try await m.approve(id)
    }

    @Test func admissionRetrySucceeds() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("oom"))
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .done)
        #expect(ex.calls.value == 3)
    }

    @Test func admissionRetryExhausted() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("oom-always"))
        let s = try await m.status(id, waitS: 5)
        #expect(s.status == .failed)
        #expect(s.reason == "insufficient_memory")
        #expect(ex.calls.value == 4)   // first try + 3 retries
    }

    @Test func cancelDuringAdmissionWait() async throws {
        let ex = FakeExec()
        let m = JobManager(executor: ex.executor, admissionRetryDelay: .seconds(30))
        let id = try await m.submit(spec("oom-always"))
        #expect(await waitFor { ex.calls.value == 1 })
        #expect(try await m.cancel(id).status == .cancelled)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ex.calls.value == 1)
    }

    @Test func manyConcurrentPollersResumeOnce() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("block"))
        let results = Box<[JobStatus]>([])
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<60 {
                g.addTask {
                    // mix of long waits and waits that expire around completion time
                    let w = i % 3 == 0 ? 0.05 : 10
                    if let s = try? await m.status(id, waitS: w) { results.mutate { $0.append(s.status) } }
                }
            }
            g.addTask { try? await Task.sleep(for: .milliseconds(80)); ex.open() }
            await g.waitForAll()
        }
        #expect(results.value.count == 60)
        #expect(results.value.filter { $0 == .done }.count >= 40)
        // a late poll after completion returns immediately
        let t0 = Date()
        #expect(try await m.status(id, waitS: 10).status == .done)
        #expect(Date().timeIntervalSince(t0) < 1)
    }

    @Test func cancelledPollerReturnsEarly() async throws {
        let ex = FakeExec()
        let m = fastManager(ex)
        let id = try await m.submit(spec("block"))
        let t0 = Date()
        let poll = Task { try await m.status(id, waitS: 20) }
        try? await Task.sleep(for: .milliseconds(50))
        poll.cancel()
        let s = try await poll.value
        #expect(!s.status.isTerminal)
        #expect(Date().timeIntervalSince(t0) < 2)
        ex.open()
    }

    @Test func secretStraddlingClipBoundaryNeverLeaks() async throws {
        let secret = "ghp_" + String((0..<36).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
        Redactor.register(secret: secret)
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func leaks(_ text: String) -> Bool {
            let chars = Array(secret)
            for start in 0...(chars.count - 6) where text.contains(String(chars[start..<(start + 6)])) { return true }
            return false
        }
        // Place the secret so that it straddles the 60 (lastSteps) and 300 (events) boundaries.
        let cmds = [20, 40, 50, 55, 270, 290, 296].map { pad in
            String(repeating: "x", count: pad) + secret
        }
        let executor: JobExecutor = { _, _, onEvent in
            for c in cmds {
                onEvent(.toolCall(name: "bash", args: c))
                onEvent(.toolResult(name: "bash", output: c, isError: false))
            }
            onEvent(.finished(.done))
            return HarnessJobResult(status: .done, summary: "see \(secret) end",
                                    commands: [CommandRecord(cmd: "echo \(secret)", exit: 0)])
        }
        let m = JobManager(executor: executor, store: FileJobStore(root: dir), pollInterval: .milliseconds(10))
        let id = try await m.submit(spec("x"))
        let snap = try await m.status(id, waitS: 5)
        await m.flush()
        #expect(snap.status == .done)
        #expect(snap.progress.lastSteps.count == 5)
        for s in snap.progress.lastSteps { #expect(!leaks(s)) }
        #expect(!leaks(snap.result?.summary ?? ""))
        #expect(!leaks(snap.result?.commands.first?.cmd ?? ""))
        let events = try await m.eventsSince(id, index: 0)
        #expect(events.count > 10)
        for e in events { #expect(!leaks(e.text)) }
        let jobDir = dir.appendingPathComponent(id)
        for f in ["job.json", "events.jsonl"] {
            #expect(!leaks(try String(contentsOf: jobDir.appendingPathComponent(f), encoding: .utf8)))
        }
    }
}

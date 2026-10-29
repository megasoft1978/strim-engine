import XCTest
import StrimAPI
@testable import StrimAppCore

final class FakeProcessTable: HostProcessTable, @unchecked Sendable {
    struct S { var alive: Set<Int32> = []; var ignoresTerm: Set<Int32> = []; var ignoresKill: Set<Int32> = []
        var exe: [Int32: String] = [:]; var exeAfterTerm: [Int32: String?] = [:]; var lock: Int32?; var termed: [Int32] = [], killed: [Int32] = [] }
    let s = Locked(S())
    func isAlive(_ pid: Int32) -> Bool { s.with { $0.alive.contains(pid) } }
    func terminate(_ pid: Int32) { s.with { $0.termed.append(pid); if let e = $0.exeAfterTerm[pid] { $0.exe[pid] = e }; if !$0.ignoresTerm.contains(pid) { $0.alive.remove(pid) } } }
    func kill(_ pid: Int32) { s.with { $0.killed.append(pid); if !$0.ignoresKill.contains(pid) { $0.alive.remove(pid) } } }
    func executablePath(of pid: Int32) -> String? { s.with { $0.exe[pid] } }
    func lockOwner() -> Int32? { s.with { $0.lock } }
}

final class FakeStore: OwnedHostStore, @unchecked Sendable {
    let rec = Locked<OwnedHostRecord?>(nil)
    func load() -> OwnedHostRecord? { rec.value }
    func save(_ r: OwnedHostRecord) { rec.with { $0 = r } }
    func clear() { rec.with { $0 = nil } }
}

@MainActor
final class FakeTarget: LifecycleTarget {
    var ownedHostPID: Int32? { didSet { if ownedHostPID != oldValue { onOwnedHostChange?(ownedHostPID) } } }
    var onOwnedHostChange: ((Int32?) -> Void)?
    var prepared = 0, reconnects = 0, launches = 0
    var hangPrepare = false
    func prepareForQuit() async -> Int32? {
        prepared += 1
        if hangPrepare { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        return ownedHostPID
    }
    func hostExited(_ pid: Int32) { if ownedHostPID == pid { ownedHostPID = nil } }
    func adoptRunningHost(_ pid: Int32) { ownedHostPID = pid }
    func reconnectNow() { reconnects += 1 }
}

@MainActor
final class QuitLifecycleTests: XCTestCase {
    let bin = "/opt/strim/bin/strim"
    var table = FakeProcessTable(), store = FakeStore(), target = FakeTarget()
    var keep = false

    override func setUp() { table = FakeProcessTable(); store = FakeStore(); target = FakeTarget(); keep = false }

    func coordinator(_ t: LifecycleTiming? = nil) -> LifecycleCoordinator {
        var timing = LifecycleTiming(); timing.total = 0.5; timing.prepareCap = 0.05; timing.termWait = 0.15; timing.killWait = 0.05; timing.poll = 0.01
        return LifecycleCoordinator(target: target, table: table, store: store, expectedBinary: { self.bin },
                                    keepServerOnQuit: { self.keep }, timing: t ?? timing)
    }

    func testQuitStopsOwnedServerWithSigtermOnly() async {
        table.s.with { $0.alive = [500]; $0.exe[500] = bin }; target.ownedHostPID = 500
        await coordinator().runQuit()
        XCTAssertEqual(table.s.value.termed, [500]); XCTAssertEqual(table.s.value.killed, [])
        XCTAssertNil(target.ownedHostPID); XCTAssertNil(store.rec.value, "record cleared after a clean stop")
        XCTAssertEqual(target.prepared, 1)
    }

    func testForeignServerIsNeverSignalled() async {
        table.s.with { $0.alive = [777] }       // reachable server started by the CLI: no ownedHostPID
        await coordinator().runQuit()
        XCTAssertEqual(table.s.value.termed, []); XCTAssertEqual(table.s.value.killed, []); XCTAssertTrue(table.isAlive(777))
        XCTAssertEqual(target.prepared, 1, "sessions still close")
    }

    func testHangEscalatesToSigkillOnOwnedPidOnly() async {
        table.s.with { $0.alive = [500, 777]; $0.ignoresTerm = [500]; $0.exe[500] = bin }; target.ownedHostPID = 500
        await coordinator().runQuit()
        XCTAssertEqual(table.s.value.termed, [500]); XCTAssertEqual(table.s.value.killed, [500])
        XCTAssertFalse(table.isAlive(500)); XCTAssertTrue(table.isAlive(777))
    }

    func testKeepServerSkipsSignalsAndKeepsRecord() async {
        let c = coordinator(); table.s.with { $0.alive = [500]; $0.exe[500] = bin }; target.ownedHostPID = 500
        keep = true
        await c.runQuit()
        XCTAssertEqual(table.s.value.termed, []); XCTAssertEqual(table.s.value.killed, [])
        XCTAssertEqual(store.rec.value, OwnedHostRecord(pid: 500, binaryPath: bin), "next launch can adopt it")
    }

    func testTotalTimeBoundedWhenHostAndPrepareHang() async {
        table.s.with { $0.alive = [500]; $0.ignoresTerm = [500]; $0.ignoresKill = [500]; $0.exe[500] = bin }
        target.ownedHostPID = 500; target.hangPrepare = true
        var t = LifecycleTiming(); t.total = 0.3; t.prepareCap = 0.05; t.termWait = 5; t.killWait = 5; t.poll = 0.01
        let start = Date()
        await coordinator(t).runQuit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        XCTAssertEqual(table.s.value.termed, [500], "stop signal not delayed by the hung prepare")
        XCTAssertGreaterThanOrEqual(table.s.value.killed.count, 1, "hard bound still SIGKILLs the owned pid")
    }

    func testDefaultTimingMatchesBudget() {
        let t = LifecycleTiming()
        XCTAssertEqual(t.total, 4); XCTAssertEqual(t.termWait, 3)
        XCTAssertLessThanOrEqual(t.prepareCap + t.termWait + t.killWait, t.total)
    }

    func testSecondQuitTerminatesImmediately() async {
        table.s.with { $0.alive = [500]; $0.ignoresTerm = [500]; $0.ignoresKill = [500]; $0.exe[500] = bin }; target.ownedHostPID = 500
        let c = coordinator()
        let replied = Locked(0)
        XCTAssertEqual(c.requestQuit { replied.with { $0 += 1 } }, .later)
        XCTAssertEqual(c.requestQuit { replied.with { $0 += 1 } }, .now)
        XCTAssertEqual(c.requestQuit { }, .now)
        let ok = await waitFor { replied.value == 1 }
        XCTAssertTrue(ok); XCTAssertEqual(target.prepared, 1, "shutdown ran once")
    }

    func testWakeReconnectsWithoutLaunching() {
        let c = coordinator()
        c.systemDidWake(); c.systemDidWake()
        XCTAssertEqual(target.reconnects, 2); XCTAssertEqual(target.launches, 0)
        XCTAssertEqual(table.s.value.termed, [])
    }

    func testWakeDuringQuitIsIgnored() async {
        let c = coordinator(); await c.runQuit(); c.systemDidWake()
        XCTAssertEqual(target.reconnects, 0)
    }

    // MARK: pid reuse / late launch

    func testForeignExecutableIsNeverSignalled() async {
        table.s.with { $0.alive = [500]; $0.exe[500] = "/usr/bin/other" }; target.ownedHostPID = 500
        await coordinator().runQuit()
        XCTAssertEqual(table.s.value.termed, []); XCTAssertEqual(table.s.value.killed, [])
        XCTAssertNil(target.ownedHostPID)
    }

    func testUnreadableExecutableIsNeverSignalled() async {
        table.s.with { $0.alive = [500] }; target.ownedHostPID = 500      // exe map has no entry: nil
        await coordinator().runQuit()
        XCTAssertEqual(table.s.value.termed, []); XCTAssertEqual(table.s.value.killed, [])
    }

    func testPidReusedBetweenTermAndKillGetsNoSigkill() async {
        table.s.with { $0.alive = [500]; $0.ignoresTerm = [500]; $0.exe[500] = bin; $0.exeAfterTerm[500] = "/usr/bin/other" }
        target.ownedHostPID = 500
        await coordinator().runQuit()
        XCTAssertEqual(table.s.value.termed, [500]); XCTAssertEqual(table.s.value.killed, [], "reused pid must not be killed")
        XCTAssertNil(target.ownedHostPID)
    }

    func testPidReusedBeforeLastChanceKillGetsNoSigkill() async {
        table.s.with { $0.alive = [500]; $0.ignoresTerm = [500]; $0.ignoresKill = [500]; $0.exe[500] = bin; $0.exeAfterTerm[500] = .some(nil) }
        target.ownedHostPID = 500; target.hangPrepare = true
        var t = LifecycleTiming(); t.total = 0.3; t.prepareCap = 0.05; t.termWait = 5; t.killWait = 5; t.poll = 0.01
        await coordinator(t).runQuit()
        XCTAssertEqual(table.s.value.killed, [])
    }

    func testHostFinishingLaunchAfterPrepareCapIsStopped() async {
        let launcher = SlowLauncher(delay: 0.12, pid: 600)
        let model = AppModel(client: FakeControlClient(), launcher: launcher, pollInterval: nil)
        table.s.with { $0.alive = [600]; $0.exe[600] = bin }
        model.startHost()
        let started = await waitFor { model.hostLaunchInFlight }
        XCTAssertTrue(started)
        var t = LifecycleTiming(); t.total = 1; t.prepareCap = 0.03; t.termWait = 0.2; t.killWait = 0.1; t.poll = 0.01
        let c = LifecycleCoordinator(target: model, table: table, store: store, expectedBinary: { self.bin }, timing: t)
        await c.runQuit()
        XCTAssertEqual(table.s.value.termed, [600], "late-launched host must not be orphaned")
    }

    // MARK: adoption

    func seed(pid: Int32 = 500, recBin: String? = nil, exe: String? = nil, lock: Int32? = 500, alive: Bool = true) {
        store.rec.with { $0 = OwnedHostRecord(pid: pid, binaryPath: recBin ?? bin) }
        table.s.with { if alive { $0.alive = [pid] }; $0.exe[pid] = exe ?? bin; $0.lock = lock }
    }

    func testAdoptsWhenRecordPathAndLockAgree() {
        seed()
        XCTAssertEqual(coordinator().adoptOnLaunch(), .adopted(500))
        XCTAssertEqual(target.ownedHostPID, 500)
        XCTAssertEqual(store.rec.value?.pid, 500)
    }

    func testAdoptedHostIsStoppedOnNextQuit() async {
        seed(); let c = coordinator(); c.adoptOnLaunch()
        await c.runQuit()
        XCTAssertEqual(table.s.value.termed, [500])
    }

    func testNoRecordMeansForeign() {
        table.s.with { $0.alive = [500]; $0.exe[500] = bin; $0.lock = 500 }
        XCTAssertEqual(coordinator().adoptOnLaunch(), .noRecord); XCTAssertNil(target.ownedHostPID)
    }

    func testRejections() {
        for (name, setup): (String, () -> Void) in [
            ("dead pid", { self.seed(alive: false) }),
            ("pid reused by another program", { self.seed(exe: "/usr/bin/other") }),
            ("recorded binary differs from current", { self.seed(recBin: "/old/strim", exe: "/old/strim") }),
            ("lock held by someone else", { self.seed(lock: 999) }),
            ("no lock file", { self.seed(lock: nil) }),
        ] {
            table = FakeProcessTable(); store = FakeStore(); target = FakeTarget()
            setup()
            let out = coordinator().adoptOnLaunch()
            XCTAssertNil(target.ownedHostPID, name)
            XCTAssertNil(store.rec.value, "\(name): record dropped"); XCTAssertNotEqual(out, .adopted(500), name)
        }
    }

    func testLaunchWritesRecordAndExitClearsIt() {
        let c = coordinator(); defer { withExtendedLifetime(c) {} }
        target.ownedHostPID = 42
        XCTAssertEqual(store.rec.value, OwnedHostRecord(pid: 42, binaryPath: bin))
        target.ownedHostPID = nil
        XCTAssertNil(store.rec.value)
    }

    func testFileStoreRoundTripAndPermissions() throws {
        let dir = NSTemporaryDirectory() + "qlt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = FileOwnedHostStore(path: dir + "/app-host.json")
        XCTAssertNil(s.load())
        s.save(OwnedHostRecord(pid: 9, binaryPath: "/x")); XCTAssertEqual(s.load()?.pid, 9)
        let mode = (try FileManager.default.attributesOfItem(atPath: dir + "/app-host.json")[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0 != "app-host.json" }
        XCTAssertEqual(leftovers, [], "no temp file left behind")
        s.save(OwnedHostRecord(pid: 10, binaryPath: "/y")); XCTAssertEqual(s.load()?.pid, 10)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir + "/app-host.json")[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        s.clear(); XCTAssertNil(s.load())
    }

    func testSystemTableReadsLockOwnerAndOwnPath() throws {
        let dir = NSTemporaryDirectory() + "qlt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "1234\n".write(toFile: dir + "/host.lock", atomically: true, encoding: .utf8)
        let t = SystemProcessTable(lockPath: dir + "/host.lock")
        XCTAssertEqual(t.lockOwner(), 1234)
        XCTAssertNotNil(t.executablePath(of: getpid())); XCTAssertTrue(t.isAlive(getpid()))
    }

    // MARK: real AppModel

    func testAdoptedHostPreventsDuplicateStart() async {
        let launcher = MockLauncher(.started(pid: 4242))
        let model = AppModel(client: FakeControlClient(), launcher: launcher, pollInterval: nil)
        seed()
        let c = LifecycleCoordinator(target: model, table: table, store: store, expectedBinary: { self.bin })
        XCTAssertEqual(c.adoptOnLaunch(), .adopted(500))
        XCTAssertEqual(model.ownedHostPID, 500); XCTAssertFalse(model.hostCanBeStarted)
        model.startHost(); await model.startServer()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(launcher.calls.value, 0)
    }

    func testPrepareForQuitWithNothingOwnedReturnsNil() async {
        let model = AppModel(client: FakeControlClient(), launcher: MockLauncher(.needsModel), pollInterval: nil)
        let pid = await model.prepareForQuit()
        XCTAssertNil(pid)
    }
}

final class SlowLauncher: HostLauncher, @unchecked Sendable {
    let delay: Double, pid: Int32
    init(delay: Double, pid: Int32) { self.delay = delay; self.pid = pid }
    func start(settings: AppSettings) -> HostLaunchResult { Thread.sleep(forTimeInterval: delay); return .started(pid: pid) }
}

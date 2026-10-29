import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Quit / relaunch / wake decisions, kept out of the AppKit delegate so they run windowless against fakes.
//
// Ownership rules:
//  - Quit stops ONLY the pid this app instance launched (or adopted, see below). A server it merely connected to
//    (started by the CLI or another tool) is never signalled.
//  - Adoption on relaunch: a server left running by a previous app instance is adopted as owned only when ALL hold:
//    the app-written record exists, that pid is alive, its executable path equals the recorded binary path, that path
//    equals the binary the app would launch now (bundle/CLI path), and host.lock names that pid as its holder.
//    Anything else is treated as foreign and the stale record is dropped. An adopted server is never launched twice
//    (the model refuses to start while it owns a pid).

public struct OwnedHostRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var binaryPath: String
    public init(pid: Int32, binaryPath: String) { self.pid = pid; self.binaryPath = binaryPath }
}

public protocol OwnedHostStore: Sendable {
    func load() -> OwnedHostRecord?
    func save(_ record: OwnedHostRecord)
    func clear()
}

public protocol HostProcessTable: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func terminate(_ pid: Int32)
    func kill(_ pid: Int32)
    func executablePath(of pid: Int32) -> String?
    /// First line of host.lock (the pid of the host holding it).
    func lockOwner() -> Int32?
}

public struct SystemProcessTable: HostProcessTable {
    public let lockPath: String
    public init(lockPath: String = AppPaths.home + "/.strim/host.lock") { self.lockPath = lockPath }
    public func isAlive(_ pid: Int32) -> Bool { pid > 1 && Darwin.kill(pid, 0) == 0 }
    public func terminate(_ pid: Int32) { if pid > 1 { _ = Darwin.kill(pid, SIGTERM) } }
    public func kill(_ pid: Int32) { if pid > 1 { _ = Darwin.kill(pid, SIGKILL) } }
    public func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
    public func lockOwner() -> Int32? {
        guard let h = FileHandle(forReadingAtPath: lockPath) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 32)) ?? Data()
        return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct FileOwnedHostStore: OwnedHostStore {
    public let path: String
    public init(path: String = AppPaths.home + "/.strim/app-host.json") { self.path = path }
    public func load() -> OwnedHostRecord? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(OwnedHostRecord.self, from: d)
    }
    public func save(_ record: OwnedHostRecord) {
        guard let d = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created 0600 from the start (no wider-mode window), then renamed into place atomically.
        let tmp = path + ".tmp.\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let ok = d.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        if !ok || rename(tmp, path) != 0 { unlink(tmp) }
    }
    public func clear() { try? FileManager.default.removeItem(atPath: path) }
}

public struct LifecycleTiming: Sendable {
    /// Hard bound for the whole quit sequence.
    public var total = 4.0
    /// Closing sessions / cancelling work may not delay the stop signal past this.
    public var prepareCap = 0.5
    /// Wait after SIGTERM before SIGKILL.
    public var termWait = 3.0
    public var killWait = 0.3
    public var poll = 0.1
    public init() {}
}

@MainActor
public protocol LifecycleTarget: AnyObject {
    var ownedHostPID: Int32? { get }
    var onOwnedHostChange: ((Int32?) -> Void)? { get set }
    /// Ends the update loop, cancels a running download, closes live chat sessions; returns the owned pid.
    func prepareForQuit() async -> Int32?
    func hostExited(_ pid: Int32)
    func adoptRunningHost(_ pid: Int32)
    func reconnectNow()
    /// A host launch has started and has not yet published its pid.
    var hostLaunchInFlight: Bool { get }
}

extension LifecycleTarget { public var hostLaunchInFlight: Bool { false } }

public enum QuitReply: Equatable, Sendable { case now, later }
public enum AdoptOutcome: Equatable, Sendable {
    case noRecord, stale, adopted(Int32), rejected(String)
}

private final class Once: @unchecked Sendable {
    private let l = NSLock(); private var done = false
    func take() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true }
}

@MainActor
public final class LifecycleCoordinator {
    private let target: LifecycleTarget
    private let table: HostProcessTable
    private let store: OwnedHostStore
    private let clock: AppClock
    private let expectedBinary: () -> String?
    private let keepServerOnQuit: () -> Bool
    private let timing: LifecycleTiming
    public private(set) var isQuitting = false
    private var termPID: Int32?

    public init(target: LifecycleTarget, table: HostProcessTable = SystemProcessTable(),
                store: OwnedHostStore = FileOwnedHostStore(), clock: AppClock = SystemClock(),
                expectedBinary: @escaping () -> String?, keepServerOnQuit: @escaping () -> Bool = { false },
                timing: LifecycleTiming = LifecycleTiming()) {
        self.target = target; self.table = table; self.store = store; self.clock = clock
        self.expectedBinary = expectedBinary; self.keepServerOnQuit = keepServerOnQuit; self.timing = timing
        target.onOwnedHostChange = { [weak self] pid in self?.ownedHostChanged(pid) }
    }

    // MARK: quit

    /// Cmd+Q, menu Quit, logout, shutdown. The first request runs the bounded stop and replies later; a second one
    /// while it runs terminates immediately.
    public func requestQuit(reply: @escaping @MainActor () -> Void) -> QuitReply {
        if isQuitting { return .now }
        isQuitting = true
        Task { @MainActor in
            await self.runQuit()
            reply()
        }
        return .later
    }

    public func runQuit() async {
        isQuitting = true
        _ = await race(timing.total) { await self.shutdownSteps() }
        // Hard bound hit with the owned host still alive: last-chance SIGKILL (never for a kept or foreign pid).
        if let pid = termPID, !keepServerOnQuit(), table.isAlive(pid) {
            if stillOurs(pid) { table.kill(pid) } else { target.hostExited(pid) }
        }
    }

    /// The pid still runs the binary we launched (guards against pid reuse after our server exited).
    private func stillOurs(_ pid: Int32) -> Bool {
        guard let exe = table.executablePath(of: pid),
              let want = expectedBinary() ?? store.load()?.binaryPath else { return false }
        return Self.samePath(exe, want)
    }

    private func shutdownSteps() async {
        var pid = target.ownedHostPID
        if let r = await race(timing.prepareCap, { await self.target.prepareForQuit() }) { pid = r }
        else {
            // Cap fired: a launch still in flight may publish its pid after this point; give it the spare budget.
            let spare = max(0, timing.total - timing.prepareCap - timing.termWait - timing.killWait)
            var waited = 0.0
            while target.ownedHostPID == nil, target.hostLaunchInFlight, waited < spare {
                do { try await clock.sleep(seconds: timing.poll) } catch { break }
                waited += timing.poll
            }
            pid = target.ownedHostPID ?? pid
        }
        guard let pid, pid > 1, pid != getpid(), !keepServerOnQuit() else { return }
        termPID = pid
        guard table.isAlive(pid) else { target.hostExited(pid); return }
        guard stillOurs(pid) else { target.hostExited(pid); return }
        table.terminate(pid)
        if await waitExit(pid, timing.termWait) { target.hostExited(pid); return }
        guard stillOurs(pid) else { target.hostExited(pid); return }
        table.kill(pid)
        if await waitExit(pid, timing.killWait) { target.hostExited(pid) }
    }

    private func waitExit(_ pid: Int32, _ seconds: Double) async -> Bool {
        let steps = max(1, Int((seconds / timing.poll).rounded(.up)))
        for _ in 0..<steps {
            if !table.isAlive(pid) { return true }
            do { try await clock.sleep(seconds: timing.poll) } catch { return !table.isAlive(pid) }
        }
        return !table.isAlive(pid)
    }

    /// First of work / timeout wins; the loser is cancelled (a stuck `op` is abandoned, not awaited).
    private func race<T: Sendable>(_ seconds: Double, _ op: @escaping @MainActor () async -> T) async -> T? {
        let once = Once(), clock = clock
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let work = Task { @MainActor in
                let v = await op()
                if once.take() { c.resume(returning: v) }
            }
            Task {
                try? await clock.sleep(seconds: seconds)
                if once.take() { work.cancel(); c.resume(returning: nil) }
            }
        }
    }

    // MARK: relaunch

    @discardableResult
    public func adoptOnLaunch() -> AdoptOutcome {
        guard let rec = store.load() else { return .noRecord }
        guard table.isAlive(rec.pid) else { store.clear(); return .stale }
        func reject(_ why: String) -> AdoptOutcome { store.clear(); return .rejected(why) }
        guard let expected = expectedBinary(), Self.samePath(expected, rec.binaryPath) else { return reject("binary differs from current") }
        guard let exe = table.executablePath(of: rec.pid), Self.samePath(exe, rec.binaryPath) else { return reject("pid is another program") }
        guard table.lockOwner() == rec.pid else { return reject("host.lock names another owner") }
        target.adoptRunningHost(rec.pid)
        return .adopted(rec.pid)
    }

    private func ownedHostChanged(_ pid: Int32?) {
        if let pid, let bin = expectedBinary() { store.save(OwnedHostRecord(pid: pid, binaryPath: bin)) }
        else if pid == nil { store.clear() }
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardized.path == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardized.path
    }

    // MARK: sleep / wake

    /// Wake: the connection is stale after sleep. Reconnect the existing server; never relaunch it.
    public func systemDidWake() {
        guard !isQuitting else { return }
        target.reconnectNow()
    }
}

extension AppModel: LifecycleTarget {}

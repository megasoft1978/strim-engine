import Foundation

/// Multi-producer, single-consumer command queue: mutex-protected array plus a semaphore the
/// consumer parks on when it has no work. Wakeups may be spurious (the consumer re-checks).
final class Inbox<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    private let sem = DispatchSemaphore(value: 0)

    func push(_ item: Item) {
        lock.lock(); items.append(item); lock.unlock()
        sem.signal()
    }

    /// Takes everything queued so far, in push order.
    func drain() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        if items.isEmpty { return [] }
        let out = items
        items.removeAll(keepingCapacity: true)
        return out
    }

    /// Parks until a push happened (or returns at once if one is unconsumed).
    func wait() { sem.wait() }
    @discardableResult
    func wait(timeout: TimeInterval) -> Bool { sem.wait(timeout: .now() + timeout) == .success }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// What the engine thread drives. All methods run on the one engine thread.
protocol EngineWorker: AnyObject, Sendable {
    /// Loads the model etc. on the engine thread (MLX streams are per-thread).
    func prepare() throws
    /// Runs one work unit; false when there is nothing to do.
    func runOneUnit() -> Bool
    var shouldStop: Bool { get }
    func shutdown()
}

/// ONE dedicated OS thread with its own loop. Not a Swift actor or a cooperative-pool task:
/// MLX streams and the objects created on them are tied to the creating thread.
///
/// Loop: drain the inbox (commands are applied between units, so cancellation and new
/// arrivals take effect at unit boundaries), run at most one unit, repeat; park when idle.
final class EngineLoop<W: EngineWorker>: @unchecked Sendable {
    typealias Command = @Sendable (W) -> Void
    let inbox = Inbox<Command>()
    private let worker: W
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    /// Name of the thread the loop ran on, for tests.
    private(set) var threadName = ""

    init(worker: W) { self.worker = worker }

    func start(onReady: @escaping @Sendable (Error?) -> Void) {
        let t = Thread { [self] in
            Thread.current.name = "strim-engine"
            threadName = Thread.current.name ?? ""
            do { try worker.prepare() } catch {
                onReady(error); done.signal(); return
            }
            onReady(nil)
            run()
            worker.shutdown()
            done.signal()
        }
        t.stackSize = 16 << 20
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func send(_ c: @escaping Command) { inbox.push(c) }

    func stop() {
        inbox.push { _ in }   // wake the loop; shouldStop is set by the caller's command
    }

    func waitUntilStopped() { done.wait() }

    private func run() {
        while !worker.shouldStop {
            let cmds = inbox.drain()
            for c in cmds { c(worker) }
            if worker.shouldStop { break }
            if worker.runOneUnit() { continue }
            if !cmds.isEmpty { continue }   // a command may have created work
            inbox.wait()
        }
    }
}

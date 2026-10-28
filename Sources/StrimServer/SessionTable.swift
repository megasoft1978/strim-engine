import Foundation
import StrimEngine

/// Maps a conversation fingerprint to a live engine session so a stateless client that resends its whole
/// history each turn keeps hitting the same ledger / hot state. LRU-capped; concurrent requests on one
/// conversation get a throwaway session instead of waiting.
actor SessionTable {
    struct Lease: Sendable {
        let session: SessionID
        let fingerprint: UInt64
        /// False: a session that is closed when the request ends (not in the table).
        let pooled: Bool
        /// True when an existing pooled session was reused.
        let reused: Bool
    }

    private struct Entry {
        var session: SessionID
        var busy: Bool
        var used: UInt64
    }

    private let engine: any EngineClient
    private let capacity: Int
    private var entries: [UInt64: Entry] = [:]
    private var tick: UInt64 = 0
    private(set) var reuseCount = 0
    private(set) var openCount = 0

    init(engine: any EngineClient, capacity: Int) {
        self.engine = engine
        self.capacity = max(capacity, 1)
    }

    var count: Int { entries.count }

    func acquire(fingerprint fp: UInt64, config: SessionConfig) async throws -> Lease {
        tick += 1
        if var e = entries[fp], !e.busy {
            e.busy = true; e.used = tick
            entries[fp] = e
            reuseCount += 1
            return Lease(session: e.session, fingerprint: fp, pooled: true, reused: true)
        }
        let busyElsewhere = entries[fp] != nil
        let id = try await engine.openSession(config)
        openCount += 1
        if busyElsewhere || entries[fp] != nil {
            return Lease(session: id, fingerprint: fp, pooled: false, reused: false)
        }
        tick += 1
        entries[fp] = Entry(session: id, busy: true, used: tick)
        var victims: [SessionID] = []
        while entries.count > capacity,
              let old = entries.filter({ !$0.value.busy }).min(by: { $0.value.used < $1.value.used }) {
            entries[old.key] = nil
            victims.append(old.value.session)
        }
        for v in victims { await engine.close(v) }
        return Lease(session: id, fingerprint: fp, pooled: true, reused: false)
    }

    /// Ends a lease. `keep: false` drops the session (the engine state is suspect).
    func release(_ lease: Lease, keep: Bool) async {
        guard lease.pooled else { await engine.close(lease.session); return }
        guard var e = entries[lease.fingerprint], e.session == lease.session else { return }
        if keep {
            e.busy = false
            entries[lease.fingerprint] = e
        } else {
            entries[lease.fingerprint] = nil
            await engine.close(lease.session)
        }
    }

    func closeAll() async {
        let all = entries.values.map(\.session)
        entries = [:]
        for s in all { await engine.close(s) }
    }
}

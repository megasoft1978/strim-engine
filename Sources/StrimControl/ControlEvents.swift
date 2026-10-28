import Foundation
import StrimAPI
import StrimHost
import StrimHTTP
import StrimJobs

extension StrimControlPlane {
    /// `GET /v1/strim/events[?session_id=j_...]`: `status` on connect and every `statusInterval`, `job_event` on job
    /// status changes, `harness_event` for job progress, chat output published by `chat/append`, `: ping` comments.
    /// At most `maxEventSubscribers` connections (429 beyond); ONE shared poller serves all of them.
    func events(_ req: Request, _ r: Responder) async throws {
        do { try ControlGuard.check(req, status: false, auth: auth) } catch {
            await send(error, r); return
        }
        let filter = req.query["session_id"]
        if let f = filter, !ControlMapping.isValidJobID(f) {
            await send(ControlError.badRequest("malformed session_id"), r); return
        }
        guard let sub = hub.subscribe(session: filter) else {
            await send(ControlError(429, "too_many_subscribers", "too many event streams (limit \(hub.maxSubscribers))"), r); return
        }
        defer { hub.unsubscribe(sub.id) }
        sub.continuation.yield(.event(.status(await hostStatus())))
        ensurePoller()

        do {
            try await r.startSSE()
            for await item in sub.stream {
                if r.isClosed { break }
                switch item {
                case .event(let e):
                    try await r.sseEvent(e.typeName, String(decoding: try ControlJSON.encode(e), as: UTF8.self))
                case .ping:
                    try await r.sseComment("ping")
                }
            }
            try await r.finish()
        } catch {
            // peer closed or encode failure: end the stream
        }
    }

    /// Starts the shared poller when there is none; it stops itself when the last subscriber leaves.
    func ensurePoller() {
        pollerLock.withLock { task in
            guard task == nil else { return }
            task = Task { [self] in await pollLoop() }
        }
    }

    private func pollLoop() async {
        var known: [String: (JobStatusDTO, StrimAPI.VerifyResult?)] = [:]
        var cursor: [String: Int] = [:]
        var first = true
        let clock = ContinuousClock()
        var lastStatus = clock.now, lastPing = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: options.jobPollInterval)
            let stop = pollerLock.withLock { task -> Bool in
                if hub.subscriberCount == 0 { task = nil; return true }
                return false
            }
            if stop { return }
            let records = (try? await store.list()) ?? []
            for rec in records {
                let s = ControlMapping.summary(rec)
                let key = (s.status, s.verify)
                let changed = known[rec.id].map { $0 != key } ?? !first
                if changed { hub.publish(.jobEvent(JobEvent(jobID: rec.id, status: s.status, verify: s.verify))) }
                known[rec.id] = key
                // Harness progress of live jobs (plus the tail of one that just finished). Chat sessions publish
                // their own frames through `chat/append`; their mirrored job events would be duplicates.
                guard rec.profile == nil else { continue }
                if !rec.status.isTerminal || changed || cursor[rec.id] == nil {
                    guard let from = cursor[rec.id] else {
                        let n = ((try? await jobs.eventsSince(rec.id, index: 0)) ?? []).count
                        cursor[rec.id] = (first || rec.status.isTerminal) ? n : 0
                        continue
                    }
                    let evs = (try? await jobs.eventsSince(rec.id, index: from)) ?? []
                    for e in evs { hub.publish(.harnessEvent(HarnessEvent(jobID: rec.id, kind: e.kind, text: e.text))) }
                    if let last = evs.last { cursor[rec.id] = last.index + 1 }
                }
            }
            first = false
            if clock.now - lastStatus >= options.statusInterval {
                lastStatus = clock.now
                hub.publish(.status(await hostStatus()))
            }
            if clock.now - lastPing >= options.pingInterval {
                lastPing = clock.now
                hub.ping()
            }
        }
    }
}

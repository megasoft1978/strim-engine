import Foundation
import StrimAPI
import StrimHarness
import StrimHost
import StrimHTTP
import StrimJobs

extension StrimControlPlane {
    func chatOpen(_ req: Request) async throws -> Reply {
        let b = try ControlJSON.decode(ChatOpenRequest.self, from: req.body)
        guard let profile = RunProfile.named(b.profile) else { throw ChatError.unknownProfile(b.profile) }
        guard b.cwd.hasPrefix("/"), !b.cwd.contains("\0") else { throw ControlError.badRequest("cwd must be an absolute path") }
        var access = AccessLevel.write
        if policy.violation(access: "write", cwd: b.cwd) != nil {
            access = .read
            if let v = policy.violation(access: "read", cwd: b.cwd) { throw ControlError.forbidden(v) }
        }
        let id = try await jobs.openSession(HarnessJobSpec(task: "", cwd: b.cwd, access: access), profile: profile)
        if let t = b.enableThinking { try await jobs.setChatThinking(id, enabled: t) }
        return try .json(ChatSession(sessionID: id, jobID: id, cwd: b.cwd, profile: b.profile))
    }

    func chatCancel(_ req: Request) async throws -> Reply {
        let b = try ControlJSON.decode(ChatCancelRequest.self, from: req.body)
        try await jobs.cancelTurn(b.sessionID)
        return .empty
    }

    func chatClose(_ id: String) async throws -> Reply {
        guard ControlMapping.isValidJobID(id) else { throw ControlError.badRequest("malformed session id") }
        try await jobs.closeSession(id)
        await jobs.flush()
        let r = try await record(id)
        return try await detailReply(r)
    }

    /// `POST chat/append`. Default: 202 and the turn's output arrives as `chat_delta` / `harness_event` frames on
    /// `/events` (cancelled if nobody listens for `orphanTurnGrace`). With `Accept: text/event-stream` the same frames
    /// stream in the response itself and a client disconnect cancels the turn.
    func chatAppend(_ req: Request, _ r: Responder) async throws {
        let stream: AsyncStream<ChatEvent>
        let id: String
        do {
            try ControlGuard.check(req, status: false, auth: auth)
            try ControlGuard.jsonBody(req, maxBytes: options.maxBodyBytes)
            let b = try ControlJSON.decode(ChatAppendRequest.self, from: req.body)
            id = b.sessionID
            guard ControlMapping.isValidJobID(id) else { throw ChatError.sessionNotFound(id) }
            let state = await slot.status().state
            guard state == .ready || state == .busy else { throw ControlError.unavailable("no model loaded (state: \(state.rawValue))") }
            if let t = b.enableThinking { try await jobs.setChatThinking(id, enabled: t) }
            stream = try await jobs.appendUserTurn(id, text: b.text)
        } catch let e as HTTPServerError {
            throw e
        } catch {
            await send(error, r)
            return
        }

        if (req.headers["Accept"] ?? "").contains("text/event-stream") {
            do {
                try await r.startSSE()
                for await ev in stream {
                    for w in ControlMapping.events(ev, sessionID: id) {
                        hub.publish(w)
                        try await r.sseEvent(w.typeName, String(decoding: try ControlJSON.encode(w), as: UTF8.self))
                    }
                }
                try await r.finish()
            } catch {
                // Write failed: the peer is gone. Returning drops `stream`, which cancels the turn.
            }
            return
        }

        await respond(r) { Reply(status: 202, body: Data("{}".utf8)) }
        let hub = self.hub, jobs = self.jobs, grace = options.orphanTurnGrace
        let pump = Task {
            for await ev in stream { for w in ControlMapping.events(ev, sessionID: id) { hub.publish(w) } }
        }
        let watchdog = Task {
            let clock = ContinuousClock()
            var since: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if hub.subscriberCount > 0 { since = nil; continue }
                since = since ?? clock.now
                if let s = since, clock.now - s >= grace { try? await jobs.cancelTurn(id); return }
            }
        }
        // The handler returns now (the 202 is out); the turn lives on in the background.
        Task { await pump.value; watchdog.cancel() }
    }
}

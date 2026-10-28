import Foundation
import StrimAPI

/// One SSE connection's inbox: wire events plus keep-alive pings.
enum SSEItem: Sendable { case event(StrimEvent), ping }

/// Fan-out of events to the SSE connections: broadcast items (status, job events, pings) reach everyone; chat output
/// (`chat_delta`, and `harness_event` of the same job id) reaches subscribers without a session filter and the one
/// whose `session_id` filter matches. The number of subscribers is capped.
final class EventHub: @unchecked Sendable {
    private struct Sub { var cont: AsyncStream<SSEItem>.Continuation; var session: String? }
    private let lock = NSLock()
    private var subs: [UUID: Sub] = [:]
    let maxSubscribers: Int

    init(maxSubscribers: Int = 8) { self.maxSubscribers = maxSubscribers }

    var subscriberCount: Int { lock.withLock { subs.count } }

    /// nil when the cap is reached.
    func subscribe(session: String? = nil) -> (id: UUID, stream: AsyncStream<SSEItem>, continuation: AsyncStream<SSEItem>.Continuation)? {
        let (stream, cont) = AsyncStream<SSEItem>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        let id = UUID()
        let ok = lock.withLock { () -> Bool in
            guard subs.count < maxSubscribers else { return false }
            subs[id] = Sub(cont: cont, session: session)
            return true
        }
        if !ok { cont.finish(); return nil }
        return (id, stream, cont)
    }

    func unsubscribe(_ id: UUID) {
        let s = lock.withLock { subs.removeValue(forKey: id) }
        s?.cont.finish()
    }

    func publish(_ e: StrimEvent) {
        let target: String?
        switch e {
        case .chatDelta(let d): target = d.sessionID
        case .harnessEvent(let h): target = h.jobID
        default: target = nil
        }
        let all = lock.withLock { Array(subs.values) }
        for s in all where target == nil || s.session == nil || s.session == target { s.cont.yield(.event(e)) }
    }

    func ping() {
        let all = lock.withLock { Array(subs.values) }
        for s in all { s.cont.yield(.ping) }
    }
}

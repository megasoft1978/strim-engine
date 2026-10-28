import Foundation
import Testing
@testable import StrimHTTP

// F2/F3: connection cap, read timeouts and pipelining bound, all enforced before routing or auth.
// The `LIMITS` line is the only API difference from the pre-fix server.

private func makeServer(_ lim: HTTPServerLimits, token: String? = nil) async throws -> (HTTPServer, UInt16) {
    let server = HTTPServer(port: 0, bearerToken: token, limits: lim)   // LIMITS
    server.route("GET", "/ok") { _, r in try await r.text(200, "ok") }
    server.route("GET", "/slow") { _, r in
        try? await Task.sleep(for: .milliseconds(600))
        try await r.text(200, "slow")
    }
    return (server, try await server.start())
}

/// True when the server closes the connection within `seconds` (no further response bytes are required).
private func closes(_ c: RawClient, within seconds: Double) async -> Bool {
    await withTaskGroup(of: Bool.self) { g in
        g.addTask { while await c.readMore() {}; return true }
        g.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            c.cancel()   // unblocks the non-cancellable receive so the group can finish
            return false
        }
        let first = await g.next() ?? false
        g.cancelAll()
        return first
    }
}

@Suite("HTTP limits", .serialized) struct HTTPLimitsTests {
    @Test func slowHeadIsClosed() async throws {
        let (server, port) = try await makeServer(HTTPServerLimits(headTimeout: 0.4))
        defer { server.stop() }
        let c = RawClient(port: port); defer { c.cancel() }
        try await c.send("GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Slow: ")   // never finished
        #expect(await closes(c, within: 3))
    }

    @Test func stalledBodyIsClosed() async throws {
        let (server, port) = try await makeServer(HTTPServerLimits(bodyTimeout: 0.4))
        defer { server.stop() }
        let c = RawClient(port: port); defer { c.cancel() }
        try await c.send("POST /ok HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 16777216\r\n\r\nabc")
        #expect(await closes(c, within: 3))
    }

    @Test func idleKeepAliveIsClosedButActiveRequestIsNot() async throws {
        let (server, port) = try await makeServer(HTTPServerLimits(idleTimeout: 0.5))
        defer { server.stop() }
        // A request that runs longer than the idle timeout still completes.
        let busy = RawClient(port: port); defer { busy.cancel() }
        try await busy.send("GET /slow HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        #expect(await busy.readResponse()?.status == 200)
        let idle = RawClient(port: port); defer { idle.cancel() }
        try await idle.send("GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(await idle.readResponse()?.status == 200)
        #expect(await closes(idle, within: 4))
    }

    @Test func connectionCapDropsTheExtraConnection() async throws {
        let (server, port) = try await makeServer(HTTPServerLimits(maxConnections: 2))
        defer { server.stop() }
        let a = RawClient(port: port), b = RawClient(port: port)
        defer { a.cancel(); b.cancel() }
        for c in [a, b] {
            try await c.send("GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            #expect(await c.readResponse()?.status == 200)
        }
        let extra = RawClient(port: port); defer { extra.cancel() }
        try? await extra.send("GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(await extra.readResponse() == nil)
        // The first two are still served.
        try await a.send("GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(await a.readResponse()?.status == 200)
    }

    @Test func pipeliningFloodIsCut() async throws {
        let (server, port) = try await makeServer(HTTPServerLimits(maxPipelined: 3))
        defer { server.stop() }
        let c = RawClient(port: port); defer { c.cancel() }
        let watchdog = Task { try? await Task.sleep(for: .seconds(15)); c.cancel() }   // unblock a hung read
        defer { watchdog.cancel() }
        let one = "GET /slow HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        try await c.send(String(repeating: one, count: 12))
        var statuses: [Int] = []
        while let r = await c.readResponse() { statuses.append(r.status) }
        #expect(statuses.count < 12)
        #expect(statuses.last == 429)
        #expect(statuses.dropLast().allSatisfy { $0 == 200 })
    }

    @Test func normalKeepAliveTrafficIsUntouched() async throws {
        let (server, port) = try await makeServer(HTTPServerLimits())
        defer { server.stop() }
        let c = RawClient(port: port); defer { c.cancel() }
        for _ in 0..<5 {
            try await c.send("GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            #expect(await c.readResponse()?.status == 200)
        }
    }
}

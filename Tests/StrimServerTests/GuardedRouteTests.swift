import Foundation
import Testing
import StrimEngine
import StrimHTTP
@testable import StrimServer

/// One raw HTTP/1.1 exchange over a blocking loopback socket (lets tests set an arbitrary Host header).
private func rawExchange(port: UInt16, request: String) async -> String {
    await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return "" }
        _ = Array(request.utf8).withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }.value
}

@Suite("StrimServer guarded routes", .serialized)
struct GuardedRouteTests {
    private func start() async throws -> (StrimOpenAIServer, UInt16) {
        let server = StrimOpenAIServer(engine: FakeEngine(), config: ServerConfig(modelId: "m", bearerToken: "tok"))
        server.addGuardedRoute("POST", "/mcp") { _, r in try await r.json(200, Data(#"{"hook":true}"#.utf8)) }
        return (server, try await server.start(port: 0))
    }

    private func post(_ port: UInt16, host: String = "127.0.0.1", auth: Bool) async -> String {
        var req = "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nContent-Length: 2\r\n"
        if auth { req += "Authorization: Bearer tok\r\n" }
        return await rawExchange(port: port, request: req + "\r\n{}")
    }

    @Test("hook route wins over catch-all and is served with bearer")
    func exactRoute() async throws {
        let (s, port) = try await start(); defer { s.stop() }
        let ok = await post(port, auth: true)
        #expect(ok.hasPrefix("HTTP/1.1 200") && ok.contains(#"{"hook":true}"#))
    }

    @Test("401 without bearer")
    func unauthorized() async throws {
        let (s, port) = try await start(); defer { s.stop() }
        #expect(await post(port, auth: false).hasPrefix("HTTP/1.1 401"))
    }

    @Test("403 for a non-loopback Host")
    func badHost() async throws {
        let (s, port) = try await start(); defer { s.stop() }
        #expect(await post(port, host: "evil.example.com", auth: true).hasPrefix("HTTP/1.1 403"))
    }
}

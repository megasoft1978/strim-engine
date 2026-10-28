import Foundation
import Testing
import StrimHTTP
import StrimTemplate
@testable import StrimMCP

private struct NoopProvider: MCPToolProvider {
    func definitions() -> [MCPToolDefinition] { [] }
    func call(name: String, arguments: OrderedJSON, progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        MCPToolResult(text: "ok")
    }
}

/// F8: a JSON-RPC batch is capped so one request cannot queue thousands of tool calls.
@Suite("MCP batch limit") struct MCPBatchLimitTests {
    private func post(_ items: Int) async throws -> RawClient.Response {
        let route = MCPRoute(provider: NoopProvider(), serverName: "t", version: "1", instructions: "")
        let server = HTTPServer(port: 0)
        server.route("POST", "/mcp") { req, r in try await route.handle(request: req, responder: r) }
        let port = try await server.start()
        defer { server.stop() }
        let body = "[" + (0..<items).map { #"{"jsonrpc":"2.0","id":\#($0),"method":"ping"}"# }.joined(separator: ",") + "]"
        let c = RawClient(port: port); defer { c.cancel() }
        try await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        return try #require(await c.readResponse())
    }

    @Test func oversizedBatchIsRejected() async throws {
        let r = try await post(17)
        #expect(r.status == 400)
    }

    @Test func batchAtTheLimitIsServed() async throws {
        let r = try await post(16)
        #expect(r.status == 200)
        #expect((try? JSONSerialization.jsonObject(with: Data(r.body)) as? [Any])?.count == 16)
    }
}

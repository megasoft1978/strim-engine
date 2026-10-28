import Foundation
import Testing
import StrimAPI
@testable import StrimControl

private let allControl: [(String, String)] = [
    ("GET", "/v1/strim/events"), ("GET", "/v1/strim/jobs"), ("GET", "/v1/strim/jobs/j_abcdefgh23"),
    ("POST", "/v1/strim/load"), ("POST", "/v1/strim/unload"), ("POST", "/v1/strim/jobs/approve"),
    ("POST", "/v1/strim/chat/open"), ("POST", "/v1/strim/chat/append"), ("POST", "/v1/strim/chat/cancel"),
    ("POST", "/v1/strim/chat/close"), ("DELETE", "/v1/strim/chat/j_abcdefgh23"),
]

@Suite("scoped tokens", .serialized)
struct ControlTokenTests {
    @Test("the API/MCP token is 403 on every control route except GET status")
    func mcpTokenDenied() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        for (m, p) in allControl {
            let x = await r.call(m, p, body: m == "GET" ? nil : "{}", bearer: "tok")
            #expect(x.status == 403 && x.code == "forbidden", "\(m) \(p) -> \(x.status)")
        }
        #expect(await r.call("GET", "/v1/strim/status", bearer: "tok").status == 200)
    }

    @Test("the control token is refused on /mcp and the OpenAI routes, which keep using the API token")
    func controlTokenNotForApi() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        for (m, p) in [("POST", "/mcp"), ("POST", "/v1/chat/completions"), ("GET", "/v1/models"), ("GET", "/metrics")] {
            let bad = await Raw.exchange(port: r.port, method: m, path: p, host: "127.0.0.1",
                                         headers: ["Authorization": "Bearer \(r.control)", "Content-Type": "application/json"], body: m == "POST" ? "{}" : nil)
            #expect(bad.status == 401, "\(m) \(p) -> \(bad.status)")
        }
        #expect(await Raw.exchange(port: r.port, method: "GET", path: "/v1/models", host: "127.0.0.1",
                                   headers: ["Authorization": "Bearer tok"], body: nil).status == 200)
    }

    @Test("no credentials or a wrong token is 401 with one message that names neither token")
    func missingOrWrong() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        var msgs = Set<String>()
        for (m, p) in allControl + [("GET", "/v1/strim/status")] {
            let none = await r.call(m, p, body: m == "GET" ? nil : "{}", auth: false)
            let wrong = await r.call(m, p, body: m == "GET" ? nil : "{}", bearer: "nope")
            #expect(none.status == 401 && wrong.status == 401, "\(m) \(p)")
            msgs.insert(none.error_message); msgs.insert(wrong.error_message)
        }
        #expect(msgs.count == 1 && !(msgs.first ?? "").lowercased().contains("token"))
    }

    @Test("--no-auth host: status is open, everything else still needs the control token")
    func noAuthHost() async throws {
        let r = try await Rig.make(token: nil); defer { r.stop() }
        #expect(await r.call("GET", "/v1/strim/status", auth: false).status == 200)
        #expect(await r.call("POST", "/v1/strim/unload", body: "", auth: false).status == 401)
        #expect(await r.call("GET", "/v1/strim/jobs", auth: false).status == 401)
        #expect(await r.call("GET", "/v1/strim/jobs").status == 200)
    }

    @Test("control token file: 0600, stable across restarts, distinct from the API token, rotates when deleted")
    func tokenFile() throws {
        let dir = tmpDir("tok").path
        let api = dir + "/token"
        let path = ControlToken.path(besideAPITokenAt: api)
        #expect(path == dir + "/control-token")
        let t1 = try ControlToken.loadOrCreate(path: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! Int
        #expect(mode & 0o777 == 0o600 && t1.count == 64 && t1.allSatisfy(\.isHexDigit))
        #expect(try ControlToken.loadOrCreate(path: path) == t1)
        let apiTok = try ControlToken.loadOrCreate(path: api)
        #expect(apiTok != t1)
        chmod(path, 0o644)
        _ = try ControlToken.loadOrCreate(path: path)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! Int) & 0o777 == 0o600)
        try FileManager.default.removeItem(atPath: path)
        let t2 = try ControlToken.loadOrCreate(path: path)
        #expect(t2 != t1 && t2.count == 64)
        #expect(ControlToken.defaultPath.hasSuffix("/.strim/control-token"))
    }
}

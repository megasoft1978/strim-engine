import Foundation
import Testing
import StrimAPI
import StrimHarness
import StrimHost
@testable import StrimControl

private func openChat(_ r: Rig, cwd: String, access: String? = nil, bearer: String? = nil) async -> HTTPReply {
    await r.call("POST", "/v1/strim/chat/open", body: #"{"cwd":"\#(cwd)","profile":"interactive"}"#, bearer: bearer)
}
private func fbody(_ p: String) -> String { #"{"path":"\#(p)"}"# }

private struct FEnv {
    let base: String, home: String, cfg: URL
    func dir(_ n: String) -> String {
        let p = base + "/" + n; try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); return p
    }
    static func make() throws -> FEnv {
        let raw = NSTemporaryDirectory() + "fgc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw + "/home/.ssh", withIntermediateDirectories: true)
        let base = realpath(raw, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? raw
        return FEnv(base: base, home: base + "/home", cfg: URL(fileURLWithPath: base + "/state/config.json"))
    }
    func rig(access: AccessLevel = .write) async throws -> Rig {
        let g = FolderGrants(roots: [home], configURL: cfg, home: home)
        return try await Rig.make(policy: HostPolicy(maxAccess: access, allowedRoots: [home], grants: g))
    }
}

@Suite("folder grant routes", .serialized)
struct ControlFolderTests {
    @Test("only the control token may list, grant or revoke; the API token and no token cannot")
    func auth() async throws {
        let e = try FEnv.make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await e.rig(); defer { r.stop() }
        let ext = e.dir("ext")
        for (m, body) in [("GET", nil), ("POST", fbody(ext)), ("DELETE", fbody(ext))] as [(String, String?)] {
            let api = await r.call(m, "/v1/strim/folders", body: body, bearer: "tok")
            #expect(api.status == 403 && api.code == "forbidden", "\(m) with the API token")
            let none = await r.call(m, "/v1/strim/folders", body: body, auth: false)
            #expect(none.status == 401, "\(m) without a token")
            let wrong = await r.call(m, "/v1/strim/folders", body: body, bearer: "nope")
            #expect(wrong.status == 401, "\(m) with a wrong token")
        }
        #expect(r.plane.policy.grants?.roots == [e.home], "nothing was granted by the refused calls")
        #expect(!FileManager.default.fileExists(atPath: e.cfg.path))
        // MCP-style: a prompt-injected agent only holds the API token; the chat route still refuses the folder
        #expect(await openChat(r, cwd: ext, bearer: "tok").status == 403)
    }

    @Test("loopback Host/Origin guards still apply")
    func guards() async throws {
        let e = try FEnv.make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await e.rig(); defer { r.stop() }
        let ext = e.dir("ext")
        #expect(await r.call("POST", "/v1/strim/folders", body: fbody(ext), host: "evil.example").status == 403)
        #expect(await r.call("POST", "/v1/strim/folders", body: fbody(ext), headers: ["Origin": "https://evil.example"]).status == 403)
        #expect(await r.call("POST", "/v1/strim/folders", body: fbody(ext), headers: ["Sec-Fetch-Site": "cross-site"]).status == 403)
        #expect(await r.call("POST", "/v1/strim/folders", body: fbody(ext), headers: ["Content-Type": "text/plain"]).status == 400)
        #expect(r.plane.policy.grants?.roots == [e.home])
    }

    @Test("grant, list, persist, revoke over HTTP")
    func roundTrip() async throws {
        let e = try FEnv.make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await e.rig(); defer { r.stop() }
        let ext = e.dir("ext")
        let l0 = try await r.call("GET", "/v1/strim/folders").decode(FolderList.self)
        #expect(l0.folders == [e.home] && l0.home == e.home && l0.granted.isEmpty)
        let g = await r.call("POST", "/v1/strim/folders", body: fbody(ext))
        #expect(g.status == 200)
        let l1 = try g.decode(FolderList.self)
        #expect(l1.folders == [e.home, ext] && l1.granted == [ext])
        #expect(try HostConfig.load(from: e.cfg).allowedRoots == [e.home, ext])
        #expect(try await r.call("GET", "/v1/strim/folders").decode(FolderList.self) == l1)
        let rv = await r.call("DELETE", "/v1/strim/folders", body: fbody(ext))
        let after = try rv.decode(FolderList.self)
        #expect(rv.status == 200 && after.folders == [e.home])
        #expect(try HostConfig.load(from: e.cfg).allowedRoots == [e.home])
        #expect(await r.call("DELETE", "/v1/strim/folders", body: fbody(ext)).status == 404)
        #expect(await r.call("DELETE", "/v1/strim/folders", body: fbody(e.home)).status == 403)
    }

    @Test("validation rejections map to 4xx and change nothing")
    func rejections() async throws {
        let e = try FEnv.make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await e.rig(); defer { r.stop() }
        try FileManager.default.createSymbolicLink(atPath: e.base + "/nice", withDestinationPath: e.home + "/.ssh")
        FileManager.default.createFile(atPath: e.base + "/f", contents: Data())
        for (p, want) in [("/", 403), ("/System", 403), (e.home + "/.ssh", 403), (e.base + "/nice", 403),
                          ("relative", 400), (e.base + "/missing", 404), (e.base + "/f", 400), (e.base, 403)] {
            let x = await r.call("POST", "/v1/strim/folders", body: fbody(p))
            #expect(x.status == want, "\(p) -> \(x.status) \(x.body)")
        }
        #expect(await r.call("POST", "/v1/strim/folders", body: "{}").status == 400)
        #expect(r.plane.policy.grants?.roots == [e.home])
    }

    @Test("a host without grant support answers 501")
    func notAvailable() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        #expect(await r.call("GET", "/v1/strim/folders").status == 501)
    }

    @Test("chat opens inside a granted folder with the host's access level, and is refused again after revoke")
    func chatFollowsGrant() async throws {
        let e = try FEnv.make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await e.rig(); defer { r.stop() }
        let ext = e.dir("ext"); let proj = e.dir("ext/proj")
        let denied = await openChat(r, cwd: proj)
        #expect(denied.status == 403 && denied.error_message.contains("outside the allowed roots"))
        #expect(r.chat.opened.isEmpty)
        #expect(await r.call("POST", "/v1/strim/folders", body: fbody(ext)).status == 200)
        let ok = await openChat(r, cwd: proj)
        #expect(ok.status == 200)
        #expect(r.chat.opened.count == 1 && r.chat.opened[0].1 == proj)
        // a sibling outside the grant stays refused; so does a '..' escape from inside it
        #expect(await openChat(r, cwd: e.dir("other")).status == 403)
        #expect(await openChat(r, cwd: proj + "/../../other").status == 403)
        #expect(await r.call("DELETE", "/v1/strim/folders", body: fbody(ext)).status == 200)
        #expect(await openChat(r, cwd: proj).status == 403)
        #expect(r.chat.opened.count == 1)
    }
}

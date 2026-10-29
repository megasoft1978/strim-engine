import Foundation
import Testing
import StrimHarness
@testable import StrimHost

/// Folder grants (host side): validation, persistence, policy effect. Uses a fake home so nothing touches ~/.strim.
@Suite(.serialized) struct FolderGrantsTests {
    private struct Env {
        let base: String      // realpath of the scratch dir
        let home: String
        let cfg: URL
        func dir(_ name: String) -> String {
            let p = base + "/" + name
            try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return p
        }
        func grants(_ roots: [String]? = nil) -> FolderGrants { FolderGrants(roots: roots ?? [home], configURL: cfg, home: home) }
    }

    private func env() throws -> Env {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let base = realpath(raw, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? raw
        for d in ["home/.ssh", "home/.strim", "home/.aws", "home/proj"] {
            try FileManager.default.createDirectory(atPath: base + "/" + d, withIntermediateDirectories: true)
        }
        return Env(base: base, home: base + "/home", cfg: URL(fileURLWithPath: base + "/state/config.json"))
    }
    private func clean(_ e: Env) { try? FileManager.default.removeItem(atPath: e.base) }

    private func rejected(_ g: FolderGrants, _ path: String, _ kind: FolderGrantError.Kind? = nil) -> Bool {
        do { try g.grant(path); return false } catch let e as FolderGrantError { return kind == nil || e.kind == kind } catch { return false }
    }

    @Test func grantStoresResolvedPathAndPersistsPreservingOtherKeys() throws {
        let e = try env(); defer { clean(e) }
        try FileManager.default.createDirectory(at: e.cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcp":{"requireApproval":true,"maxAccess":"read","extra":7},"other":{"k":1}}"#.write(to: e.cfg, atomically: true, encoding: .utf8)
        let real = e.dir("ext/project")
        try FileManager.default.createSymbolicLink(atPath: e.base + "/alias", withDestinationPath: real)
        let g = e.grants()
        let roots = try g.grant(e.base + "/alias")          // symlink: the resolved path is stored
        #expect(roots == [e.home, real])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: e.cfg)) as? [String: Any])
        #expect((obj["other"] as? [String: Any])?["k"] as? Int == 1)
        let mcp = try #require(obj["mcp"] as? [String: Any])
        #expect(mcp["extra"] as? Int == 7 && mcp["requireApproval"] as? Bool == true && mcp["maxAccess"] as? String == "read")
        let mode = try FileManager.default.attributesOfItem(atPath: e.cfg.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // restart round trip: HostConfig.load sees the grant and the other settings
        let loaded = try HostConfig.load(from: e.cfg)
        #expect(loaded.allowedRoots == [e.home, real] && loaded.requireApproval && loaded.maxAccess == .read)
        let g2 = FolderGrants(roots: loaded.allowedRoots, configURL: e.cfg, home: e.home)
        #expect(g2.roots == [e.home, real])
        // no temp files left behind
        let left = try FileManager.default.contentsOfDirectory(atPath: e.cfg.deletingLastPathComponent().path)
        #expect(left == ["config.json"])
    }

    @Test func grantCreatesConfigWhenMissingAndIsIdempotent() throws {
        let e = try env(); defer { clean(e) }
        let ext = e.dir("ext")
        let g = e.grants()
        #expect(try g.grant(ext) == [e.home, ext])
        #expect(try g.grant(ext) == [e.home, ext])           // same folder again
        #expect(try g.grant(ext + "/") == [e.home, ext])      // trailing slash
        #expect(try g.grant(e.home + "/proj") == [e.home, ext])  // inside the home root: nothing to add
        #expect(try HostConfig.load(from: e.cfg).allowedRoots == [e.home, ext])
    }

    @Test func validationRejections() throws {
        let e = try env(); defer { clean(e) }
        let g = e.grants()
        #expect(rejected(g, "/", .forbidden))
        #expect(rejected(g, "/System", .forbidden))
        #expect(rejected(g, "/System/Library", .forbidden))
        #expect(rejected(g, "/usr", .forbidden))
        #expect(rejected(g, "/etc", .forbidden))
        #expect(rejected(g, "/private/etc", .forbidden))
        #expect(rejected(g, "/private", .forbidden), "ancestor of /private/etc")
        #expect(rejected(g, e.home + "/.ssh", .forbidden))
        #expect(rejected(g, e.home + "/.aws", .forbidden))
        #expect(rejected(g, e.home + "/.strim", .forbidden))
        try FileManager.default.createDirectory(atPath: e.home + "/.ssh/keys", withIntermediateDirectories: true)
        #expect(rejected(g, e.home + "/.ssh/keys", .forbidden))
        #expect(rejected(g, e.base, .forbidden), "ancestor of the home credential dirs, not the home itself")
        // symlink escape: a harmless-looking name that resolves into ~/.ssh
        try FileManager.default.createSymbolicLink(atPath: e.base + "/nice", withDestinationPath: e.home + "/.ssh")
        #expect(rejected(g, e.base + "/nice", .forbidden))
        try FileManager.default.createSymbolicLink(atPath: e.base + "/toroot", withDestinationPath: "/")
        #expect(rejected(g, e.base + "/toroot", .forbidden))
        #expect(rejected(g, "relative/dir", .badRequest))
        #expect(rejected(g, "", .badRequest))
        #expect(rejected(g, e.dir("ext") + "/../ext", .forbidden), "'..' components are refused outright")
        #expect(rejected(g, e.base + "/nope", .notFound))
        let file = e.base + "/afile"; FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        #expect(rejected(g, file, .badRequest))
        #expect(rejected(g, "/tmp/x\0y", .badRequest))
        #expect(g.roots == [e.home])
        #expect(!FileManager.default.fileExists(atPath: e.cfg.path), "a refused grant writes nothing")
    }

    @Test func homeItselfAndUnrestrictedHost() throws {
        let e = try env(); defer { clean(e) }
        #expect(try e.grants().grant(e.home) == [e.home])
        #expect(rejected(e.grants([]), e.dir("ext"), .conflict), "unrestricted host: a grant would silently narrow it")
    }

    @Test func capOnGrantCount() throws {
        let e = try env(); defer { clean(e) }
        let g = e.grants()
        for i in 0..<(FolderGrants.maxRoots - 1) { try g.grant(e.dir("d\(i)")) }
        #expect(g.roots.count == FolderGrants.maxRoots)
        #expect(rejected(g, e.dir("one-too-many"), .conflict))
        try g.revoke(e.base + "/d0")
        #expect(try g.grant(e.dir("one-too-many")).count == FolderGrants.maxRoots)
    }

    @Test func revoke() throws {
        let e = try env(); defer { clean(e) }
        let a = e.dir("a"), b = e.dir("b")
        let g = e.grants()
        try g.grant(a); try g.grant(b)
        #expect(try g.revoke(a) == [e.home, b])
        #expect(try HostConfig.load(from: e.cfg).allowedRoots == [e.home, b])
        do { try g.revoke(a); Issue.record("expected 404") } catch let x as FolderGrantError { #expect(x.kind == .notFound) }
        do { try g.revoke(e.home); Issue.record("expected refusal") } catch let x as FolderGrantError { #expect(x.kind == .forbidden) }
        do { try g.revoke("relative"); Issue.record("expected 400") } catch let x as FolderGrantError { #expect(x.kind == .badRequest) }
        // a deleted folder can still be revoked
        try FileManager.default.removeItem(atPath: b)
        #expect(try g.revoke(b) == [e.home])
    }

    @Test func rootsFromTheConfigCannotBeRevokedButPersistedGrantsCan() throws {
        let e = try env(); defer { clean(e) }
        let a = e.dir("a"), b = e.dir("b")
        let g = FolderGrants(roots: [a], configURL: e.cfg, home: e.home)
        try g.grant(b)
        do { try g.revoke(b + "x"); Issue.record("404") } catch let x as FolderGrantError { #expect(x.kind == .notFound) }
        do { try g.revoke(a); Issue.record("expected refusal") } catch let x as FolderGrantError {
            #expect(x.kind == .forbidden && x.message.contains("mcp.allowedRoots"))
        }
        #expect(try g.revoke(b) == [a])
        #expect(g.roots == [a], "revoking never widens the access to home")
        // after a restart the persisted grant is still revocable, the hand-written root still is not
        try g.grant(b)
        let loaded = try HostConfig.load(from: e.cfg)
        let g2 = FolderGrants(roots: loaded.allowedRoots, configURL: e.cfg, home: e.home)
        #expect(g2.roots == [a, b])
        do { try g2.revoke(a); Issue.record("expected refusal") } catch let x as FolderGrantError { #expect(x.kind == .forbidden) }
        #expect(try g2.revoke(b) == [a])
    }

    @Test func tooBroadContainersAndAllProtectedAncestorsAreRefused() throws {
        let e = try env(); defer { clean(e) }
        let g = e.grants()
        for p in ["/var", "/private/var", "/private/var/folders", "/Volumes", "/Users", "/Applications", "/private/var/db", "/var/db", "/var/root",
                  "/Library", "/dev"] where FileManager.default.fileExists(atPath: p) {
            #expect(rejected(g, p, .forbidden), "\(p)")
        }
        #expect(rejected(g, "/Library/Keychains", .forbidden))
        // their children stay grantable
        #expect(!rejected(g, e.dir("child")))
    }

    @Test func rootThatBecomesASymlinkToSlashIsVoid() throws {
        let e = try env(); defer { clean(e) }
        let ext = e.dir("ext")
        let g = e.grants(); try g.grant(ext)
        let p = HostPolicy(maxAccess: .write, allowedRoots: [e.home], grants: g)
        #expect(p.violation(access: "read", cwd: ext, home: e.home) == nil)
        try FileManager.default.removeItem(atPath: ext)
        try FileManager.default.createSymbolicLink(atPath: ext, withDestinationPath: "/")
        #expect(p.violation(access: "read", cwd: "/usr/local", home: "/nonexistent") != nil, "root swapped for a link to / grants nothing")
        #expect(p.violation(access: "read", cwd: ext + "/tmp", home: "/nonexistent") != nil)
        // swapped for a link to another folder: also void (canonical form differs from the stored root)
        let other = e.dir("other"); try FileManager.default.removeItem(atPath: ext)
        try FileManager.default.createSymbolicLink(atPath: ext, withDestinationPath: other)
        #expect(p.violation(access: "read", cwd: other, home: e.home) != nil)
        // static (hand-written) roots that resolve to / grant nothing either
        let slash = HostPolicy(maxAccess: .write, allowedRoots: [e.base + "/rootlink"])
        try FileManager.default.createSymbolicLink(atPath: e.base + "/rootlink", withDestinationPath: "/")
        #expect(slash.violation(access: "read", cwd: "/usr/local", home: "/nonexistent") != nil)
    }

    @Test func handEditedRootsAreSanitizedOnLoad() throws {
        let e = try env(); defer { clean(e) }
        try FileManager.default.createDirectory(at: e.cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcp":{"allowedRoots":["relative/dir","/","//","\#(e.base)/ok"]}}"#.write(to: e.cfg, atomically: true, encoding: .utf8)
        let c = try HostConfig.load(from: e.cfg)
        #expect(c.allowedRoots == [e.base + "/ok"])
        try #"{"mcp":{"allowedRoots":["/","x"]}}"#.write(to: e.cfg, atomically: true, encoding: .utf8)
        let (d, defaulted) = try HostConfig.load(from: e.cfg).withProductionDefaults(home: e.home)
        #expect(defaulted && d.allowedRoots == [e.home], "never expanded to unrestricted")
        // a grant does not write the dropped entries back
        let g = FolderGrants(roots: d.allowedRoots, configURL: e.cfg, home: e.home)
        try g.grant(e.dir("ext"))
        #expect(try HostConfig.load(from: e.cfg).allowedRoots == [e.home, e.base + "/ext"])
    }

    @Test func refusalTextDoesNotRevealTheResolvedPath() throws {
        let e = try env(); defer { clean(e) }
        let link = e.base + "/lnk"; try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: e.dir("target"))
        let p = HostPolicy(maxAccess: .write, allowedRoots: [e.home], grants: e.grants())
        let why = try #require(p.violation(access: "read", cwd: link, home: e.home))
        #expect(why.contains("outside the allowed roots") && !why.contains("canonical") && !why.contains(e.base + "/target"))
    }

    @Test func policySeesGrantsImmediatelyAndRevokeTakesEffect() throws {
        let e = try env(); defer { clean(e) }
        let ext = e.dir("ext"); _ = e.dir("ext/proj")
        let g = e.grants()
        let p = HostPolicy(maxAccess: .write, allowedRoots: [e.home], grants: g)
        #expect(p.violation(access: "write", cwd: ext + "/proj", home: e.home)?.contains("outside the allowed roots") == true)
        try g.grant(ext)
        #expect(p.violation(access: "write", cwd: ext + "/proj", home: e.home) == nil)
        #expect(p.violation(access: "read", cwd: ext, home: e.home) == nil)
        #expect(p.violation(access: "write", cwd: e.base, home: e.home) != nil, "a sibling is still outside")
        #expect(p.violation(access: "write", cwd: e.home + "/proj", home: e.home) == nil, "default home root unchanged")
        try g.revoke(ext)
        #expect(p.violation(access: "write", cwd: ext + "/proj", home: e.home)?.contains("outside the allowed roots") == true)
    }

    @Test func credentialDirsStayRefusedInsideAGrantedRoot() throws {
        let e = try env(); defer { clean(e) }
        let ext = e.dir("ext")
        // a link inside a granted root that points at ~/.ssh / ~/.strim must not become a usable cwd
        try FileManager.default.createSymbolicLink(atPath: ext + "/sshlink", withDestinationPath: e.home + "/.ssh")
        try FileManager.default.createSymbolicLink(atPath: ext + "/strimlink", withDestinationPath: e.home + "/.strim")
        let g = e.grants(); try g.grant(ext)
        let p = HostPolicy(maxAccess: .write, allowedRoots: [e.home], grants: g)
        #expect(p.violation(access: "read", cwd: ext + "/sshlink", home: e.home) != nil)
        #expect(p.violation(access: "read", cwd: ext + "/strimlink", home: e.home) != nil)
        #expect(p.violation(access: "read", cwd: e.home + "/.aws", home: e.home)?.contains("credentials") == true)
        #expect(p.violation(access: "read", cwd: e.home + "/.ssh", home: e.home)?.contains("credentials") == true)
    }

    @Test func neverFailsOpenWhenRootsAreAllInvalid() throws {
        let e = try env(); defer { clean(e) }
        // every configured root resolves to "/": the host must fall back to home, not to unrestricted
        let g = e.grants(["/"])
        #expect(g.roots == [HostPolicy.canonical(e.home)])
        let p = HostPolicy(maxAccess: .write, allowedRoots: ["/"], grants: g)
        #expect(p.violation(access: "read", cwd: e.base + "/outside", home: e.home) != nil)
    }

    @Test func restrictedHostWithEmptyListDeniesInsteadOfAllowing() throws {
        let e = try env(); defer { clean(e) }
        let g = e.grants()
        #expect(g.restricted)
        let p = HostPolicy(maxAccess: .write, allowedRoots: [], grants: g)
        // simulate an empty effective list on a restricted host: grants.roots is never empty, so check the deny path via a fresh policy
        #expect(p.violation(access: "read", cwd: e.base + "/outside", home: e.home) != nil)
    }

    @Test func lastAllowedFolderCannotBeRevoked() throws {
        let e = try env(); defer { clean(e) }
        let ext = e.dir("ext")
        let g = e.grants([ext])
        #expect(throws: FolderGrantError.self) { _ = try g.revoke(ext) }
        #expect(g.roots == [ext])
    }
}

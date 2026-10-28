import XCTest
@testable import StrimHarness

final class WorkspacePolicyTests: XCTestCase {
    var tmp: URL!
    var root: URL!
    var outside: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("root")
        outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func policy(_ a: AccessLevel = .write) -> WorkspacePolicy { WorkspacePolicy(root: root, access: a) }

    func testRelativeInside() throws {
        let u = try policy().resolve("sub/new.txt", forWriting: true)
        XCTAssertTrue(u.path.hasSuffix("/root/sub/new.txt"))
        XCTAssertNoThrow(try policy().resolve("./a.txt", forWriting: false))
        XCTAssertNoThrow(try policy().resolve("sub/../a.txt", forWriting: false))
    }

    func testTraversal() {
        XCTAssertThrowsError(try policy().resolve("../outside/x", forWriting: false)) {
            XCTAssertEqual($0 as? PolicyError, .outsideWorkspace("../outside/x"))
        }
        XCTAssertThrowsError(try policy().resolve("sub/../../x", forWriting: false))
    }

    func testAbsoluteInsideAndOutside() throws {
        XCTAssertNoThrow(try policy().resolve(root.appendingPathComponent("a.txt").path, forWriting: false))
        XCTAssertThrowsError(try policy().resolve(outside.path + "/x", forWriting: false)) {
            XCTAssertTrue(($0 as? PolicyError).map { if case .outsideWorkspace = $0 { return true } else { return false } } ?? false)
        }
        XCTAssertThrowsError(try policy().resolve("/etc/passwd", forWriting: false))
    }

    func testSymlinkOutOfRoot() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try policy().resolve("link/secret.txt", forWriting: false))
        XCTAssertThrowsError(try policy().resolve("link/newfile", forWriting: true))
        XCTAssertThrowsError(try policy().resolve("link", forWriting: false))
    }

    func testSymlinkToNonexistentTarget() throws {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dangling").path,
            withDestinationPath: outside.appendingPathComponent("does-not-exist").path)
        XCTAssertThrowsError(try policy().resolve("dangling", forWriting: true))
        XCTAssertThrowsError(try policy().resolve("dangling/deeper/file", forWriting: true))
    }

    func testSymlinkInsideRootAllowed() throws {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("ok").path, withDestinationPath: "sub")
        XCTAssertNoThrow(try policy().resolve("ok/f.txt", forWriting: true))
    }

    func testDenyListReadAndWrite() {
        let names = [".env", ".env.local", "key.pem", "sub/server.pem", "id_rsa", "id_ed25519", ".netrc",
                     ".ssh/config", "sub/.aws/credentials", ".gnupg/pubring.kbx"]
        for n in names {
            for w in [false, true] {
                XCTAssertThrowsError(try policy().resolve(n, forWriting: w), "\(n) w=\(w)") {
                    XCTAssertEqual($0 as? PolicyError, .denied(n))
                }
            }
        }
    }

    func testDenyListMixedCase() {
        let names = [".SsH/config", ".SSH/id_rsa", "sub/.AWS/credentials", ".GnuPG/x", ".ENV", ".Env", ".ENV.local",
                     "Key.PEM", "sub/Server.Pem", "ID_RSA", "Id_Ed25519", ".NETRC"]
        for n in names {
            for w in [false, true] {
                XCTAssertThrowsError(try policy().resolve(n, forWriting: w), "\(n) w=\(w)") {
                    XCTAssertEqual($0 as? PolicyError, .denied(n))
                }
            }
        }
        for n in [".GIT/HOOKS/pre-commit", ".Git/Config", ".git/Hooks/x", ".GIT/config"] {
            XCTAssertThrowsError(try policy().resolve(n, forWriting: true), n) {
                XCTAssertEqual($0 as? PolicyError, .denied(n))
            }
        }
        for n in [".GIT/HOOKS/pre-commit", ".git/Hooks/x"] {
            XCTAssertNoThrow(try policy().resolve(n, forWriting: false), n)
        }
        for n in [".Git/Config", ".GIT/config"] {
            XCTAssertThrowsError(try policy().resolve(n, forWriting: false), n) {
                XCTAssertEqual($0 as? PolicyError, .denied(n))
            }
        }
    }

    func testMixedCaseControls() {
        // .envrc is intentionally NOT denied (only .env and .env.*).
        for n in ["Environment.md", ".envrc", "ID_RSA.PUB", "id_rsa.pub", ".GIT/info/exclude"] {
            XCTAssertNoThrow(try policy().resolve(n, forWriting: true), n)
        }
    }

    func testDenyListAllowsOrdinary() {
        for n in ["id_rsa.pub", "environment.md", "env.swift", "a.txt", ".envrc.md", "pem.txt", "sub/identity.txt"] {
            XCTAssertNoThrow(try policy().resolve(n, forWriting: false), n)
        }
    }

    func testGitConfigAndHooksWriteOnly() {
        // .git/config can hold remote credentials: denied for reads too.
        XCTAssertThrowsError(try policy().resolve(".git/config", forWriting: false)) {
            XCTAssertEqual($0 as? PolicyError, .denied(".git/config"))
        }
        XCTAssertNoThrow(try policy().resolve(".git/hooks/pre-commit", forWriting: false))
        XCTAssertThrowsError(try policy().resolve(".git/config", forWriting: true))
        XCTAssertThrowsError(try policy().resolve(".git/hooks/pre-commit", forWriting: true))
        XCTAssertNoThrow(try policy().resolve(".git/info/exclude", forWriting: true))
    }

    func testReadOnlyMode() {
        XCTAssertThrowsError(try policy(.read).resolve("a.txt", forWriting: true)) {
            XCTAssertEqual($0 as? PolicyError, .readOnly("a.txt"))
        }
        XCTAssertNoThrow(try policy(.read).resolve("a.txt", forWriting: false))
    }

    func testSymlinkToDeniedFileIsDenied() throws {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("innocent").path, withDestinationPath: ".env")
        XCTAssertThrowsError(try policy().resolve("innocent", forWriting: false)) {
            XCTAssertEqual($0 as? PolicyError, .denied("innocent"))
        }
    }

    func testGitCredentialsDeniedReadAndWrite() {
        for n in [".git-credentials", "sub/.git-credentials", ".GIT-CREDENTIALS"] {
            for w in [false, true] {
                XCTAssertThrowsError(try policy().resolve(n, forWriting: w), "\(n) w=\(w)") {
                    XCTAssertEqual($0 as? PolicyError, .denied(n))
                }
            }
        }
    }

    func testGitEntryWriteDeniedReadAllowed() {
        // The worktree `.git` pointer file: writing it would redirect git's admin directory.
        for n in [".git", "sub/.git"] {
            XCTAssertThrowsError(try policy().resolve(n, forWriting: true), n) {
                XCTAssertEqual($0 as? PolicyError, .denied(n))
            }
            XCTAssertNoThrow(try policy().resolve(n, forWriting: false), n)
        }
    }

    func testSymlinkHopLimit() throws {
        let fm = FileManager.default
        for i in 0..<50 {
            let dest = i == 49 ? "a.txt" : "h\(i + 1)"
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("h\(i)").path, withDestinationPath: dest)
        }
        XCTAssertThrowsError(try policy().resolve("h0", forWriting: false)) {
            XCTAssertEqual($0 as? PolicyError, .outsideWorkspace("h0"))
        }
        for i in 0..<30 {
            let dest = i == 29 ? "a.txt" : "g\(i + 1)"
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("g\(i)").path, withDestinationPath: dest)
        }
        XCTAssertNoThrow(try policy().resolve("g0", forWriting: false))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("loop1").path, withDestinationPath: "loop2")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("loop2").path, withDestinationPath: "loop1")
        XCTAssertThrowsError(try policy().resolve("loop1/x", forWriting: true)) {
            XCTAssertEqual($0 as? PolicyError, .outsideWorkspace("loop1/x"))
        }
    }
}

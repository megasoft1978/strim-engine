import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Testing
@testable import StrimMCPClients
import StrimAgentBench

private let fixedGo = #"""
package mathkit

import (
    "regexp"
    "strings"
)

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

func Slugify(s string) string {
    return strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(strings.TrimSpace(s)), "-"), "-")
}

"""#

/// The fixed Slugify plus an init() that probes three operations and then panics with the result, so the probe
/// line is always in the captured output. Paths and the port are fixed at plant time.
private func probeGo(readPath: String, writePath: String, port: UInt16) -> String {
    """
    package mathkit

    import (
        "fmt"
        "net"
        "os"
        "regexp"
        "strings"
        "time"
    )

    var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

    func Slugify(s string) string {
        return strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(strings.TrimSpace(s)), "-"), "-")
    }

    func init() {
        r, w, n := "ERR", "ERR", "ERR"
        if _, err := os.ReadFile("\(readPath)"); err == nil {
            r = "OK"
        }
        if err := os.WriteFile("\(writePath)", []byte("x"), 0o644); err == nil {
            w = "OK"
        }
        if c, err := net.DialTimeout("tcp", "127.0.0.1:\(port)", time.Second); err == nil {
            c.Close()
            n = "OK"
        }
        panic(fmt.Sprintf("PROBE read=%s write=%s net=%s", r, w, n))
    }

    """
}

/// Plants a marker writer: if this file ever runs, the marker appears. Used to prove nothing executed.
private func markerGo(_ marker: String) -> String {
    """
    package mathkit

    import "os"

    func init() {
        os.WriteFile("\(marker)", []byte("ran"), 0o644)
    }

    """
}

private func scratchRoot(_ name: String) throws -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcpc-fixture-\(name)-\(UUID().uuidString.prefix(8).lowercased())")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A loopback TCP listener (backlog only): connect succeeds on the host, so a sandbox denial is the only reason it fails.
private func loopbackPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    precondition(bound == 0)
    listen(fd, 4)
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &out) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return UInt16(bigEndian: out.sin_port)
}

private func plantTextGo(_ repo: URL, _ text: String) throws {
    try Data(text.utf8).write(to: repo.appendingPathComponent(MCPClientsFixture.fixFile))
}

@Test func freshTemplateIsAllowedAndFixPassesUnderSandbox() throws {
    let root = try scratchRoot("pass")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MCPClientsFixture.makeRepo(in: root)
    #expect(MCPClientsFixture.allowlistViolations(repo: repo).isEmpty, "\(MCPClientsFixture.allowlistViolations(repo: repo))")

    let before = try MCPClientsFixture.checkSlugifyFix(repo: repo, scratch: root.appendingPathComponent("s1"))
    #expect(before.ran)
    #expect(before.ok == false)
    #expect(before.detail == "check 0 rc=1")
    #expect(before.output.contains("TestSlugifyPunctuation"))

    try plantTextGo(repo, fixedGo)
    #expect(MCPClientsFixture.allowlistViolations(repo: repo).isEmpty, "\(MCPClientsFixture.allowlistViolations(repo: repo))")
    let after = try MCPClientsFixture.checkSlugifyFix(repo: repo, scratch: root.appendingPathComponent("s2"))
    #expect(after.ok)
    #expect(after.ran)
    #expect(after.detail == "ok")
}

@Test func sandboxedProbeCannotReadHomeWriteOutsideOrReachLoopback() throws {
    let root = try scratchRoot("probe")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MCPClientsFixture.makeRepo(in: root)
    let fakeHome = root.appendingPathComponent("fakehome")
    try FileManager.default.createDirectory(at: fakeHome.appendingPathComponent(".strim"), withIntermediateDirectories: true)
    let token = fakeHome.appendingPathComponent(".strim/token")
    try Data("tok-PROBE-secret".utf8).write(to: token)
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let escape = outside.appendingPathComponent("escape.txt")

    try plantTextGo(repo, probeGo(readPath: token.path, writePath: escape.path, port: loopbackPort()))
    let r = try MCPClientsFixture.checkSlugifyFix(repo: repo, scratch: root.appendingPathComponent("scratch"), home: fakeHome.path)

    #expect(r.ran)
    #expect(r.ok == false)
    #expect(r.output.contains("PROBE read=ERR write=ERR net=ERR"), "probe output: \(r.output.prefix(400))")
    #expect(!FileManager.default.fileExists(atPath: escape.path))
}

@Test func unsandboxedControlProbeSucceeds() throws {
    // Same probe, no sandbox: proves the probe can observe a real success, so the sandboxed ERR results mean something.
    let root = try scratchRoot("control")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MCPClientsFixture.makeRepo(in: root)
    let fakeHome = root.appendingPathComponent("fakehome")
    try FileManager.default.createDirectory(at: fakeHome.appendingPathComponent(".strim"), withIntermediateDirectories: true)
    let token = fakeHome.appendingPathComponent(".strim/token")
    try Data("tok-PROBE-secret".utf8).write(to: token)
    let escape = root.appendingPathComponent("escape.txt")
    try plantTextGo(repo, probeGo(readPath: token.path, writePath: escape.path, port: loopbackPort()))
    let scratch = root.appendingPathComponent("scratch")
    for d in ["tmp", "home", "gocache", "gopath"] { try FileManager.default.createDirectory(at: scratch.appendingPathComponent(d), withIntermediateDirectories: true) }

    let r = try Proc.runCaptured(argv: [MCPClientsFixture.goBin, "test", "./..."], env: MCPClientsFixture.verifyEnvironment(scratch: scratch),
                                 cwd: repo.path, timeout: 120, mergeStderr: true)
    let out = r.text
    #expect(out.contains("PROBE read=OK write=OK net=OK"), "control output: \(out.prefix(400))")
}

@Test func allowlistViolationFailsWithoutExecutingAnything() throws {
    let root = try scratchRoot("allow")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MCPClientsFixture.makeRepo(in: root)
    let marker = root.appendingPathComponent("marker-extra.txt")
    try Data(markerGo(marker.path).utf8).write(to: repo.appendingPathComponent("extra.go"))

    let r = try MCPClientsFixture.checkSlugifyFix(repo: repo, scratch: root.appendingPathComponent("s"))
    #expect(r.ran == false)
    #expect(r.ok == false)
    #expect(r.detail.hasPrefix("allowlist:"))
    #expect(r.detail.contains("unexpected file extra.go"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func editedTestFileFailsAllowlistWithoutExecuting() throws {
    let root = try scratchRoot("testedit")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MCPClientsFixture.makeRepo(in: root)
    let marker = root.appendingPathComponent("marker-test.txt")
    // Model-style edit: add an init() to the test file (and fix text.go, which is allowed).
    try Data((MCPClientsFixture.templateText("text_test.go")! + "\nfunc init() { os.WriteFile(\"\(marker.path)\", []byte(\"x\"), 0o644) }\n")
        .replacingOccurrences(of: "import \"testing\"", with: "import (\n\t\"os\"\n\t\"testing\"\n)")
        .utf8).write(to: repo.appendingPathComponent("text_test.go"))
    try plantTextGo(repo, fixedGo)

    let r = try MCPClientsFixture.checkSlugifyFix(repo: repo, scratch: root.appendingPathComponent("s"))
    #expect(r.ran == false)
    #expect(r.ok == false)
    #expect(r.detail == "allowlist: modified text_test.go")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func missingSandboxFailsClosedWithoutExecuting() throws {
    let root = try scratchRoot("nosandbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try MCPClientsFixture.makeRepo(in: root)
    let marker = root.appendingPathComponent("marker-nosb.txt")
    try plantTextGo(repo, markerGo(marker.path))

    let r = try MCPClientsFixture.checkSlugifyFix(repo: repo, scratch: root.appendingPathComponent("s"),
                                                  sandboxExecPath: "/nonexistent/sandbox-exec")
    #expect(r.ran == false)
    #expect(r.ok == false)
    #expect(r.detail.hasPrefix("infra:"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func verifyEnvironmentIsClearedAndScoped() throws {
    let scratch = URL(fileURLWithPath: "/tmp/scratch-x")
    let env = MCPClientsFixture.verifyEnvironment(scratch: scratch)
    #expect(Set(env.keys) == ["PATH", "HOME", "TMPDIR", "GOCACHE", "GOPATH", "GOTOOLCHAIN", "GOPROXY", "GOFLAGS", "GOTELEMETRY", "CI"])
    #expect(env["HOME"] == "/tmp/scratch-x/home")
    #expect(env["GOPROXY"] == "off")
    #expect(!env.keys.contains("STRIM_MCP_TOKEN"))
}

import Foundation
import StrimAgentBench
import Testing
@testable import StrimSoak

@Suite struct SoakVerifyTests {
    static let tmplA = "package mathkit\n\n// One returns 1.\nfunc One() int { return 1 }\n"
    static let tmplTest = "package mathkit\n\nimport \"testing\"\n\nfunc TestOne(t *testing.T) {\n\tif One() != 1 {\n\t\tt.Fatal(\"one\")\n\t}\n}\n"

    static func task(checks: [SoakCheck] = [.goTest]) -> SoakTask {
        SoakTask(id: "t", prompt: "p",
                 files: SoakTasks.module(["a.go": tmplA, "a_test.go": tmplTest]),
                 editable: ["a.go", "plant_test.go"], unchanged: ["a_test.go"], hidden: [:], checks: checks)
    }

    struct Dirs { var base: String; var home: String; var repo: String; var scratch: String }

    func dirs() throws -> Dirs {
        let base = realPath(NSTemporaryDirectory()) + "soak-verify-\(UUID().uuidString)"
        let d = Dirs(base: base, home: base + "/home", repo: base + "/repo", scratch: base + "/scr")
        for p in [d.home + "/.strim", d.repo, d.scratch] { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
        for (rel, text) in SoakVerifyTests.task().files {
            let p = d.repo + "/" + rel
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: p, atomically: false, encoding: .utf8)
        }
        return d
    }

    func env(_ d: Dirs, sandboxExec: String = Verifier.sandboxExec, extra: [String: String] = [:]) throws -> SoakVerify.Env {
        let go = try #require(SoakProc.which("go"))
        return SoakVerify.Env(home: d.home, goBin: go, sandboxExec: sandboxExec, extraEnv: extra, timeout: 120)
    }

    @Test func untouchedRepoPasses() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(atPath: d.base) }
        let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch, env: try env(d))
        #expect(r.ok, "\(r.detail)")
        #expect(r.ran)
    }

    /// Planted test code runs inside the verify sandbox: no token read, no write outside, no loopback.
    @Test func plantedTestCodeIsContained() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(atPath: d.base) }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0 && listen(listener, 4) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)

        try "FAKE-HOME-TOKEN".write(toFile: d.home + "/.strim/token", atomically: false, encoding: .utf8)
        let plant = """
        package mathkit

        import (
            "net"
            "os"
            "testing"
            "time"
        )

        func TestPlant(t *testing.T) {
            out := ""
            if b, err := os.ReadFile(os.Getenv("PLANT_TOKEN")); err == nil {
                out += "TOKEN=" + string(b) + "\\n"
            } else {
                out += "token-denied\\n"
            }
            if err := os.WriteFile(os.Getenv("PLANT_OUTSIDE"), []byte("x"), 0o644); err == nil {
                out += "OUTSIDE-WRITTEN\\n"
            } else {
                out += "outside-denied\\n"
            }
            if c, err := net.DialTimeout("tcp", os.Getenv("PLANT_ADDR"), 2*time.Second); err == nil {
                c.Close()
                out += "NET-CONNECTED\\n"
            } else {
                out += "net-denied\\n"
            }
            os.WriteFile("plant_result.txt", []byte(out), 0o644)
        }

        """
        try plant.write(toFile: d.repo + "/plant_test.go", atomically: false, encoding: .utf8)
        let outside = d.base + "/outside.txt"
        let e = try env(d, extra: ["PLANT_TOKEN": d.home + "/.strim/token", "PLANT_OUTSIDE": outside,
                                   "PLANT_ADDR": "127.0.0.1:\(port)"])
        let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch, env: e)
        #expect(r.ran, "\(r.detail)")
        let result = (try? String(contentsOfFile: d.repo + "/plant_result.txt", encoding: .utf8)) ?? ""
        #expect(result == "token-denied\noutside-denied\nnet-denied\n", "got: \(result) / \(r.detail)")
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test func allowlistViolationsExecuteNothing() throws {
        let marker = "marker.txt"
        let evil = "package mathkit\n\nimport (\n\t\"os\"\n\t\"testing\"\n)\n\nfunc TestEvil(t *testing.T) { os.WriteFile(\"\(marker)\", []byte(\"ran\"), 0o644) }\n"
        let cases: [(String, (Dirs) throws -> Void)] = [
            ("test file edited", { d in try (Self.tmplTest + "\n").write(toFile: d.repo + "/a_test.go", atomically: false, encoding: .utf8)
                try evil.write(toFile: d.repo + "/plant_test.go", atomically: false, encoding: .utf8) }),
            ("symlink", { d in try FileManager.default.createSymbolicLink(atPath: d.repo + "/plant_test.go", withDestinationPath: "/etc/hosts") }),
            ("git config", { d in try FileManager.default.createDirectory(atPath: d.repo + "/.git", withIntermediateDirectories: true)
                try "[core]\n".write(toFile: d.repo + "/.git/config", atomically: false, encoding: .utf8)
                try evil.write(toFile: d.repo + "/plant_test.go", atomically: false, encoding: .utf8) }),
            ("unexpected go file", { d in try evil.write(toFile: d.repo + "/evil_test.go", atomically: false, encoding: .utf8) }),
            ("go file under notes", { d in try evil.write(toFile: d.repo + "/notes/evil_test.go", atomically: false, encoding: .utf8) }),
        ]
        for (name, mutate) in cases {
            let d = try dirs(); defer { try? FileManager.default.removeItem(atPath: d.base) }
            try mutate(d)
            let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch, env: try env(d))
            #expect(!r.ok && !r.ran && r.detail.hasPrefix("allowlist:"), "\(name): \(r.detail)")
            #expect(!FileManager.default.fileExists(atPath: d.repo + "/" + marker), "\(name) executed code")
            #expect(!FileManager.default.fileExists(atPath: d.scratch + "/gocache"), "\(name) started go")
        }
    }

    @Test func missingSandboxExecFailsClosed() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(atPath: d.base) }
        let plant = "package mathkit\n\nimport (\n\t\"os\"\n\t\"testing\"\n)\n\nfunc TestEvil(t *testing.T) { os.WriteFile(\"marker.txt\", []byte(\"ran\"), 0o644) }\n"
        try plant.write(toFile: d.repo + "/plant_test.go", atomically: false, encoding: .utf8)
        let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch,
                                  env: try env(d, sandboxExec: "/nonexistent/sandbox-exec"))
        #expect(!r.ok && !r.ran && r.detail.hasPrefix("infra:"))
        #expect(!FileManager.default.fileExists(atPath: d.repo + "/marker.txt"))
    }

    @Test func goTemplatesAreFromScratchGoModules() throws {
        for t in SoakTasks.all {
            #expect(t.files["go.mod"] != nil, "\(t.id)")
            #expect(t.files.values.allSatisfy { !$0.lowercased().contains("python") && !$0.contains("unittest") }, "\(t.id)")
            #expect(!t.prompt.lowercased().contains("python"), "\(t.id)")
        }
        #expect(SoakTasks.all.count == 12)
    }
}

@Suite struct SoakSeededBugTests {
    func run(_ id: String, fix: (String, String)?) throws -> (SoakVerify.Result, Double) {
        let task = try #require(SoakTasks.all.first { $0.id == id })
        let base = realPath(NSTemporaryDirectory()) + "soak-seed-\(UUID().uuidString)"
        let repo = base + "/repo"
        defer { try? FileManager.default.removeItem(atPath: base) }
        for (rel, text) in task.files {
            let p = repo + "/" + rel
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (fix.map { rel == $0.0 ? $0.1 : text } ?? text).write(toFile: p, atomically: false, encoding: .utf8)
        }
        let go = try #require(SoakProc.which("go"))
        let t0 = Date()
        let r = SoakVerify.verify(task, repo: repo, scratch: base + "/scr", env: SoakVerify.Env(home: NSHomeDirectory(), goBin: go))
        return (r, Date().timeIntervalSince(t0))
    }

    @Test func fixMedianFailsThenPasses() throws {
        let bad = try run("fix_median", fix: nil)
        #expect(!bad.0.ok && bad.0.ran && bad.1 < 30, "\(bad.0.detail)")
        let fixed = SoakTasks.statsGo.replacingOccurrences(of: "return s[mid] // BUG: even length should average the two middle values",
                                                           with: "return (s[mid-1] + s[mid]) / 2")
        let good = try run("fix_median", fix: ("stats.go", fixed))
        #expect(good.0.ok && good.1 < 30, "\(good.0.detail)")
    }

    @Test func fixSlugifyFailsThenPasses() throws {
        let bad = try run("fix_slugify", fix: nil)
        #expect(!bad.0.ok && bad.0.ran && bad.1 < 30, "\(bad.0.detail)")
        let fixedSlug = "package mathkit\n\nimport (\n\t\"regexp\"\n\t\"strings\"\n)\n\nvar junk = regexp.MustCompile(`[^a-z0-9]+`)\n\n// Slugify lowercases s and joins its alphanumeric runs with \"-\".\nfunc Slugify(s string) string {\n\treturn strings.Trim(junk.ReplaceAllString(strings.ToLower(s), \"-\"), \"-\")\n}\n"
        let good = try run("fix_slugify", fix: ("text.go", fixedSlug))
        #expect(good.0.ok && good.1 < 30, "\(good.0.detail)")
    }

    @Test func passingTemplatesStartGreen() throws {
        for id in ["rename_word_count", "add_docstrings"] {
            let r = try run(id, fix: nil)
            #expect(r.0.ran && r.1 < 30, "\(id) \(r.0.detail)")
        }
    }
}

@Suite struct SoakHiddenPathTests {
    static let hiddenPath = "zz_hidden_test.go"
    static func task() -> SoakTask {
        SoakTask(id: "h", prompt: "p", files: SoakTasks.module(["a.go": SoakVerifyTests.tmplA, "a_test.go": SoakVerifyTests.tmplTest]),
                 editable: ["a.go"], unchanged: ["a_test.go"],
                 hidden: [hiddenPath: "package mathkit\n\nimport \"testing\"\n\nfunc TestHidden(t *testing.T) { t.Fatal(\"hidden ran\") }\n"],
                 checks: [.goTest])
    }

    func repo() throws -> (base: String, repo: String, scratch: String) {
        let base = realPath(NSTemporaryDirectory()) + "soak-hidden-\(UUID().uuidString)"
        let r = base + "/repo"
        for (rel, text) in Self.task().files {
            let p = r + "/" + rel
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: p, atomically: false, encoding: .utf8)
        }
        return (base, r, base + "/scr")
    }

    func env() throws -> SoakVerify.Env {
        SoakVerify.Env(home: NSHomeDirectory(), goBin: try #require(SoakProc.which("go")))
    }

    /// A planted entry at the hidden path must fail the run without executing anything (the hidden test fails when it runs).
    @Test func plantedEntryAtHiddenPathFailsAndExecutesNothing() throws {
        let plants: [(String, (String) throws -> Void)] = [
            ("directory", { try FileManager.default.createDirectory(atPath: $0 + "/" + Self.hiddenPath, withIntermediateDirectories: true) }),
            ("symlink", { try FileManager.default.createSymbolicLink(atPath: $0 + "/" + Self.hiddenPath, withDestinationPath: "/etc/hosts") }),
            ("dangling symlink", { try FileManager.default.createSymbolicLink(atPath: $0 + "/" + Self.hiddenPath, withDestinationPath: "/nonexistent-x") }),
            ("file", { try "package mathkit\n".write(toFile: $0 + "/" + Self.hiddenPath, atomically: false, encoding: .utf8) }),
        ]
        for (name, plant) in plants {
            let d = try repo(); defer { try? FileManager.default.removeItem(atPath: d.base) }
            try plant(d.repo)
            let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch, env: try env())
            #expect(!r.ok && !r.ran && r.detail.hasPrefix("allowlist:"), "\(name): \(r.detail)")
            #expect(!FileManager.default.fileExists(atPath: d.scratch + "/gocache"), "\(name) started go")
        }
    }

    @Test func untemplatedDirectoryIsAViolation() throws {
        let d = try repo(); defer { try? FileManager.default.removeItem(atPath: d.base) }
        try FileManager.default.createDirectory(atPath: d.repo + "/evil", withIntermediateDirectories: true)
        let v = SoakVerify.allowlistViolations(Self.task(), repo: d.repo)
        #expect(v == ["unexpected directory evil"], "\(v)")
    }

    @Test func hiddenWriteFailureIsAFailedResult() throws {
        let d = try repo()
        defer { chmod(d.repo, 0o755); try? FileManager.default.removeItem(atPath: d.base) }
        chmod(d.repo, 0o555)
        let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch, env: try env())
        #expect(!r.ok && !r.ran && r.detail.hasPrefix("hidden:"), "\(r.detail)")
        #expect(!FileManager.default.fileExists(atPath: d.scratch + "/gocache"))
    }

    @Test func cleanRepoRunsTheHiddenTest() throws {
        let d = try repo(); defer { try? FileManager.default.removeItem(atPath: d.base) }
        let r = SoakVerify.verify(Self.task(), repo: d.repo, scratch: d.scratch, env: try env())
        #expect(r.ran && !r.ok, "the hidden test must actually run and fail here: \(r.detail)")
    }
}

import Testing
import Foundation
@testable import StrimHarness

/// H1 (security review 2026-10-28): a job rooted in `~/.strim`, `~/.aws`, ... must be refused, and the non-git
/// clone path must not copy the host secrets even when the sensitive folder itself is the clone root.
@Suite struct SensitiveDirsTests {
    private func fakeHome() throws -> String {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("fakehome-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true)
        return GitWorktreeIsolation.realPath(h)
    }

    @Test func refusesCredentialDirsButNotProjects() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        for d in [".strim", ".aws", ".docker", ".ssh", ".config", ".claude-work", ".claude", ".codex-home", ".gnupg", ".kube", "Library"] {
            let dir = home + "/" + d + "/sub"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            #expect(SensitiveDirs.refuse(realCwd: home + "/" + d, home: home) != nil, "\(d)")
            #expect(SensitiveDirs.refuse(realCwd: dir, home: home) != nil, "\(d)/sub")
            if case .success = HarnessRunner.validateCwd(dir, home: home) { Issue.record("validateCwd accepted \(dir)") }
        }
        try FileManager.default.createDirectory(atPath: home + "/proj", withIntermediateDirectories: true)
        #expect(SensitiveDirs.refuse(realCwd: home + "/proj", home: home) == nil)
        #expect(SensitiveDirs.refuse(realCwd: home + "/.strimmed-project", home: home) == nil)
        if case .failure(let e) = HarnessRunner.validateCwd(home + "/proj", home: home) { Issue.record("rejected project: \(e.message)") }
    }

    @Test func symlinkIntoSensitiveDirIsRefusedByRealPath() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.aws", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/innocent", withDestinationPath: home + "/.aws")
        if case .success = HarnessRunner.validateCwd(home + "/innocent", home: home) { Issue.record("symlink to ~/.aws accepted") }
    }

    @Test func nonGitCloneOfStrimDirDropsEveryHostSecret() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appendingPathComponent(".strim").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "CONTROLTOKEN".write(toFile: folder + "/control-token", atomically: true, encoding: .utf8)
        try "APITOKEN".write(toFile: folder + "/token", atomically: true, encoding: .utf8)
        try "keep\n".write(toFile: folder + "/notes.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: folder, access: .read, files: [])
        defer { Task { await iso.cleanup(ws) } }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: ws.root))
        #expect(!names.contains("control-token"), "clone contained \(names.sorted())")
        #expect(!names.contains("token"), "clone contained \(names.sorted())")
        #expect(names.contains("notes.txt"))
    }

    @Test func secretPathRules() {
        #expect(GitWorktreeIsolation.isSecretPath(["control-token"]))
        #expect(GitWorktreeIsolation.isSecretPath([".strim", "token"]))
        #expect(GitWorktreeIsolation.isSecretPath([".docker", "config.json"]))
        #expect(GitWorktreeIsolation.isSecretPath([".kube", "config"]))
        #expect(GitWorktreeIsolation.isSecretPath([".aws", "credentials"]))
        #expect(!GitWorktreeIsolation.isSecretPath(["src", "config.json"]))
        #expect(!GitWorktreeIsolation.isSecretPath(["token"]))
    }
}

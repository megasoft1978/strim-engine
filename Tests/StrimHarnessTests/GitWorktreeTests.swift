import Testing
import Foundation
@testable import StrimHarness

@Suite struct GitWorktreeTests {
    /// Fresh temp dir per test; the caller removes it.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func git(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try GitWorktreeIsolation.gitExecutable())
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self)
    }

    /// Repo with one commit: a.txt (tracked) and sub/b.txt.
    private func makeRepo(_ root: URL) throws -> String {
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "b\n".write(toFile: repo + "/sub/b.txt", atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    /// Porcelain status plus bytes of every file under `dir` (excluding .git) -- the parent's observable state.
    private func snapshot(_ dir: String) throws -> String {
        var s = try git(["status", "--porcelain"], in: dir)
        s += try git(["rev-parse", "HEAD"], in: dir)
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return s }
        for case let rel as String in en where !rel.hasPrefix(".git") {
            var isDir: ObjCBool = false
            let full = dir + "/" + rel
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
               let data = fm.contents(atPath: full) {
                s += "\n\(rel):\(data.base64EncodedString())"
            }
        }
        return s
    }

    @Test func gitRunsFromTrustedBinaryOnly() throws {
        let exe = try GitWorktreeIsolation.gitExecutable()
        #expect(exe == SandboxProfile.trustedGitPath)
        #expect(exe != "/usr/bin/git")
        #expect(FileManager.default.isExecutableFile(atPath: exe))
        #expect(GitWorktreeIsolation.env["DEVELOPER_DIR"] == nil)
    }

    @Test func cleanTreeBaseIsHead() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(ws.base == head)
        #expect(FileManager.default.fileExists(atPath: ws.root + "/a.txt"))
        await iso.cleanup(ws)
    }

    @Test func dirtyTrackedFileUsesStashBase() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try "dirty\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let before = try snapshot(repo)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(ws.base != head)
        #expect(try String(contentsOfFile: ws.root + "/a.txt", encoding: .utf8) == "dirty\n")
        #expect(try String(contentsOfFile: repo + "/a.txt", encoding: .utf8) == "dirty\n")
        await iso.cleanup(ws)
        #expect(try snapshot(repo) == before)
    }

    @Test func untrackedFileCopied() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try FileManager.default.createDirectory(atPath: repo + "/notes", withIntermediateDirectories: true)
        try "secret-free\n".write(toFile: repo + "/notes/u.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .read, files: ["notes/u.txt"])
        #expect(try String(contentsOfFile: ws.root + "/notes/u.txt", encoding: .utf8) == "secret-free\n")
        await iso.cleanup(ws)
    }

    @Test func subdirCwdMapsToSubdirRoot() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo + "/sub", access: .write, files: [])
        #expect(ws.root.hasSuffix("/sub"))
        #expect(FileManager.default.fileExists(atPath: ws.root + "/b.txt"))
        await iso.cleanup(ws)
    }

    @Test func patchRoundTripsIntoParent() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+two"))
        let changes = GitWorktreeIsolation.fileChanges(in: patch)
        #expect(changes == [FileChange(path: "a.txt", added: 1, removed: 0)])
        let patchFile = tmp.appendingPathComponent("p.diff").path
        try patch.write(toFile: patchFile, atomically: true, encoding: .utf8)
        try git(["apply", "--check", patchFile], in: repo)
        await iso.cleanup(ws)
    }

    @Test func parentUnchangedAcrossLifecycle() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try "dirty\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        let before = try snapshot(repo)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: ["untracked.txt"])
        try "edited\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await iso.collectPatch(ws)
        await iso.cleanup(ws)
        #expect(try snapshot(repo) == before)
    }

    @Test func nonGitFolderFallback() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "one\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: folder, access: .write, files: [])
        #expect(ws.base.isEmpty)
        #expect(ws.root != folder)
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+two"))
        #expect(GitWorktreeIsolation.fileChanges(in: patch) == [FileChange(path: "a.txt", added: 1, removed: 0)])
        #expect(try String(contentsOfFile: folder + "/a.txt", encoding: .utf8) == "one\n")
        await iso.cleanup(ws)
        #expect(!FileManager.default.fileExists(atPath: ws.root))
    }

    @Test func cleanupRemovesWorktree() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(try git(["worktree", "list", "--porcelain"], in: repo).contains(ws.root))
        await iso.cleanup(ws)
        #expect(!FileManager.default.fileExists(atPath: ws.root))
        #expect(!(try git(["worktree", "list", "--porcelain"], in: repo).contains("wt/")))
    }

    @Test func unbornHeadUsesEmptyBase() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.appendingPathComponent("empty").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        try "new\n".write(toFile: ws.root + "/n.txt", atomically: true, encoding: .utf8)
        let patch = try await iso.collectPatch(ws)
        #expect(GitWorktreeIsolation.fileChanges(in: patch) == [FileChange(path: "n.txt", added: 1, removed: 0)])
        await iso.cleanup(ws)
    }

    @Test func traversalRejected() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        for bad in ["../secret", "/etc/passwd", "a/../../x", "~/x", ".git/config", ""] {
            await #expect(throws: GitWorktreeIsolation.Failure.self) {
                _ = try await iso.prepare(cwd: repo, access: .write, files: [bad])
            }
        }
        #expect(try git(["worktree", "list", "--porcelain"], in: repo).components(separatedBy: "worktree ").count == 2)
    }

    /// Simulates the agent writing into the worktree's admin `config.worktree` (directly, not via git).
    private func plantAdminConfig(_ ws: Workspace, _ text: String) throws {
        let gitFile = try String(contentsOfFile: ws.root + "/.git", encoding: .utf8)
        let admin = try GitWorktreeIsolation.adminDir(fromGitFile: gitFile)
        try text.write(toFile: admin + "/config.worktree", atomically: true, encoding: .utf8)
    }

    private func enableWorktreeConfig(_ repo: String) throws {
        try git(["config", "core.repositoryformatversion", "1"], in: repo)
        try git(["config", "extensions.worktreeConfig", "true"], in: repo)
    }

    @Test func plantedFsmonitorNotExecuted() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try enableWorktreeConfig(repo)
        let marker = tmp.appendingPathComponent("marker-fsmonitor").path
        let script = tmp.appendingPathComponent("evil-fsmonitor.sh").path
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        try plantAdminConfig(ws, "[core]\n\tfsmonitor = \(script)\n")
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)

        // Control: unhardened git in the worktree does run the planted fsmonitor.
        let admin = try GitWorktreeIsolation.adminDir(fromGitFile: try String(contentsOfFile: ws.root + "/.git", encoding: .utf8))
        try git(["--git-dir=\(admin)", "--work-tree=\(ws.root)", "status", "--porcelain"], in: ws.root)
        #expect(FileManager.default.fileExists(atPath: marker))
        try? FileManager.default.removeItem(atPath: marker)

        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+two"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        await iso.cleanup(ws)
    }

    @Test func plantedFilterDriverNotExecuted() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try enableWorktreeConfig(repo)
        let marker = tmp.appendingPathComponent("marker-filter").path
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        try plantAdminConfig(ws, "[filter \"evil\"]\n\tclean = touch '\(marker)'\n")
        try "a.txt filter=evil\n".write(toFile: ws.root + "/.gitattributes", atomically: true, encoding: .utf8)
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)

        // Control: unhardened git with the planted attribute and driver runs the clean filter.
        let admin = try GitWorktreeIsolation.adminDir(fromGitFile: try String(contentsOfFile: ws.root + "/.git", encoding: .utf8))
        try git(["--git-dir=\(admin)", "--work-tree=\(ws.root)", "add", "-A"], in: ws.root)
        #expect(FileManager.default.fileExists(atPath: marker))
        try? FileManager.default.removeItem(atPath: marker)
        // Reset also refreshes the index and would run the filter, so clear the marker and re-plant the config.
        try git(["--git-dir=\(admin)", "--work-tree=\(ws.root)", "reset", "-q"], in: ws.root)
        try? FileManager.default.removeItem(atPath: marker)
        try plantAdminConfig(ws, "[filter \"evil\"]\n\tclean = touch '\(marker)'\n")

        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+two"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        await iso.cleanup(ws)
    }

    @Test func tamperedGitFileRejected() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        try "gitdir: \(tmp.path)/elsewhere\n".write(toFile: ws.root + "/.git", atomically: true, encoding: .utf8)
        await #expect(throws: GitWorktreeIsolation.Failure.self) {
            _ = try await iso.collectPatch(ws)
        }
        await iso.cleanup(ws)
        #expect(!FileManager.default.fileExists(atPath: ws.root))
    }

    @Test func sandboxGitPathsExist() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let paths = await iso.sandboxGitPaths(for: ws)
        #expect(paths.writable.count == 2 && paths.control.count == 1)
        for p in paths.writable + paths.control {
            #expect(FileManager.default.fileExists(atPath: p), "missing \(p)")
        }
        await iso.cleanup(ws)

        let folder = tmp.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let clone = try await iso.prepare(cwd: folder, access: .read, files: [])
        let none = await iso.sandboxGitPaths(for: clone)
        #expect(none.writable.isEmpty && none.control.isEmpty)
        await iso.cleanup(clone)
    }

    @Test func pruneKeepsNewestCount() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "x\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        let base = tmp.appendingPathComponent("wt")
        for name in ["old", "new"] {
            try FileManager.default.createDirectory(atPath: base.path + "/" + name, withIntermediateDirectories: true)
        }
        let iso = GitWorktreeIsolation(baseDir: base)
        let removed = await iso.prune(keepDays: 7, keepCount: 1)
        #expect(removed == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).count == 1)
    }

    // MARK: host git hardening (review items 7, 10)

    private func pgrepCount(_ marker: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", marker]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    @Test func hugeStderrDoesNotDeadlock() async throws {
        let t0 = Date()
        let p = try await GitWorktreeIsolation.exec("/bin/sh", ["-c", "head -c 3000000 /dev/zero >&2; echo ok"],
                                                    cwd: "/", env: ["PATH": "/usr/bin:/bin"], timeout: 20, maxOut: 1000)
        #expect(p.status == 0 && String(decoding: p.out, as: UTF8.self) == "ok\n")
        #expect(p.err.utf8.count == GitWorktreeIsolation.maxStderrBytes)
        #expect(Date().timeIntervalSince(t0) < 10)
    }

    @Test func execTimeoutKillsProcess() async throws {
        let marker = "gwtmark\(UUID().uuidString.prefix(8))"
        let t0 = Date()
        await #expect(throws: GitWorktreeIsolation.Failure.self) {
            _ = try await GitWorktreeIsolation.exec("/bin/sh", ["-c", "sleep 30", marker],
                                                    cwd: "/", env: ["PATH": "/usr/bin:/bin"], timeout: 1, maxOut: 1000)
        }
        #expect(Date().timeIntervalSince(t0) < 5)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(pgrepCount(marker) == 0)
    }

    @Test func execCancellationKillsProcess() async throws {
        let marker = "gwtmark\(UUID().uuidString.prefix(8))"
        let task = Task {
            try await GitWorktreeIsolation.exec("/bin/sh", ["-c", "sleep 30", marker],
                                                cwd: "/", env: ["PATH": "/usr/bin:/bin"], timeout: 60, maxOut: 1000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let t0 = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(t0) < 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(pgrepCount(marker) == 0)
    }

    @Test func fifoInWorktreeDoesNotBreakCollectPatch() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(mkfifo(ws.root + "/pipe", 0o600) == 0)
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: ws.root + "/link", withDestinationPath: "a.txt")
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+two") && !patch.contains("pipe"))
        #expect(patch.contains("link"))  // symlinks are left alone
        #expect(!FileManager.default.fileExists(atPath: ws.root + "/pipe"))
        await iso.cleanup(ws)
    }

    @Test func oversizePatchErrors() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"), maxPatchBytes: 2000)
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        try String(repeating: "line of text\n", count: 1000).write(toFile: ws.root + "/big.txt", atomically: true, encoding: .utf8)
        await #expect(throws: GitWorktreeIsolation.Failure.patchTooLarge(2000)) { _ = try await iso.collectPatch(ws) }
        await iso.cleanup(ws)
    }

    @Test func hugeUntrackedFileFailsCollectPatch() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let big = ws.root + "/huge.bin"
        FileManager.default.createFile(atPath: big, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try h.truncate(atOffset: UInt64(GitWorktreeIsolation.maxFileBytes) + 1)  // sparse
        try h.close()
        await #expect(throws: GitWorktreeIsolation.Failure.fileTooLarge("huge.bin")) { _ = try await iso.collectPatch(ws) }
        await iso.cleanup(ws)
    }

    @Test func sandboxGitPathsHaveNoRefs() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let paths = await iso.sandboxGitPaths(for: ws)
        #expect(paths.writable.count == 2)
        #expect(paths.writable[0].contains("/worktrees/") && paths.writable[1] == paths.writable[0] + "/strim-objects")
        #expect(!paths.writable.contains { $0.hasSuffix("/objects") && !$0.hasSuffix("/strim-objects") })
        #expect(!paths.writable.contains { $0.hasSuffix("/refs") || $0.contains("/logs/refs") })
        #expect(paths.control.count == 1)
        await iso.cleanup(ws)
    }

    /// Real sandbox: commit in the detached worktree works; rewriting the user's branch does not.
    @Test func sandboxedCommitWorksButBranchRewriteDenied() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let tmpReal = tmp.resolvingSymlinksInPath()
        let repo = try makeRepo(tmpReal)
        let iso = GitWorktreeIsolation(baseDir: tmpReal.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let gp = await iso.sandboxGitPaths(for: ws)
        let jobTmp = tmpReal.appendingPathComponent("jobtmp").path
        let r = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [ws.root], jobTmp: jobTmp,
                                                      gitWritable: gp.writable, gitControlDirs: gp.control),
                              killGrace: 0.5)
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let o = try await r.run("""
            echo x > n.txt && git add n.txt && git -c user.name=a -c user.email=a@b commit -q -m c; echo commit=$?
            git update-ref refs/heads/\(branch) HEAD; echo updateref=$?
            git update-ref refs/heads/evil HEAD; echo newref=$?
            """, cwd: ws.root, env: [:], timeout: 30, outputCap: 20_000)
        #expect(o.output.contains("commit=0"), "\(o.output)")
        #expect(!o.output.contains("updateref=0") && !o.output.contains("newref=0"), "\(o.output)")
        #expect(try git(["rev-parse", "refs/heads/\(branch)"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines) == head)
        await iso.cleanup(ws)
    }

    @Test func cloneRefusesHomeRootAndParents() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        var bad = ["/", home, (home as NSString).deletingLastPathComponent]
        bad = bad.filter { !$0.isEmpty }
        for cwd in bad {
            #expect(throws: GitWorktreeIsolation.Failure.self) { try GitWorktreeIsolation.validateCloneSource(cwd) }
        }
    }

    @Test func cloneRefusesTooManyFilesOrBytes() throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        for i in 0..<20 { try String(repeating: "x", count: 100).write(toFile: tmp.path + "/f\(i)", atomically: true, encoding: .utf8) }
        #expect(throws: GitWorktreeIsolation.Failure.self) { try GitWorktreeIsolation.validateCloneSource(tmp.path, maxFiles: 10) }
        #expect(throws: GitWorktreeIsolation.Failure.self) { try GitWorktreeIsolation.validateCloneSource(tmp.path, maxBytes: 1000) }
        try GitWorktreeIsolation.validateCloneSource(tmp.path)
    }

    @Test func cloneSkipsSecretsAndPatchOmitsThem() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appendingPathComponent("plain").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/.ssh", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: folder + "/.strim", withIntermediateDirectories: true)
        try "ok\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        for f in [".env", ".env.local", "k.pem", "id_rsa", ".netrc", ".git-credentials", ".ssh/id_ed25519", ".strim/token"] {
            try "SECRET\n".write(toFile: folder + "/" + f, atomically: true, encoding: .utf8)
        }
        try "pub\n".write(toFile: folder + "/id_rsa.pub", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: folder, access: .write, files: [])
        for f in [".env", ".env.local", "k.pem", "id_rsa", ".netrc", ".git-credentials", ".ssh", ".strim/token"] {
            #expect(!fm.fileExists(atPath: ws.root + "/" + f), "\(f) was copied")
        }
        #expect(fm.fileExists(atPath: ws.root + "/id_rsa.pub") && fm.fileExists(atPath: ws.root + "/a.txt"))
        try "ok\nmore\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        try "SECRET2\n".write(toFile: ws.root + "/.env", atomically: true, encoding: .utf8)
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+more") && !patch.contains("SECRET"))
        #expect(try String(contentsOfFile: folder + "/.env", encoding: .utf8) == "SECRET\n")
        await iso.cleanup(ws)
    }

    @Test func cloneRefusedForHomeViaPrepare() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        await #expect(throws: GitWorktreeIsolation.Failure.self) {
            _ = try await iso.prepare(cwd: "/", access: .read, files: [])
        }
    }

    @Test func copyUntrackedSkipsSecrets() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/cfg/.aws", withIntermediateDirectories: true)
        try "S\n".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)
        try "S\n".write(toFile: repo + "/cfg/key.pem", atomically: true, encoding: .utf8)
        try "S\n".write(toFile: repo + "/cfg/.aws/credentials", atomically: true, encoding: .utf8)
        try "fine\n".write(toFile: repo + "/cfg/ok.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .read, files: [".env", "cfg", "cfg/key.pem"])
        #expect(!fm.fileExists(atPath: ws.root + "/.env"))
        #expect(!fm.fileExists(atPath: ws.root + "/cfg/key.pem"))
        #expect(!fm.fileExists(atPath: ws.root + "/cfg/.aws"))
        #expect(fm.fileExists(atPath: ws.root + "/cfg/ok.txt"))
        await iso.cleanup(ws)
    }

    // MARK: stash robustness, orphan sweep

    @Test func stashFailureFallsBackToHeadWhenClean() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        await iso.setStashArgs(["rev-parse", "--verify", "refs/nonexistent"])
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(ws.base == head)
        await iso.cleanup(ws)
    }

    @Test func stashFailureWhenDirtyFailsWithStderr() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try "dirty\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        await iso.setStashArgs(["rev-parse", "--verify", "refs/nonexistent"])
        do {
            _ = try await iso.prepare(cwd: repo, access: .write, files: [])
            Issue.record("expected failure")
        } catch let GitWorktreeIsolation.Failure.command(_, code, err) {
            #expect(code != 0 && !err.isEmpty)
        }
    }

    @Test func stashCreateWorksWithoutConfiguredIdentity() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        try git(["config", "--unset", "user.name"], in: repo)
        try git(["config", "--unset", "user.email"], in: repo)
        try "dirty\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(try String(contentsOfFile: ws.root + "/a.txt", encoding: .utf8) == "dirty\n")
        await iso.cleanup(ws)
    }

    @Test func sweepOrphansRemovesLeftoverWorktreeAndStaleDirs() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let base = tmp.appendingPathComponent("wt")
        let fm = FileManager.default
        let first = GitWorktreeIsolation(baseDir: base)
        let ws = try await first.prepare(cwd: repo, access: .write, files: [])  // "crashed" host: never cleaned up
        let outside = tmp.appendingPathComponent("outside").path
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "keep\n".write(toFile: outside + "/f", atomically: true, encoding: .utf8)
        let b = base.resolvingSymlinksInPath().path
        try fm.createSymbolicLink(atPath: b + "/linkdir", withDestinationPath: outside)
        try fm.createDirectory(atPath: b + "/fresh", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: b + "/stale", withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: b + "/stale")

        let second = GitWorktreeIsolation(baseDir: base)  // restarted host: no records
        let n = await second.sweepOrphans(graceSeconds: 0)
        #expect(n == 2)
        #expect(!fm.fileExists(atPath: ws.root))
        #expect(!fm.fileExists(atPath: b + "/stale"))
        #expect(fm.fileExists(atPath: b + "/fresh"))
        #expect(fm.fileExists(atPath: outside + "/f") && fm.fileExists(atPath: b + "/linkdir"))
        #expect(!(try git(["worktree", "list", "--porcelain"], in: repo).contains("wt/")))
    }

    @Test func sweepSkipsLiveJobsAndCleanupAllKeeps() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let a = try await iso.prepare(cwd: repo, access: .write, files: [])
        let b = try await iso.prepare(cwd: repo, access: .write, files: [])
        #expect(await iso.sweepOrphans(graceSeconds: 0) == 0)
        #expect(await iso.cleanupAll(keeping: [a.root]) == 1)
        #expect(FileManager.default.fileExists(atPath: a.root) && !FileManager.default.fileExists(atPath: b.root))
        #expect(await iso.cleanupAll() == 1)
        #expect(!FileManager.default.fileExists(atPath: a.root))
    }

    // MARK: second review (H2, M1, LOW)

    @Test func cloneDropsQuotedSecretSymlinkAndGitSections() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appendingPathComponent("plain").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/\u{e9}", withIntermediateDirectories: true)
        try "TOPSECRET\n".write(toFile: folder + "/\u{e9}/.env", atomically: true, encoding: .utf8)
        try "ok\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: folder, access: .write, files: [])
        #expect(!fm.fileExists(atPath: ws.root + "/\u{e9}/.env"))
        try "ok\nmore\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: ws.root + "/sub/.GIT/hooks", withIntermediateDirectories: true)
        try "#!/bin/sh\nGITHOOK\n".write(toFile: ws.root + "/sub/.GIT/hooks/x", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: ws.root + "/abs", withDestinationPath: "/etc/passwd")
        try fm.createSymbolicLink(atPath: ws.root + "/up", withDestinationPath: "../../x")
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+more"))
        for bad in ["TOPSECRET", ".env", "GITHOOK", "hooks/x", "/etc/passwd", "abs", "../../x"] {
            #expect(!patch.contains(bad), "patch leaks \(bad)")
        }
        await iso.cleanup(ws)
    }

    @Test func dropSecretSectionsFailsClosedOnQuotedHeaders() {
        let patch = "diff --git \"a/x\\303\\251/.env\" \"b/x\\303\\251/.env\"\ndeleted file mode 100644\n--- \"a/x\\303\\251/.env\"\n+++ /dev/null\n@@ -1 +0,0 @@\n-SECRET\ndiff --git a/ok.txt b/ok.txt\n--- a/ok.txt\n+++ b/ok.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let out = GitWorktreeIsolation.dropSecretSections(patch)
        #expect(!out.contains("SECRET") && out.contains("ok.txt"))
    }

    /// Existing loose object in the parent's store.
    private func someLooseObject(_ repo: String) throws -> String {
        let en = FileManager.default.enumerator(atPath: repo + "/.git/objects")!
        for case let rel as String in en {
            let parts = rel.split(separator: "/")
            if parts.count == 2, parts[0].count == 2 { return repo + "/.git/objects/" + rel }
        }
        throw NSError(domain: "t", code: 1)
    }

    @Test func sandboxCannotTouchParentObjectsButCommitAndPatchWork() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let tmpReal = tmp.resolvingSymlinksInPath()
        let repo = try makeRepo(tmpReal)
        let iso = GitWorktreeIsolation(baseDir: tmpReal.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let gp = await iso.sandboxGitPaths(for: ws)
        let jobTmp = tmpReal.appendingPathComponent("jobtmp").path
        let r = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [ws.root], jobTmp: jobTmp,
                                                      gitWritable: gp.writable, gitControlDirs: gp.control), killGrace: 0.5)
        let obj = try someLooseObject(repo)
        let before = try Data(contentsOf: URL(fileURLWithPath: obj))
        let count0 = try git(["count-objects"], in: repo)
        let o = try await r.run("""
            chmod u+w '\(obj)' 2>/dev/null; echo x >> '\(obj)'; echo append=$?
            rm -f '\(obj)'; echo rm=$?
            echo hi > n.txt && git add -A && git -c user.name=a -c user.email=a@b commit -q -m c; echo commit=$?
            """, cwd: ws.root, env: [:], timeout: 30, outputCap: 20_000)
        #expect(!o.output.contains("append=0") && !o.output.contains("rm=0"), "\(o.output)")
        #expect(o.output.contains("commit=0"), "\(o.output)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: obj)) == before)
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+two") && patch.contains("+hi"))
        #expect(try git(["count-objects"], in: repo) == count0, "parent object store changed")
        await iso.cleanup(ws)
    }

    @Test func cleanupRemovesUnremovableTree() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let fm = FileManager.default
        try fm.createDirectory(atPath: ws.root + "/locked/inner", withIntermediateDirectories: true)
        try "x".write(toFile: ws.root + "/locked/inner/f", atomically: true, encoding: .utf8)
        try "y".write(toFile: ws.root + "/immutable", atomically: true, encoding: .utf8)
        _ = try git(["-C", ws.root, "status"], in: ws.root)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        p.arguments = ["uchg", ws.root + "/immutable"]; try p.run(); p.waitUntilExit()
        #expect(chmod(ws.root + "/locked", 0) == 0)
        await iso.cleanup(ws)
        #expect(!fm.fileExists(atPath: ws.root))
    }

    @Test func totalChangedBytesCapped() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"), maxChangedBytes: 3000)
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        for i in 0..<4 { try String(repeating: "x", count: 1000).write(toFile: ws.root + "/f\(i)", atomically: true, encoding: .utf8) }
        await #expect(throws: GitWorktreeIsolation.Failure.changesTooLarge(4000)) { _ = try await iso.collectPatch(ws) }
        await iso.cleanup(ws)
    }

    // MARK: third review (quarantine validation, forged index, hardlinks)

    private func adminOf(_ ws: Workspace) throws -> String {
        try GitWorktreeIsolation.adminDir(fromGitFile: try String(contentsOfFile: ws.root + "/.git", encoding: .utf8))
    }

    private func objectFiles(_ repo: String) -> [String] {
        let base = repo + "/.git/objects"
        var out: [String] = []
        for case let rel as String in FileManager.default.enumerator(atPath: base)! {
            let a = try? FileManager.default.attributesOfItem(atPath: base + "/" + rel)
            out.append("\(rel):\(a?[.size] ?? 0):\(a?[.modificationDate] ?? Date())")
        }
        return out.sorted()
    }

    @Test func symlinkedQuarantineIsTampered() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let q = try adminOf(ws) + "/" + GitWorktreeIsolation.quarantineName
        let evil = tmp.appendingPathComponent("evil").path
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: q)
        try FileManager.default.createSymbolicLink(atPath: q, withDestinationPath: evil)
        try "one\ntwo\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        do { _ = try await iso.collectPatch(ws); Issue.record("expected tampered") }
        catch GitWorktreeIsolation.Failure.tampered {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: evil).isEmpty, "host git wrote through the symlink")
        await iso.cleanup(ws)
    }

    @Test func foreignAndHardlinkedQuarantineEntriesAreTampered() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let q = try adminOf(ws) + "/" + GitWorktreeIsolation.quarantineName
        try "x".write(toFile: q + "/stray", atomically: true, encoding: .utf8)
        do { _ = try await iso.collectPatch(ws); Issue.record("expected tampered") }
        catch GitWorktreeIsolation.Failure.tampered {}
        try FileManager.default.removeItem(atPath: q + "/stray")
        try FileManager.default.createDirectory(atPath: q + "/ab", withIntermediateDirectories: true)
        let outside = tmp.appendingPathComponent("outside").path
        try "o".write(toFile: outside, atomically: true, encoding: .utf8)
        #expect(link(outside, q + "/ab/" + String(repeating: "c", count: 38)) == 0)
        do { _ = try await iso.collectPatch(ws); Issue.record("expected tampered") }
        catch GitWorktreeIsolation.Failure.tampered {}
        await iso.cleanup(ws)
    }

    @Test func plantedAlternatesAndInfoAreRemoved() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let admin = try adminOf(ws), q = admin + "/" + GitWorktreeIsolation.quarantineName
        let evilObjs = tmp.appendingPathComponent("evilobjs").path
        try FileManager.default.createDirectory(atPath: evilObjs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: q + "/info", withIntermediateDirectories: true)
        try (evilObjs + "\n").write(toFile: q + "/info/alternates", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: admin + "/info", withIntermediateDirectories: true)
        try "*\n".write(toFile: admin + "/info/exclude", atomically: true, encoding: .utf8)
        try "one\ntwo\n".write(toFile: ws.root + "/new.txt", atomically: true, encoding: .utf8)
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("new.txt"), "info/exclude hid a file")
        #expect(!FileManager.default.fileExists(atPath: q + "/info"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: evilObjs).isEmpty)
        await iso.cleanup(ws)
    }

    @Test func forgedIndexFlagsCannotHideChanges() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let objsBefore = objectFiles(repo)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let admin = try adminOf(ws)
        try "one\nHIDDEN-A\n".write(toFile: ws.root + "/a.txt", atomically: true, encoding: .utf8)
        try "b\nHIDDEN-B\n".write(toFile: ws.root + "/sub/b.txt", atomically: true, encoding: .utf8)
        try git(["--git-dir=\(admin)", "--work-tree=\(ws.root)", "update-index", "--assume-unchanged", "a.txt"], in: ws.root)
        try git(["--git-dir=\(admin)", "--work-tree=\(ws.root)", "update-index", "--skip-worktree", "sub/b.txt"], in: ws.root)
        let patch = try await iso.collectPatch(ws)
        #expect(patch.contains("+HIDDEN-A") && patch.contains("+HIDDEN-B"), "\(patch)")
        await iso.cleanup(ws)
        #expect(objectFiles(repo) == objsBefore, "parent object store changed")
    }

    @Test func cleanupDoesNotChmodThroughHardlinks() async throws {
        let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo(tmp)
        let iso = GitWorktreeIsolation(baseDir: tmp.appendingPathComponent("wt"))
        let ws = try await iso.prepare(cwd: repo, access: .write, files: [])
        let outside = tmp.appendingPathComponent("userfile").path
        try "precious".write(toFile: outside, atomically: true, encoding: .utf8)
        #expect(chmod(outside, 0o400) == 0)
        #expect(link(outside, ws.root + "/hl") == 0)
        try FileManager.default.createDirectory(atPath: ws.root + "/locked", withIntermediateDirectories: true)
        try "x".write(toFile: ws.root + "/locked/f", atomically: true, encoding: .utf8)
        #expect(chmod(ws.root + "/locked", 0) == 0)
        await iso.cleanup(ws)
        #expect(!FileManager.default.fileExists(atPath: ws.root))
        var st = stat()
        #expect(stat(outside, &st) == 0 && (st.st_mode & 0o777) == 0o400, "mode changed through hardlink")
        chmod(outside, 0o600)
    }
}

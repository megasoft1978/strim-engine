import Foundation
import Testing
import StrimAPI
import StrimHarness
import StrimHost
import StrimJobs
@testable import StrimControl

private func body(_ id: String, _ action: String, sha: String? = nil) -> String {
    sha.map { #"{"job_id":"\#(id)","action":"\#(action)","patch_sha256":"\#($0)"}"# } ?? #"{"job_id":"\#(id)","action":"\#(action)"}"#
}
private func sha(_ s: String) -> String { StrimControlPlane.sha256(Data(s.utf8)) }
private func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "<missing>" }

@Suite("approve: apply on a temp git repo", .serialized)
struct ControlApproveTests {
    @Test("matching digest applies with git apply --3way; second decision is 409; digest is in the detail")
    func applies() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let d = await r.call("GET", "/v1/strim/jobs/\(id)")
        let digest = (try JSONSerialization.jsonObject(with: d.data) as! [String: Any])["patch_sha256"] as! String
        #expect(digest == sha(patch))
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: digest))
        #expect(x.status == 200, "\(x.body)")
        #expect(read(repo + "/a.txt") == "one\ntwo\n" && read(repo + "/sub/b.txt") == "bee\nbuzz\n")
        #expect(FileManager.default.fileExists(atPath: r.jobsRoot.appendingPathComponent(id + "/decision.json").path))
        let again = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: digest))
        #expect(again.status == 409 && again.code == "conflict")
    }

    @Test("apply without patch_sha256 is 400 and applies nothing")
    func missingDigest() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply"))
        #expect(x.status == 400 && x.code == "bad_request")
        #expect(read(repo + "/a.txt") == "one\n")
    }

    @Test("digest mismatch is 409 patch_changed and applies nothing")
    func mismatch() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha("something else")))
        #expect(x.status == 409 && x.code == "patch_changed")
        #expect(read(repo + "/a.txt") == "one\n" && read(repo + "/sub/b.txt") == "bee\n")
        // The patch file replaced after review: the reviewed digest no longer matches.
        let file = r.jobsRoot.appendingPathComponent(id + "/patch.diff").path
        let good = sha(patch)
        try patch.replacingOccurrences(of: "+two", with: "+evil").write(toFile: file, atomically: true, encoding: .utf8)
        let y = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: good))
        #expect(y.status == 409 && y.code == "patch_changed")
        #expect(read(repo + "/a.txt") == "one\n")
    }

    @Test("patch file swapped between hash and apply cannot slip through: the hashed bytes are applied")
    func swapAfterHash() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let file = r.jobsRoot.appendingPathComponent(id + "/patch.diff").path
        let evil = patch.replacingOccurrences(of: "+two", with: "+evil")
        r.plane.afterPatchHash.withLock { $0 = { try? evil.write(toFile: file, atomically: true, encoding: .utf8) } }
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 200, "\(x.body)")
        #expect(read(file) == evil, "the swap really happened")
        #expect(read(repo + "/a.txt") == "one\ntwo\n", "applied the reviewed bytes, not the swapped file")
    }

    @Test("reject needs no digest, records the decision and applies nothing")
    func reject() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        #expect(await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "reject")).status == 200)
        #expect(read(repo + "/a.txt") == "one\n")
        #expect(await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch))).status == 409)
    }

    @Test("traversal and .git paths are refused (unsafe_patch), nothing is written")
    func unsafePaths() async throws {
        let (repo, _) = try makeRepo()
        let outside = URL(fileURLWithPath: repo).deletingLastPathComponent().appendingPathComponent("escape-\(UUID().uuidString).txt")
        let cases: [(String, String)] = [
            ("traversal", "diff --git a/../\(outside.lastPathComponent) b/../\(outside.lastPathComponent)\nnew file mode 100644\n--- /dev/null\n+++ b/../\(outside.lastPathComponent)\n@@ -0,0 +1 @@\n+pwn\n"),
            ("dotgit", "diff --git a/.git/hooks/pre-commit b/.git/hooks/pre-commit\nnew file mode 100755\n--- /dev/null\n+++ b/.git/hooks/pre-commit\n@@ -0,0 +1 @@\n+echo pwn\n"),
            ("nested .git", "diff --git a/sub/.GIT/config b/sub/.GIT/config\nnew file mode 100644\n--- /dev/null\n+++ b/sub/.GIT/config\n@@ -0,0 +1 @@\n+x\n"),
            ("absolute", "diff --git a//etc/x b//etc/x\nnew file mode 100644\n--- /dev/null\n+++ b//etc/x\n@@ -0,0 +1 @@\n+x\n"),
            ("symlink", "diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/etc\n\\ No newline at end of file\n"),
            ("rename into .git", "diff --git a/a.txt b/.git/x\nsimilarity index 100%\nrename from a.txt\nrename to .git/x\n"),
        ]
        for (name, patch) in cases {
            let r = try await Rig.make(patch: patch)
            defer { r.stop() }
            let id = try await runJob(r, cwd: repo)
            let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
            #expect(x.status == 400 && x.code == "unsafe_patch", "\(name): \(x.status) \(x.body)")
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: repo + "/.git/hooks/pre-commit"))
        #expect(!FileManager.default.fileExists(atPath: repo + "/link"))
        #expect(read(repo + "/a.txt") == "one\n")
    }

    @Test("a patch touching files outside the job's sub-directory is refused")
    func outsideCwd() async throws {
        let (repo, patch) = try makeRepo()    // edits a.txt (outside sub) and sub/b.txt
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo + "/sub")
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 400 && x.code == "unsafe_patch", "\(x.body)")
        #expect(read(repo + "/a.txt") == "one\n" && read(repo + "/sub/b.txt") == "bee\n")
    }

    @Test("a symlink inside cwd pointing out of it is not followed")
    func symlinkEscape() async throws {
        let (repo, _) = try makeRepo()
        let outsideDir = tmpDir("out").resolvingSymlinksInPath().path
        try "keep\n".write(toFile: outsideDir + "/t.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo + "/sub/esc", withDestinationPath: outsideDir)
        let patch = "diff --git a/sub/esc/t.txt b/sub/esc/t.txt\n--- a/sub/esc/t.txt\n+++ b/sub/esc/t.txt\n@@ -1 +1,2 @@\n keep\n+pwn\n"
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 400, "\(x.status)")
        #expect(x.body.contains("\"code\":\"unsafe_patch\"") && x.body.contains("resolves outside the job"), "\(x.body)")
        #expect(read(outsideDir + "/t.txt") == "keep\n")
    }

    @Test("a hunk body that looks like a header is not mistaken for one; real headers are still checked")
    func headerParser() throws {
        let benign = "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n--- a/../../x\n+++ b/../../y\n ctx\n"
        #expect(try PatchApplier.headerPaths(benign) == ["f.txt", "f.txt", "f.txt", "f.txt"])
        let evil = benign + "diff --git a/../z b/../z\n"
        let paths = try PatchApplier.headerPaths(evil)
        #expect(paths.contains("../z"))
        #expect(throws: ControlError.self) { try PatchApplier.confine(["../z"], top: "/tmp/x", cwdReal: "/tmp/x") }
        #expect(throws: ControlError.self) { try PatchApplier.checkPath("a/.git/b") }
        #expect(throws: ControlError.self) { try PatchApplier.checkPath("\"quoted\"") }
        try PatchApplier.checkPath("src/.gitignore")
        try PatchApplier.checkPath("a/b.txt")
    }

    @Test("numstat -z parsing handles renames")
    func numstat() {
        let d = Data("1\t2\tfile a.txt\0".utf8) + Data("0\t0\t\0old.txt\0new.txt\0".utf8) + Data("-\t-\tbin.png\0".utf8)
        #expect(PatchApplier.numstatPaths(d) == ["file a.txt", "old.txt", "new.txt", "bin.png"])
    }

    @Test("not a git repo, no patch, unfinished job, unknown job")
    func misc() async throws {
        let dir = tmpDir("nogit").resolvingSymlinksInPath().path
        let (_, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: dir)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 400, "\(x.body)")
        let none = try await Rig.make(); defer { none.stop() }
        let id2 = try await runJob(none, cwd: dir)
        #expect(await none.call("POST", "/v1/strim/jobs/approve", body: body(id2, "apply", sha: sha("x"))).status == 409)
        #expect(await r.call("POST", "/v1/strim/jobs/approve", body: body("j_abcdefgh23", "apply", sha: "x")).status == 404)
        #expect(await r.call("POST", "/v1/strim/jobs/approve", body: body("bad", "apply", sha: "x")).status == 400)
        #expect(await r.call("POST", "/v1/strim/jobs/approve", body: #"{"job_id":"j_abcdefgh23","action":"nuke"}"#).status == 400)
    }

    @Test("allowedRoots is enforced again at apply time")
    func policyAtApply() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch, policy: HostPolicy(maxAccess: .write, allowedRoots: ["/nonexistent-root"]))
        defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 403)
        #expect(read(repo + "/a.txt") == "one\n")
    }

    // MARK: repo-controlled execution

    @Test("a repo whose .git/config can run commands is refused (risky_repo_config); nothing executes")
    func riskyConfig() async throws {
        for (name, config) in [
            ("filter", "[filter \"x\"]\n\tsmudge = sh -c 'touch MARK'\n\tclean = sh -c 'touch MARK'\n"),
            ("merge", "[merge \"x\"]\n\tdriver = sh -c 'touch MARK'\n"),
            ("fsmonitor", "[core]\n\tfsmonitor = touch MARK\n"),
            ("hooks", "[core]\n\thooksPath = /tmp/evil\n"),
            ("include", "[include]\n\tpath = /tmp/evil.cfg\n"),
            ("url", "[url \"ssh://evil/\"]\n\tinsteadOf = https://\n"),
        ] {
            let (repo, patch) = try makeRepo()
            let gitignore = "* filter=x merge=x\n"
            try gitignore.write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
            let cfg = try String(contentsOfFile: repo + "/.git/config", encoding: .utf8)
            try (cfg + config).write(toFile: repo + "/.git/config", atomically: true, encoding: .utf8)
            let r = try await Rig.make(patch: patch); defer { r.stop() }
            let id = try await runJob(r, cwd: repo)
            let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
            #expect(x.status == 400 && x.code == "risky_repo_config", "\(name): \(x.status) \(x.body)")
            #expect(!FileManager.default.fileExists(atPath: repo + "/MARK") && read(repo + "/a.txt") == "one\n", "\(name)")
        }
    }

    @Test("a conflicting tree is 409 apply_conflict, untouched, with no merge markers (no --3way)")
    func conflict() async throws {
        let (repo, patch) = try makeRepo()
        try "ONE CHANGED\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 409 && x.code == "apply_conflict", "\(x.body)")
        #expect(read(repo + "/a.txt") == "ONE CHANGED\n" && read(repo + "/sub/b.txt") == "bee\n")
        #expect(try git(["status", "--porcelain"], in: repo).split(separator: "\n").count == 1)
    }

    @Test("git timeouts kill the whole process group and return promptly")
    func timeoutKillsGroup() async throws {
        let pidFile = tmpDir("pid").path + "/pid"
        let t0 = Date()
        let res = try await Git.run(["-c", "alias.hang=!sh -c 'sleep 60 & echo $! > \(pidFile); wait'", "hang"],
                                    cwd: NSTemporaryDirectory(), stdin: nil, timeout: 0.6)
        #expect(res.timedOut && Date().timeIntervalSince(t0) < 5)
        try await Task.sleep(for: .milliseconds(300))
        let pid = Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        #expect(pid > 0 && kill(pid, 0) != 0, "child process survived the timeout")
    }

    @Test("a crash by signal is reported as a crash, a timeout as a timeout")
    func crashVsTimeout() async {
        let crash = Git.Result(status: -1, outData: Data(), err: "", signal: 11, timedOut: false)
        let hang = Git.Result(status: -1, outData: Data(), err: "", signal: nil, timedOut: true)
        do { try PatchApplier.expectCompleted(crash, what: "git x", top: "/", timeout: 5); Issue.record("no throw") }
        catch let e as ControlError { #expect(e.error.code == "internal" && e.error.message.contains("crashed (signal 11)")) } catch {}
        do { try PatchApplier.expectCompleted(hang, what: "git x", top: "/", timeout: 5); Issue.record("no throw") }
        catch let e as ControlError { #expect(e.error.code == "apply_timeout") } catch {}
        let dir = tmpDir("tree").path
        _ = try? git(["init", "-q"], in: dir)
        do { try await PatchApplier.expectCompletedReportingTree(hang, top: dir, timeout: 5); Issue.record("no throw") }
        catch let e as ControlError { #expect(e.error.code == "apply_timeout" && e.error.message.contains("working tree is clean")) } catch {}
    }

    @Test("error text is stripped of control characters")
    func sanitize() {
        #expect(Sanitize.text("a\nb\u{1B}[31mred\r\n") == "a b [31mred")
        #expect(Sanitize.text(String(repeating: "x", count: 1000), limit: 50).count == 50)
    }

    // MARK: structural defence: nothing the repo carries can execute

    private func expectRefused(_ name: String, setup: (String) throws -> Void) async throws {
        let (repo, patch) = try makeRepo()
        try setup(repo)
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 400 && x.code == "risky_repo_config", "\(name): \(x.status) \(x.body)")
        let marks = ["MARK", "sub/MARK", ".git/MARK"].filter { FileManager.default.fileExists(atPath: repo + "/" + $0) }
        #expect(marks.isEmpty && read(repo + "/a.txt") == "one\n", "\(name): executed or modified")
    }

    private func append(_ text: String, to path: String) throws {
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (old + text).write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("config.worktree with extensions.worktreeConfig")
    func worktreeConfig() async throws {
        try await expectRefused("worktree config") { repo in
            try append("[extensions]\n\tworktreeConfig = true\n", to: repo + "/.git/config")
            try append("[core]\n\tfsmonitor = touch MARK\n", to: repo + "/.git/config.worktree")
        }
        try await expectRefused("config.worktree alone") { repo in
            try append("[core]\n\tfsmonitor = touch MARK\n", to: repo + "/.git/config.worktree")
        }
    }

    @Test("includeIf / include pointing at a malicious file")
    func includes() async throws {
        let evil = tmpDir("evil").path + "/evil.cfg"
        try "[core]\n\tfsmonitor = touch MARK\n[filter \"x\"]\n\tsmudge = touch MARK\n".write(toFile: evil, atomically: true, encoding: .utf8)
        try await expectRefused("includeIf") { repo in
            try append("[includeIf \"gitdir:\(repo)/.git\"]\n\tpath = \(evil)\n", to: repo + "/.git/config")
        }
        try await expectRefused("include") { repo in
            try append("[include]\n\tpath = \(evil)\n", to: repo + "/.git/config")
        }
    }

    @Test(".git/info/attributes and nested .gitattributes with filter/merge/diff/textconv")
    func attributeFiles() async throws {
        try await expectRefused("info/attributes") { repo in
            try append("* filter=x\n", to: repo + "/.git/info/attributes")
        }
        try await expectRefused("nested merge") { repo in
            try append("*.txt merge=x\n", to: repo + "/sub/.gitattributes")
            try git(["add", "-f", "sub/.gitattributes"], in: repo); try git(["commit", "-q", "-m", "attr"], in: repo)
        }
        try await expectRefused("root diff") { repo in
            try append("*.txt diff=x\n", to: repo + "/.gitattributes")
            try git(["add", ".gitattributes"], in: repo); try git(["commit", "-q", "-m", "attr"], in: repo)
        }
        try await expectRefused("textconv in unrelated dir") { repo in
            try append("*.md diff=y textconv=cat\n", to: repo + "/other/.gitattributes")
            try git(["add", "other/.gitattributes"], in: repo); try git(["commit", "-q", "-m", "attr"], in: repo)
        }
    }

    @Test("a harmless repo still applies; core keys parser and scope listing")
    func harmless() async throws {
        let (repo, patch) = try makeRepo()
        try append("[user]\n\tname = me\n[core]\n\tautocrlf = false\n", to: repo + "/.git/config")
        try append("*.png binary\n*.txt text\n", to: repo + "/.gitattributes")
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: body(id, "apply", sha: sha(patch)))
        #expect(x.status == 200, "\(x.body)")
        #expect(RepoSafety.riskyKeys(inConfig: "[core]\n\tFsMonitor = x\n[Filter \"a\"]\n\tclean=b\n[extensions]\nworktreeConfig=true\n[core] hooksPath = /x\n").count == 4)
        #expect(RepoSafety.riskyKeys(inConfig: "[user]\n\tname = x\n[core]\n\tautocrlf = true\n[remote \"o\"]\n\turl = x\n").isEmpty)
    }
}

import Testing
import Foundation
@testable import StrimHarness

// These run real `sandbox-exec` processes. They fail (reported by `sandboxAvailable`) if the test
// runner is itself sandboxed, since sandbox_apply cannot nest.
@Suite struct SandboxTests {
    final class Env {
        let base: String, tmp: String, work: String, other: String, home: String
        init() throws {
            let fm = FileManager.default
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("strim-sbx-\(UUID().uuidString)").path
            tmp = base + "/jobtmp"; work = base + "/work"; other = base + "/other"; home = base + "/home"
            for d in [tmp, work, other, home + "/.ssh"] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
            try "secret".write(toFile: home + "/.ssh/id_test", atomically: true, encoding: .utf8)
            try "hello".write(toFile: work + "/f.txt", atomically: true, encoding: .utf8)
        }
        deinit { try? FileManager.default.removeItem(atPath: base) }
        func runner(_ access: AccessLevel = .write, sandboxed: Bool = true, pass: [String] = []) -> ProcessRunner {
            ProcessRunner(profile: SandboxProfile(access: access, writableRoots: [work], jobTmp: tmp, home: home),
                          passthroughEnv: pass, killGrace: 0.5, sandboxed: sandboxed)
        }
        func run(_ r: ProcessRunner, _ cmd: String, timeout: TimeInterval = 20, cap: Int = 100_000) async throws -> CommandOutput {
            try await r.run(cmd, cwd: work, env: [:], timeout: timeout, outputCap: cap)
        }
        /// Compiles a C probe with the system clang, outside the sandbox, so tests need no Python.
        func cProbe(_ name: String, _ src: String) throws -> String {
            let c = base + "/" + name + ".c", bin = base + "/" + name
            try src.write(toFile: c, atomically: true, encoding: .utf8)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            p.arguments = ["-o", bin, c]
            try p.run(); p.waitUntilExit()
            try #require(p.terminationStatus == 0)
            return bin
        }
    }

    @Test func sandboxAvailable() async throws {
        let e = try Env()
        let o = try await e.run(e.runner(), "echo ok")
        #expect(o.exitCode == 0 && o.output.contains("ok"),
                "sandbox-exec unusable here (test runner already sandboxed?): \(o.output)")
    }

    @Test func networkDenied() async throws {
        let e = try Env()
        let o = try await e.run(e.runner(), "exec 3<>/dev/tcp/127.0.0.1/9 2>&1; echo rc=$?; curl -s -m 3 https://example.com >/dev/null; echo curl=$?")
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        #expect(!o.output.contains("curl=0"), "\(o.output)")
        // control: curl without sandbox profile reaching network is not asserted (offline CI).
    }

    @Test func writesOnlyUnderRoots() async throws {
        let e = try Env()
        let r = e.runner()
        var o = try await e.run(r, "echo a > \(e.work)/in.txt && echo b > \(e.tmp)/t.txt; echo rc=$?")
        #expect(o.output.contains("rc=0"), "\(o.output)")
        #expect(FileManager.default.fileExists(atPath: e.work + "/in.txt"))
        o = try await e.run(r, "echo x > \(e.other)/out.txt; echo rc=$?")
        #expect(!o.output.contains("rc=0") && o.output.contains("Operation not permitted"), "\(o.output)")
        #expect(!FileManager.default.fileExists(atPath: e.other + "/out.txt"))
        o = try await e.run(r, "echo x > /dev/null && echo devnull-ok")
        #expect(o.output.contains("devnull-ok"))
    }

    @Test func readAccessOnlyWritesJobTmp() async throws {
        let e = try Env()
        let r = e.runner(.read)
        var o = try await e.run(r, "echo x > \(e.work)/no.txt; echo rc=$?")
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        o = try await e.run(r, "echo x > \(e.tmp)/ok.txt; echo rc=$?")
        #expect(o.output.contains("rc=0"), "\(o.output)")
    }

    @Test func secretReadDenied() async throws {
        let e = try Env()
        try "c".write(toFile: e.home + "/.claude.json", atomically: true, encoding: .utf8)
        let r = e.runner()
        var o = try await e.run(r, "cat \(e.home)/.ssh/id_test; echo rc=$?")
        #expect(!o.output.contains("secret") && !o.output.contains("rc=0"), "\(o.output)")
        o = try await e.run(r, "cat \(e.home)/.claude.json; echo rc=$?")
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        o = try await e.run(r, "cat f.txt")
        #expect(o.output == "hello")
        // Control: unsandboxed can read it.
        o = try await e.run(e.runner(sandboxed: false), "cat \(e.home)/.ssh/id_test")
        #expect(o.output == "secret")
    }

    @Test func envScrubbed() async throws {
        let e = try Env()
        setenv("STRIM_PLANTED_SECRET", "leak", 1)
        setenv("STRIM_PASS_ME", "pass", 1)
        defer { unsetenv("STRIM_PLANTED_SECRET"); unsetenv("STRIM_PASS_ME") }
        let o = try await e.run(e.runner(pass: ["STRIM_PASS_ME"]), "echo [$STRIM_PLANTED_SECRET][$STRIM_PASS_ME][$HOME][$TMPDIR][$PATH]")
        #expect(o.output.contains("[][pass][\(e.tmp)/home][\(e.tmp)][\(e.runner().buildEnv([:])["PATH"]!)]"), "\(o.output)")
        let all = try await e.run(e.runner(), "env | cut -d= -f1 | sort | tr '\\n' ' '")
        #expect(!all.output.contains("STRIM_PLANTED"), "\(all.output)")
    }

    @Test func timeoutKillsGroupIncludingGrandchild() async throws {
        let e = try Env()
        let pidFile = e.work + "/gc.pid"
        let t0 = Date()
        let o = try await e.run(e.runner(), "sleep 300 & echo $! > \(pidFile); sleep 300", timeout: 2)
        let dt = Date().timeIntervalSince(t0)
        #expect(o.timedOut && dt < 6, "dt=\(dt)")
        #expect(o.exitCode != 0)
        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(kill(pid, 0) != 0 && errno == ESRCH, "grandchild \(pid) still alive")
    }

    @Test func sigtermIgnoringChildGetsKilled() async throws {
        let e = try Env()
        let t0 = Date()
        let o = try await e.run(e.runner(), "trap '' TERM; sleep 300 & wait", timeout: 1)
        #expect(o.timedOut && Date().timeIntervalSince(t0) < 6)
    }

    @Test func outputCapKeepsHeadAndTail() async throws {
        let e = try Env()
        let o = try await e.run(e.runner(sandboxed: false), "echo HEADMARK; yes x | head -c 200000; echo TAILMARK", cap: 1000)
        #expect(o.truncated && o.output.hasPrefix("HEADMARK") && o.output.hasSuffix("TAILMARK\n"), "\(o.output.prefix(40))")
        #expect(o.output.utf8.count < 1200)
        let small = try await e.run(e.runner(sandboxed: false), "echo hi", cap: 1000)
        #expect(!small.truncated && small.output == "hi\n")
    }

    @Test func exitCodePropagates() async throws {
        let e = try Env()
        #expect(try await e.run(e.runner(), "exit 7").exitCode == 7)
        #expect(try await e.run(e.runner(), "true").exitCode == 0)
        let o = try await e.run(e.runner(), "echo out; echo err >&2")
        #expect(o.output.contains("out") && o.output.contains("err") && !o.timedOut)
    }

    @Test func profileEscapesQuotesAndSpaces() throws {
        let q = "/tmp/we\"ird dir/job"
        let p = SandboxProfile(access: .write, writableRoots: ["/tmp/a \"b\""], jobTmp: q, home: "/Users/x.y")
        let s = p.profile
        #expect(s.contains("(subpath \"/tmp/we\\\"ird dir/job\")"), "\(s)")
        #expect(s.contains("(subpath \"/tmp/a \\\"b\\\"\")"))
        #expect(s.contains("(subpath \"/Users/x.y/.ssh\")") && s.contains("(literal \"/Users/x.y/.netrc\")"))
        #expect(s.contains("(regex \"^/Users/x\\\\.y/\\\\.claude\")"))
        #expect(s.hasPrefix("(version 1)\n(allow default)\n(deny network*)\n"))
        #expect(s.contains("(deny mach-lookup)") && s.contains("(deny signal)"))
        let ro = SandboxProfile(access: .read, writableRoots: ["/tmp/a"], jobTmp: "/tmp/j", home: "/h").profile
        // Read mode: the roots are not writable. (They are read-allowed again because /tmp is a denied temp area.)
        let writeBlock = ro.components(separatedBy: "(allow file-write*").dropFirst().first?.components(separatedBy: "\n(").first ?? ""
        #expect(!writeBlock.contains("\"/tmp/a\"") && writeBlock.contains("/tmp/j"), "\(ro)")
    }

    @Test func realProfileWithQuoteAndSpaceInPathRuns() async throws {
        let e = try Env()
        let weird = e.base + "/we\"ird dir"
        try FileManager.default.createDirectory(atPath: weird, withIntermediateDirectories: true)
        let r = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [weird], jobTmp: e.tmp, home: e.home), sandboxed: true)
        let o = try await r.run("echo ok > \"\(weird.replacingOccurrences(of: "\"", with: "\\\""))/f\"; echo rc=$?", cwd: e.work, env: [:], timeout: 10, outputCap: 1000)
        #expect(o.output.contains("rc=0"), "\(o.output)")
    }

    // MARK: git control paths

    @Test func gitHooksAndConfigDeniedInRoot() async throws {
        let e = try Env()
        let g = e.work + "/.git"
        try FileManager.default.createDirectory(atPath: g + "/hooks", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: e.work + "/.GIT/hooks", withIntermediateDirectories: true)
        try "c".write(toFile: g + "/config", atomically: true, encoding: .utf8)
        let r = e.runner()
        for target in [".git/hooks/pre-commit", ".GIT/hooks/pre-commit", ".Git/config", ".git/config",
                       ".git/hooks/sub", ".gIt/config.worktree"] {
            let o = try await e.run(r, "mkdir -p \"$(dirname \(target))\" 2>/dev/null; echo x > \(target); echo rc=$?")
            #expect(!o.output.contains("rc=0"), "\(target): \(o.output)")
        }
        #expect(!FileManager.default.fileExists(atPath: g + "/hooks/pre-commit"))
        #expect(try String(contentsOfFile: g + "/config", encoding: .utf8) == "c")
        // Other .git files and normal files still writable.
        var o = try await e.run(r, "echo x > .git/index; echo rc=$?")
        #expect(o.output.contains("rc=0"), "\(o.output)")
        o = try await e.run(r, "echo x > normal.txt; echo rc=$?")
        #expect(o.output.contains("rc=0"), "\(o.output)")
    }

    @Test func gitDirsOutsideRootDeniedHooksAndConfig() async throws {
        let e = try Env()
        let common = e.base + "/common.git"
        let wt = common + "/worktrees/w1"
        for d in [common + "/hooks", common + "/objects", common + "/refs", wt, wt + "/hooks", wt + "/info", wt + "/Info", common + "/info"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        let r = ProcessRunner(profile: SandboxProfile(
            access: .write, writableRoots: [e.work], jobTmp: e.tmp, home: e.home,
            gitWritable: [wt, common + "/objects", common + "/refs"], gitControlDirs: [common]), killGrace: 0.5)
        for t in [common + "/refs/r", common + "/refs/heads/main", common + "/packed-refs", common + "/HEAD", common + "/logs/refs/x",
                  common + "/hooks/post-commit", common + "/config", common + "/CONFIG", wt + "/hooks/x", wt + "/config.worktree",
                  wt + "/commondir", wt + "/GITDIR", wt + "/info/exclude", wt + "/Info/attributes", common + "/info/exclude"] {
            let o = try await e.run(r, "echo x > '\(t)'; echo rc=$?")
            #expect(!o.output.contains("rc=0"), "\(t): \(o.output)")
        }
        for t in [wt + "/index", wt + "/HEAD", wt + "/ORIG_HEAD", wt + "/logs", common + "/objects/o"] {
            let o = try await e.run(r, "echo x > '\(t)'; echo rc=$?")
            #expect(o.output.contains("rc=0"), "\(t): \(o.output)")
        }
    }

    @Test func darwinTempXcrunCacheNotWritable() async throws {
        let e = try Env()
        var buf = [CChar](repeating: 0, count: 1024)
        #expect(confstr(Int32(_CS_DARWIN_USER_TEMP_DIR), &buf, buf.count) > 0)
        let f = String(cString: buf) + "xcrun_db-sandboxtest"
        defer { try? FileManager.default.removeItem(atPath: f) }
        let o = try await e.run(e.runner(), "echo x > '\(f)'; echo rc=$?")
        #expect(!o.output.contains("rc=0") && !FileManager.default.fileExists(atPath: f), "\(o.output)")
        let w = try await e.run(e.runner(), "command -v git")
        #expect(SandboxProfile.trustedGitPath != nil && w.output.hasPrefix(SandboxProfile.trustedGitPath!), "\(w.output)")
    }

    @Test func gitWorktreeCommitNeedsGitdirPaths() async throws {
        let e = try Env()
        let repo = e.base + "/repo", wtRoot = e.base + "/wt"
        func sh(_ c: String) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", c]
            p.environment = ["PATH": ProcessRunner.defaultPath, "HOME": e.base + "/ghome",
                             "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(c)")
        }
        try sh("""
            set -e; mkdir -p '\(repo)' && cd '\(repo)' && git init -q -b main && git config user.email t@t && git config user.name t \
            && echo a > a.txt && git add -A && git commit -q -m init && git worktree add -q --detach '\(wtRoot)'
            """)
        let common = URL(fileURLWithPath: repo + "/.git").path
        let id = try String(contentsOfFile: wtRoot + "/.git", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/").last!
        let cmd = "echo b > b.txt && git add -A && git -c user.email=t@t -c user.name=t commit -q -m job && git log --oneline | wc -l"
        let ident: (ProcessRunner) -> ProcessRunner = { $0 }
        let with = ident(ProcessRunner(profile: SandboxProfile(
            access: .write, writableRoots: [wtRoot], jobTmp: e.tmp, home: e.home,
            gitWritable: [common + "/worktrees/" + id, common + "/objects", common + "/refs", common + "/logs/refs"],
            gitControlDirs: [common]), killGrace: 0.5))
        var o = try await with.run(cmd, cwd: wtRoot, env: [:], timeout: 30, outputCap: 10_000)
        #expect(o.exitCode == 0 && o.output.contains("2"), "\(o.output)")
        // Hooks / config of the common gitdir and worktree .git pointer still protected.
        o = try await with.run("echo x > '\(common)/hooks/pre-commit'; echo rc=$?; echo gitdir: /x > .git; echo rc=$?", cwd: wtRoot, env: [:], timeout: 10, outputCap: 10_000)
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        // `git config --worktree` writes <admin>/config.worktree: must fail.
        o = try await with.run("git config --worktree core.fsmonitor x; echo rc=$?", cwd: wtRoot, env: [:], timeout: 30, outputCap: 10_000)
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        o = try await with.run("git config core.fsmonitor x; echo rc=$?", cwd: wtRoot, env: [:], timeout: 30, outputCap: 10_000)
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        #expect(!(try String(contentsOfFile: common + "/config", encoding: .utf8)).contains("fsmonitor"))
        let without = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [wtRoot], jobTmp: e.tmp, home: e.home), killGrace: 0.5)
        o = try await without.run("echo c > c.txt && git add -A && git -c user.email=t@t -c user.name=t commit -q -m nope", cwd: wtRoot, env: [:], timeout: 30, outputCap: 10_000)
        #expect(o.exitCode != 0, "\(o.output)")
    }

    // MARK: exploit matrix
    //
    // | # | exploit (inside sandbox)                         | block                                   | test                       |
    // |---|--------------------------------------------------|-----------------------------------------|----------------------------|
    // | 1 | `open -a App` / `open x.command` (LaunchServices)| (deny mach-lookup)                      | launchServicesBlocked      |
    // | 1 | `osascript` tell app (Apple events)              | (deny mach-lookup)                      | appleEventsPasteboardKeychainDnsBlocked |
    // | 1 | `pbpaste` clipboard read                         | (deny mach-lookup)                      | appleEventsPasteboardKeychainDnsBlocked |
    // | 1 | `security` keychain access via securityd         | (deny mach-lookup)                      | appleEventsPasteboardKeychainDnsBlocked |
    // | 1 | DNS via mDNSResponder (exfil w/o network*)       | (deny mach-lookup) + network*           | appleEventsPasteboardKeychainDnsBlocked |
    // | 1 | `kill -9 <other pid>`                             | (deny signal) + allow self/same-sandbox | cannotSignalOtherProcesses |
    // | 1 | process-info of other pids                       | (deny process-info*) + allow self/same  | cannotSignalOtherProcesses |
    // | 2 | read ~/.npmrc, other repos, ~/Library/...        | (deny file-read* /Users + home), allow roots | readsOutsideAllowedSetDenied |
    // | 2 | secret paths when workspace is under HOME        | secret denies last (win over allow)     | secretsStillDeniedUnderAllowedRoot |
    // | 8 | `git update-ref`/`branch -f`/`tag` on parent refs| (deny file-write* common refs, logs/refs, packed-refs, HEAD) | gitCannotRewriteParentRefs |
    // | 9 | xcrun_db write, shim git                         | no allow; trustedGitPath first on PATH  | darwinTempXcrunCacheNotWritable |
    // | a | /users, /USERS, mixed-case home + secret paths     | kernel canonicalises case for subpath/literal; git ctl paths use ci regex | caseVariantsDenied |
    // | b | hard link in/out of protected git files          | link needs write on source; dest hits write denies | hardLinksIntoOrOutOfGitBlocked |
    // | c | parent .git/credentials*, *.pem read (config stays readable: git needs it) | read deny regex | gitCredentialFilesUnreadableButGitWorks |
    // | d | /Volumes read, posix shm                          | (deny file-read* /Volumes), (deny ipc-posix-shm*) | volumesAndSharedMemoryDenied |
    // Normal tooling (git add/commit, sh test script, clang, swiftc, coreutils, curl failing) : normalToolingStillWorks.

    @Test func launchServicesBlocked() async throws {
        let e = try Env()
        let marker = e.work + "/PWNED"
        try "#!/bin/bash\ntouch '\(marker)'\n".write(toFile: e.work + "/x.command", atomically: true, encoding: .utf8)
        chmod(e.work + "/x.command", 0o755)
        // Control: Calculator is launched only if LaunchServices is reachable.
        let o = try await e.run(e.runner(), "open -g -j -a Calculator; echo rc=$?; open -g -j x.command; echo rc2=$?; sleep 1")
        #expect(!o.output.contains("rc=0") && !o.output.contains("rc2=0"), "\(o.output)")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func appleEventsPasteboardKeychainDnsBlocked() async throws {
        let e = try Env()
        let r = e.runner()
        var o = try await e.run(r, "osascript -e 'tell application \"Finder\" to get name of startup disk' 2>&1; echo rc=$?")
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        // Plant a clipboard value, then read it from inside the sandbox.
        let pb = Process(); pb.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        let pipe = Pipe(); pb.standardOutput = pipe; try pb.run(); pb.waitUntilExit()
        let saved = pipe.fileHandleForReading.readDataToEndOfFile()
        let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let inp = Pipe(); cp.standardInput = inp; try cp.run()
        inp.fileHandleForWriting.write(Data("STRIM-CLIP-CANARY".utf8)); inp.fileHandleForWriting.closeFile(); cp.waitUntilExit()
        defer {
            let rs = Process(); rs.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let i2 = Pipe(); rs.standardInput = i2; try? rs.run()
            i2.fileHandleForWriting.write(saved); i2.fileHandleForWriting.closeFile(); rs.waitUntilExit()
        }
        o = try await e.run(r, "pbpaste")
        #expect(!o.output.contains("CANARY"), "\(o.output)")
        o = try await e.run(r, "security find-generic-password -s strim-sbx-nonexistent 2>&1; security list-keychains 2>&1")
        #expect(!o.output.contains("login.keychain"), "\(o.output)")
        let dns = try e.cProbe("dnsprobe", """
            #include <stdio.h>
            #include <netdb.h>
            int main(void) {
                struct addrinfo *res = 0;
                int rc = getaddrinfo("example.com", "80", 0, &res);
                if (rc) { printf("gaierror %s\\n", gai_strerror(rc)); return 1; }
                printf("resolved\\n"); return 0;
            }
            """)
        o = try await e.run(r, "dns-sd -G v4 localhost 2>&1 | head -2 & sleep 1.5; kill $! 2>/dev/null; '\(dns)' 2>&1 | tail -1")
        #expect(o.output.contains("Service Not Running") || o.output.contains("gaierror"), "\(o.output)")
    }

    @Test func cannotSignalOtherProcesses() async throws {
        let e = try Env()
        let victim = Process(); victim.executableURL = URL(fileURLWithPath: "/bin/sleep"); victim.arguments = ["60"]
        try victim.run(); defer { victim.terminate() }
        let pid = victim.processIdentifier
        let o = try await e.run(e.runner(), "kill -9 \(pid); echo rc=$?; sleep 30 & kill $!; echo child=$?")
        #expect(o.output.contains("rc=1") && o.output.contains("child=0"), "\(o.output)")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(victim.isRunning)
    }

    @Test func readsOutsideAllowedSetDenied() async throws {
        let e = try Env()
        // Planted file under the fake HOME (denied by the home subpath) and under the real /Users.
        try "tok".write(toFile: e.home + "/.npmrc", atomically: true, encoding: .utf8)
        try "hist".write(toFile: e.home + "/.zsh_history", atomically: true, encoding: .utf8)
        let realDir = NSHomeDirectory() + "/.strim-sbx-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: realDir) }
        try "OTHERREPO=1".write(toFile: realDir + "/.env", atomically: true, encoding: .utf8)
        let r = e.runner()
        for f in [e.home + "/.npmrc", e.home + "/.zsh_history", realDir + "/.env", NSHomeDirectory() + "/Library/Safari/History.db"] {
            let o = try await e.run(r, "cat '\(f)' 2>&1; echo rc=$?")
            #expect(!o.output.contains("rc=0") && !o.output.contains("tok") && !o.output.contains("OTHERREPO"), "\(f): \(o.output)")
        }
        var o = try await e.run(r, "ls '\(NSHomeDirectory())' 2>&1; echo rc=$?")
        #expect(!o.output.contains("rc=0"), "\(o.output)")
        // Workspace, job tmp, cwd resolution still work.
        o = try await e.run(r, "cat f.txt; pwd; ls . >/dev/null && echo ls-ok; echo t > \(e.tmp)/r && cat \(e.tmp)/r")
        #expect(o.output.contains("hello") && o.output.contains("ls-ok"), "\(o.output)")
        // Explicit extra read root under the fake home is allowed (read-only).
        let extra = SandboxProfile(access: .write, writableRoots: [e.work], jobTmp: e.tmp, home: e.home, extraReadable: [e.home + "/.npmrc"])
        o = try await ProcessRunner(profile: extra, killGrace: 0.5).run("cat \(e.home)/.npmrc; echo x > \(e.home)/.npmrc; echo rc=$?", cwd: e.work, env: [:], timeout: 10, outputCap: 1000)
        #expect(o.output.hasPrefix("tok") && !o.output.contains("rc=0"), "\(o.output)")
    }

    /// M1 (security review 2026-10-28): other tools' files in $TMPDIR, /tmp and /var/tmp are not readable by a job;
    /// the job's own tmp dir and workspace still are.
    @Test func sharedTempAreasUnreadable() async throws {
        let e = try Env()
        let fm = FileManager.default
        let tag = UUID().uuidString
        let dirs = [NSTemporaryDirectory() + "strim-m1-\(tag)", "/tmp/strim-m1-\(tag)", "/var/tmp/strim-m1-\(tag)"]
        for d in dirs {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            try "AUTHJSON-\(tag)".write(toFile: d + "/auth.json", atomically: true, encoding: .utf8)
        }
        defer { for d in dirs { try? fm.removeItem(atPath: d) } }
        let r = e.runner()
        for d in dirs {
            let o = try await e.run(r, "cat '\(d)/auth.json' 2>&1; echo rc=$?")
            #expect(!o.output.contains("AUTHJSON") && !o.output.contains("rc=0"), "\(d): \(o.output)")
        }
        let o = try await e.run(r, "echo mine > \(e.tmp)/own && cat \(e.tmp)/own && cat f.txt && git --version >/dev/null && echo tools-ok")
        #expect(o.output.contains("mine") && o.output.contains("hello") && o.output.contains("tools-ok"), "\(o.output)")
    }

    @Test func secretsStillDeniedUnderAllowedRoot() async throws {
        let e = try Env()
        // Workspace sits under HOME: HOME/proj. Allowed as a root, but HOME/.ssh stays denied.
        let proj = e.home + "/proj"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        try "p".write(toFile: proj + "/p.txt", atomically: true, encoding: .utf8)
        let r = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [proj], jobTmp: e.tmp, home: e.home), killGrace: 0.5)
        var o = try await r.run("cat p.txt; cat \(e.home)/.ssh/id_test 2>&1; echo rc=$?", cwd: proj, env: [:], timeout: 10, outputCap: 1000)
        #expect(o.output.hasPrefix("p") && !o.output.contains("secret") && !o.output.contains("rc=0"), "\(o.output)")
        // The profile must not let a root that contains HOME re-open secrets.
        let wide = ProcessRunner(profile: SandboxProfile(access: .write, writableRoots: [e.base], jobTmp: e.tmp, home: e.home), killGrace: 0.5)
        o = try await wide.run("cat \(e.home)/.ssh/id_test 2>&1; echo rc=$?", cwd: e.work, env: [:], timeout: 10, outputCap: 1000)
        #expect(!o.output.contains("secret") && !o.output.contains("rc=0"), "\(o.output)")
    }

    @Test func gitCannotRewriteParentRefs() async throws {
        let e = try Env()
        let repo = e.base + "/repo2", wtRoot = e.base + "/wt2"
        func sh(_ c: String) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", c]
            p.environment = ["PATH": ProcessRunner.defaultPath, "HOME": e.base + "/ghome", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(c)")
            return String(decoding: d, as: UTF8.self)
        }
        _ = try sh("""
            set -e; mkdir -p '\(repo)' && cd '\(repo)' && git init -q -b main && git config user.email t@t && git config user.name t \
            && echo a > a.txt && git add -A && git commit -q -m init && git worktree add -q --detach '\(wtRoot)'
            """)
        let common = repo + "/.git"
        let id = try String(contentsOfFile: wtRoot + "/.git", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/").last!
        let snap = { try sh("cd '\(common)' && find refs logs packed-refs HEAD -type f 2>/dev/null | sort | xargs shasum") }
        let before = try snap()
        // Caller (incorrectly) passes refs paths; the profile must still block ref rewrites.
        let r = ProcessRunner(profile: SandboxProfile(
            access: .write, writableRoots: [wtRoot], jobTmp: e.tmp, home: e.home,
            gitWritable: [common + "/worktrees/" + id, common + "/objects", common + "/refs", common + "/logs/refs"],
            gitControlDirs: [common]), killGrace: 0.5)
        let cmd = """
            H=$(git rev-parse HEAD)
            git update-ref refs/heads/main $H~0 2>&1; echo u=$?
            echo b > b.txt; git add -A; git -c user.email=t@t -c user.name=t commit -q -m job 2>&1; echo commit=$?
            N=$(git rev-parse HEAD)
            git update-ref refs/heads/main $N 2>&1; echo u2=$?
            git branch -f main $N 2>&1; echo bf=$?
            git tag evil $N 2>&1; echo tag=$?
            git update-ref -d refs/heads/main 2>&1; echo del=$?
            git pack-refs --all 2>&1; echo pack=$?
            """
        let o = try await r.run(cmd, cwd: wtRoot, env: [:], timeout: 60, outputCap: 20_000)
        #expect(o.output.contains("commit=0"), "detached commit must work: \(o.output)")
        for k in ["u2", "bf", "tag", "del", "pack"] { #expect(!o.output.contains("\(k)=0"), "\(k): \(o.output)") }
        #expect(try snap() == before, "parent refs changed")
        #expect(try sh("cd '\(common)' && git rev-parse main") == (try sh("cd '\(common)' && git rev-parse main")))
    }

    @Test func normalToolingStillWorks() async throws {
        let e = try Env()
        try "#!/bin/sh\ntest 1 -eq 1\n".write(toFile: e.work + "/t.sh", atomically: true, encoding: .utf8)
        try "#include <stdio.h>\nint main(){puts(\"hi-c\");}\n".write(toFile: e.work + "/a.c", atomically: true, encoding: .utf8)
        try "print(\"hi-swift\")\n".write(toFile: e.work + "/m.swift", atomically: true, encoding: .utf8)
        let gi = Process(); gi.executableURL = URL(fileURLWithPath: SandboxProfile.trustedGitPath ?? "/usr/bin/git")
        gi.arguments = ["init", "-q", "-b", "main", e.work]; try gi.run(); gi.waitUntilExit()
        // Toolchain binaries directly (the /usr/bin xcrun shims need a cache write that is denied).
        let xc = Process(); xc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); xc.arguments = ["-p"]
        let xp = Pipe(); xc.standardOutput = xp; try xc.run(); xc.waitUntilExit()
        let dev = String(decoding: xp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let tb = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        let sdk = dev + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        let haveTC = FileManager.default.isExecutableFile(atPath: tb + "/clang") && FileManager.default.fileExists(atPath: sdk)
        let cmd = """
            export SDKROOT='\(sdk)'
            git add -A && git -c user.email=t@t -c user.name=t commit -q -m x; echo git=$?
            sh t.sh 2>&1 | tail -3; echo unit=${PIPESTATUS[0]}
            '\(tb)'/clang a.c -o a.out 2>&1 | tail -3; ./a.out; echo clang=$?
            '\(tb)'/swiftc m.swift -o m.out 2>&1 | tail -3; ./m.out; echo swiftc=$?; '\(tb)'/swift --version | head -1
            ls >/dev/null; grep -r hello f.txt; sed 's/h/j/' f.txt; echo
            curl -s -m3 https://example.com >/dev/null; echo curl=$?
            """
        let o = try await e.run(e.runner(), cmd, timeout: 120)
        for k in ["git=0", "unit=0", "hello", "jello"] + (haveTC ? ["hi-c", "clang=0", "hi-swift", "swiftc=0", "swift-driver"] : []) { #expect(o.output.contains(k), "\(k): \(o.output)") }
        #expect(!o.output.contains("curl=0"), "\(o.output)")
    }

    /// Parent repo + detached worktree + runner whose profile (wrongly) lists refs as writable.
    private func gitFixture(_ e: Env, _ tag: String) throws -> (common: String, wt: String, r: ProcessRunner) {
        let repo = e.base + "/repo" + tag, wt = e.base + "/wt" + tag
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", """
            set -e; mkdir -p '\(repo)' && cd '\(repo)' && git init -q -b main && git config user.email t@t && git config user.name t \
            && echo a > a.txt && git add -A && git commit -q -m init && git worktree add -q --detach '\(wt)'
            """]
        p.environment = ["PATH": ProcessRunner.defaultPath, "HOME": e.base + "/ghome", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        try p.run(); p.waitUntilExit()
        let common = repo + "/.git"
        let id = try String(contentsOfFile: wt + "/.git", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/").last!
        let r = ProcessRunner(profile: SandboxProfile(
            access: .write, writableRoots: [wt], jobTmp: e.tmp, home: e.home,
            gitWritable: [common + "/worktrees/" + id, common + "/objects", common + "/refs", common + "/logs/refs"],
            gitControlDirs: [common]), killGrace: 0.5)
        return (common, wt, r)
    }

    @Test func caseVariantsDenied() async throws {
        let e = try Env()
        let realDir = NSHomeDirectory() + "/.strim-sbx-ci-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: realDir) }
        try "CASEPLANT".write(toFile: realDir + "/.env", atomically: true, encoding: .utf8)
        let r = e.runner()
        let variants = [realDir + "/.env", realDir.replacingOccurrences(of: "/Users", with: "/users") + "/.env",
                        (realDir + "/.env").uppercased(), e.home + "/.ssh/id_test", e.home + "/.SSH/ID_TEST", e.home.uppercased() + "/.ssh/id_test"]
        for f in variants {
            let o = try await e.run(r, "cat '\(f)' 2>&1; echo rc=$?")
            #expect(!o.output.contains("rc=0") && !o.output.contains("CASEPLANT") && !o.output.contains("secret"), "\(f): \(o.output)")
        }
        // Git control paths in mixed case (ci regexes, not literals).
        let g = try gitFixture(e, "ci")
        for t in ["head", "Orig_Head", "FETCH_head", "INDEX", "Packed-Refs", "LOGS/head", "Refs/heads/main", "refs/HEADS/main", "LoGs/refs/heads/main"] {
            let o = try await g.r.run("echo x > '\(g.common)/\(t)'; echo rc=$?", cwd: g.wt, env: [:], timeout: 20, outputCap: 5000)
            #expect(!o.output.contains("rc=0"), "\(t): \(o.output)")
        }
    }

    @Test func hardLinksIntoOrOutOfGitBlocked() async throws {
        let e = try Env()
        let g = try gitFixture(e, "ln")
        let o = try await g.r.run("""
            ln '\(g.common)/config' x1 2>&1; echo cfg=$?
            ln '\(g.common)/refs/heads/main' x2 2>&1; echo main=$?
            ln '\(g.common)/HEAD' x3 2>&1; echo head=$?
            ln a.txt '\(g.common)/refs/heads/x4' 2>&1; echo out=$?
            ln a.txt '\(g.common)/config2' 2>&1; echo out2=$?
            ln a.txt a2.txt; echo inws=$?
            """, cwd: g.wt, env: [:], timeout: 20, outputCap: 5000)
        for k in ["cfg", "main", "head", "out", "out2"] { #expect(!o.output.contains("\(k)=0"), "\(k): \(o.output)") }
        #expect(o.output.contains("inws=0"), "\(o.output)")
        #expect(!FileManager.default.fileExists(atPath: g.wt + "/x1") && !FileManager.default.fileExists(atPath: g.common + "/refs/heads/x4"))
    }

    @Test func gitCredentialFilesUnreadableButGitWorks() async throws {
        let e = try Env()
        let g = try gitFixture(e, "cr")
        try "TOKENBODY".write(toFile: g.common + "/credentials", atomically: true, encoding: .utf8)
        try "PEMBODY".write(toFile: g.common + "/k.pem", atomically: true, encoding: .utf8)
        let o = try await g.r.run("""
            cat '\(g.common)/credentials' 2>&1; echo c=$?; cat '\(g.common)/K.PEM' 2>&1; echo p=$?
            echo b > b.txt; git add -A; git -c user.email=t@t -c user.name=t commit -q -m j; echo commit=$?
            """, cwd: g.wt, env: [:], timeout: 30, outputCap: 5000)
        #expect(!o.output.contains("TOKENBODY") && !o.output.contains("PEMBODY") && !o.output.contains("c=0") && !o.output.contains("p=0"), "\(o.output)")
        #expect(o.output.contains("commit=0"), "\(o.output)")
    }

    @Test func volumesAndSharedMemoryDenied() async throws {
        let e = try Env()
        let shm = try e.cProbe("shmprobe", """
            #include <errno.h>
            #include <fcntl.h>
            #include <stdio.h>
            #include <sys/mman.h>
            #include <unistd.h>
            int main(void) {
                int fd = shm_open("/strim-sbx-probe", O_CREAT | O_RDWR, 0600);
                if (fd < 0) { printf("shm_open errno=%d\\n", errno); return 1; }
                close(fd); shm_unlink("/strim-sbx-probe"); return 0;
            }
            """)
        // Control: the same probe must succeed outside the sandbox, so the denial below is real.
        let ctl = Process(); ctl.executableURL = URL(fileURLWithPath: shm)
        try ctl.run(); ctl.waitUntilExit()
        #expect(ctl.terminationStatus == 0)
        let o = try await e.run(e.runner(), """
            ls /Volumes >/dev/null 2>&1; echo vol=$?
            '\(shm)' >/dev/null 2>&1; echo shm=$?
            """)
        #expect(!o.output.contains("vol=0") && !o.output.contains("shm=0"), "\(o.output)")
    }
}

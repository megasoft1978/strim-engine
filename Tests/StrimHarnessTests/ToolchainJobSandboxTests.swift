import Testing
import Foundation
import StrimTemplate
@testable import StrimHarness

/// The harness job sandbox (arm H, what the delegated local model's bash and verify run in) with the language toolchains: the same
/// grammar and the same hardening as the paid arms' `runtests` (no installs, no evals, no network, no credential reads, per-run scratch).
@Suite struct ToolchainJobSandboxTests {
    // MARK: command gate (the paid-arm grammar)

    @Test func gateAcceptsTestRunsAndOrdinaryShell() {
        let ok = [
            "node --test", "node --test test/a.test.ts 2>&1 | tail -20", "cd sub && node --test --test-reporter spec", "FOO=1 node --test",
            "bun test", "deno test --no-check", "cargo test --offline --quiet", "cargo test --offline -- --nocapture", "ruby -Ilib -Itest test/a_test.rb",
            "tsc --noEmit", "npm test", "npm run typecheck", "npx --no-install tsc --noEmit", "python3 -I -m unittest discover -s tests -t .", "python3 -I -B -m unittest -v",
            "go test ./...", "swift test", "sh scripts/javatest.sh", "ls -la && cat README.md | head", "cat > a.js <<'EOF'\nnode -e evil\nEOF\nnode --test",
            "echo \"node -e is not run\"", "grep -rn 'pip install' docs", "git status", "node --test > out.txt 2>&1", "bash -c 'node --test'",
        ]
        for c in ok { #expect(ToolchainGuard.check(c) == nil, "\(c): \(ToolchainGuard.check(c) ?? "")") }
    }

    @Test func gateRefusesWhatRuntestsRefuses() {
        let bad = [
            "npm install", "npm i left-pad", "npm ci", "npx cowsay hi", "npx --yes cowsay", "bun x cowsay", "bun add left-pad", "deno run x.ts", "deno eval 1",
            "node -e 'require(\"child_process\")'", "node --eval 1", "node script.js", "node --test --require x.js", "node --test /etc/passwd", "node --test ../x",
            "cargo run", "cargo install ripgrep", "cargo fetch", "cargo test", "cargo test --offline --config x=y", "cargo +nightly test --offline",
            "ruby -e 'puts 1'", "ruby -rsocket test/a.rb", "ruby /etc/x.rb", "tsc", "tsc --noEmit --build",
            "python3 -c 'import os'", "python3 x.py", "python3 -m pip install x", "python3 -I -m http.server", "python3 -m unittest", "python -c 1",
            "pip install x", "pip3 install x", "gem install x", "bundle install", "yarn add x", "pnpm install", "rustup update", "rustc x.rs", "mvn test", "gradle test",
            "java -jar x.jar", "javac X.java",
            // hidden behind wrappers, shells, substitution, pipelines and lists
            "env node -e 1", "FOO=1 nice -n 5 node -e 1", "sh -c 'npm install'", "bash -lc \"pip install x\"", "eval 'npm i x'", "echo hi; npm install", "true && cargo run",
            "cat x | node script.js", "echo $(npm install)", "echo `pip install x`", "echo \"$(node -e 1)\"", "xargs npm install", "( node -e 1 )", "/opt/homebrew/bin/node -e 1",
            "cd sub; exec python3 -c 1", "node --test; node -p 1",
        ]
        for c in bad { #expect(ToolchainGuard.check(c) != nil, "\(c) was accepted") }
    }

    @Test func gateIsParityWithTheGrammarForEveryRunner() {
        // Every runner form the table accepts passes the gate, every form it refuses is refused (python spelled python3 here).
        let forms: [[String]] = [["node", "--test"], ["node", "-e", "1"], ["bun", "test"], ["bun", "x", "y"], ["deno", "test"], ["deno", "run", "x"],
                                 ["cargo", "test", "--offline"], ["cargo", "test"], ["ruby", "-Itest", "test/a_test.rb"], ["ruby", "-e", "1"],
                                 ["tsc", "--noEmit"], ["tsc"], ["npm", "test"], ["npm", "install"], ["npx", "--no-install", "tsc"], ["npx", "tsc"],
                                 ["python3", "-I", "-m", "unittest"], ["python3", "-c", "1"]]
        for f in forms {
            let table = RunTestsGrammar.validate(f) == nil
            #expect((ToolchainGuard.check(f.joined(separator: " ")) == nil) == table, "\(f)")
        }
    }

    @Test func bashToolRefusesWithoutRunningAndKeepsTheExitCodeLine() async throws {
        let base = tmpBase(), work = base + "/work", tmp = base + "/tmp"
        for d in [work, tmp] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        let tool = BashTool(runner: BashTool.makeRunner(workspaceRoot: work, access: .write, jobTmp: tmp))
        let r = try await tool.run(["command": .string("npm install left-pad; touch \(work)/ran")], context: ToolContext(root: work, access: .write))
        #expect(r.isError && r.output.contains("refused") && r.output.hasSuffix("[exit code: 64]"), "\(r.output)")
        #expect(!FileManager.default.fileExists(atPath: work + "/ran"))
        let ok = try await tool.run(["command": .string("echo fine")], context: ToolContext(root: work, access: .write))
        #expect(ok.output == "fine\n[exit code: 0]")
    }

    // MARK: profile and environment

    @Test func readGrantsAreTheThreeVersionRootsOnly() throws {
        let home = tmpBase() + "/home"
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        for d in [".nvm/versions", ".rustup/toolchains", ".rbenv/versions", ".cargo", ".npm", ".bun", ".deno", ".m2", ".gem", ".gradle", ".config/gh", ".ssh", ".aws", ".docker"] {
            try FileManager.default.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
        }
        let p = BashTool.jobProfile(workspaceRoot: "/tmp/w", access: .write, jobTmp: "/tmp/j", home: home)
        #expect(Set(p.extraReadable) == Set([".nvm/versions", ".rustup/toolchains", ".rbenv/versions"].map { home + "/" + $0 }))
        let text = p.profile
        for d in [".cargo", ".npm", ".bun", ".deno", ".m2", ".gem", ".gradle", ".docker"] { #expect(!text.contains("\"" + home + "/" + d), "\(d) is not granted") }
        // credential denies stay last and unchanged
        let realHome = BashTool.jobProfile(workspaceRoot: "/tmp/w", access: .write, jobTmp: "/tmp/j").profile
        for s in SandboxProfile.secretSubpaths { #expect(realHome.contains(NSHomeDirectory() + "/" + s)) }
        for l in SandboxProfile.secretLiterals { #expect(realHome.contains(NSHomeDirectory() + "/" + l)) }
    }

    @Test func environmentIsOfflineScratchLocalAndFreeOfInjectionVariables() throws {
        let home = tmpBase() + "/home", tmp = tmpBase() + "/jobtmp"
        defer { for d in [home, tmp] { try? FileManager.default.removeItem(atPath: (d as NSString).deletingLastPathComponent) } }
        for d in [".nvm/versions/node/v99.0.0/bin", ".rustup/toolchains/stable-x/bin", ".rbenv/versions/3.9.9/bin"] {
            try FileManager.default.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
        }
        setenv("NODE_OPTIONS", "--require /evil.js", 1); setenv("PYTHONPATH", "/evil", 1); setenv("RUBYOPT", "-r/evil", 1); setenv("RUSTC_WRAPPER", "/evil", 1)
        defer { for k in ["NODE_OPTIONS", "PYTHONPATH", "RUBYOPT", "RUSTC_WRAPPER"] { unsetenv(k) } }
        var r = BashTool.makeRunner(workspaceRoot: "/tmp/w", access: .write, jobTmp: tmp, home: home)
        r.passthroughEnv = ["NODE_OPTIONS", "PYTHONPATH", "RUBYOPT", "RUSTC_WRAPPER"]
        let e = r.buildEnv([:])
        let path = e["PATH"] ?? ""
        #expect(path.contains(home + "/.nvm/versions/node/v99.0.0/bin") && path.contains(home + "/.rustup/toolchains/stable-x/bin") && path.contains(home + "/.rbenv/versions/3.9.9/bin"))
        #expect(path.hasSuffix(ProcessRunner.defaultPath))
        for k in ["NODE_OPTIONS", "PYTHONPATH", "RUBYOPT", "RUSTC_WRAPPER", "NODE_PATH", "JAVA_TOOL_OPTIONS"] { #expect(e[k] == nil, "\(k)") }
        for k in ["npm_config_cache", "DENO_DIR", "BUN_INSTALL_CACHE_DIR", "CARGO_HOME", "CARGO_TARGET_DIR"] { #expect(e[k]?.hasPrefix(tmp + "/") == true, "\(k)") }
        #expect(e["npm_config_offline"] == "true" && e["CARGO_NET_OFFLINE"] == "true" && e["HOME"] == tmp + "/home" && e["TMPDIR"] == tmp)
        // host secrets are not inherited
        #expect(e["HOME"] != NSHomeDirectory())
    }

    @Test func verifyGetsItsOwnCachesNotTheAgentOnes() async throws {
        let base = tmpBase(), work = base + "/work", tmp = base + "/tmp"
        for d in [work, tmp] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        let runner = BashTool.makeRunner(workspaceRoot: work, access: .write, jobTmp: tmp)
        let res = await HarnessRunner.runVerify("printf '%s\\n%s\\n%s' \"$CARGO_TARGET_DIR\" \"$npm_config_cache\" \"$HOME\"", root: work, jobTmp: tmp, runner: runner, timeout: 30)
        #expect(res.status == .verified, "\(res.outputTail)")
        let lines = res.outputTail.split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && lines.allSatisfy { $0.contains("/verify-") }, "\(lines)")
    }

    // MARK: canaries and end-to-end with the real toolchains

    static func exists(_ p: String) -> Bool { FileManager.default.isExecutableFile(atPath: p) }
    static var haveNode: Bool { Toolchains.pathDirs(home: NSHomeDirectory()).contains { exists($0 + "/node") } }
    static var haveBun: Bool { exists("/opt/homebrew/bin/bun") }
    static var haveDeno: Bool { exists("/opt/homebrew/bin/deno") }
    static var haveRuby: Bool { Toolchains.pathDirs(home: NSHomeDirectory()).contains { exists($0 + "/ruby") } }
    static var haveCargo: Bool { Toolchains.pathDirs(home: NSHomeDirectory()).contains { exists($0 + "/cargo") } }
    static var havePython: Bool { Toolchains.pythonHome() != nil }
    static var haveJava: Bool { Toolchains.jdkHome() != nil }

    func tmpBase() -> String { NSTemporaryDirectory() + "strim-tc-\(UUID().uuidString)" }

    func put(_ root: String, _ rel: String, _ body: String) throws {
        let p = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try body.write(toFile: p, atomically: true, encoding: .utf8)
    }

    func javaRunnerScript() throws -> String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return try String(contentsOf: u.appendingPathComponent("bench/agenttasks/shared/javatest.sh"), encoding: .utf8)
    }

    func listener() -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 8)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// Files named like credentials and toolchain neighbours, planted in directories that already exist (never new dirs).
    func plantCanaries() -> [String] {
        let home = NSHomeDirectory(), fm = FileManager.default, id = UUID().uuidString
        var out: [String] = []
        for s in ["", ".cargo", ".gem", ".m2", ".docker", ".config", ".aws", ".ssh", ".npm", ".bun", ".deno", ".nvm", ".rustup", ".rbenv", ".gradle"] {
            let dir = s.isEmpty ? home : home + "/" + s
            guard fm.fileExists(atPath: dir) else { continue }
            let p = dir + "/" + (s.isEmpty ? ".npmrc-canary-\(id)" : "credentials-canary-\(id)")
            if (try? "token=SECRET".write(toFile: p, atomically: true, encoding: .utf8)) != nil { out.append(p) }
        }
        return out
    }

    /// Runs `command` through the BashTool (gate on) in the real harness job sandbox. The probe project must pass, so the toolchain runs, while
    /// every canary credential, the loopback listener and the internet are unreachable and nothing outside the worktree is writable.
    func probe(_ command: String, have: Bool, expectMarker: Bool = true, files: (_ list: String, _ outsideWrite: String, _ marker: String, _ port: Int) -> [String: String]) async throws {
        guard have else { return }
        let canaries = plantCanaries(); defer { for p in canaries { try? FileManager.default.removeItem(atPath: p) } }
        #expect(!canaries.isEmpty)
        for p in canaries { #expect((try? String(contentsOfFile: p, encoding: .utf8)) == "token=SECRET") }   // control: the host reads them
        let base = tmpBase(), work = base + "/work", tmp = base + "/tmp"
        for d in [work, tmp] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        let other = base + "/other-run.txt"; try put(base, "other-run.txt", "another run")
        let (lfd, lport) = listener(); defer { close(lfd) }
        let outsideWrite = base + "/pwned.txt", marker = work + "/ran.marker"
        let list = (canaries + [other, NSHomeDirectory() + "/.ssh/known_hosts", NSHomeDirectory() + "/.strim/token"]).joined(separator: "\n")
        for (rel, body) in files(list, outsideWrite, marker, Int(lport)) { try put(work, rel, body) }
        let tool = BashTool(runner: BashTool.makeRunner(workspaceRoot: work, access: .write, jobTmp: tmp))
        let r = try await tool.run(["command": .string(command), "timeout_s": .int(280)], context: ToolContext(root: work, access: .write))
        #expect(!r.isError, "\(command): \(r.output.suffix(1500))")
        if expectMarker { #expect(FileManager.default.fileExists(atPath: marker), "\(command): probe did not run") } else { #expect(r.output.contains("1 passed") || r.output.contains("ok"), "\(r.output)") }
        #expect(!FileManager.default.fileExists(atPath: outsideWrite))
    }

    @Test func nodeRunsIsolated() async throws {
        try await probe("node --test", have: Self.haveNode) { list, outsideWrite, marker, port in
            ["test/probe.test.js": """
            const test = require('node:test'); const fs = require('node:fs'); const net = require('node:net');
            const assert = require('node:assert/strict');
            test('isolated', async () => {
              for (const p of `\(list)`.split('\\n')) { let got = ''; try { got = fs.readFileSync(p, 'utf8'); } catch (e) {} assert.equal(got, '', 'read ' + p); }
              for (const [h, pt] of [['127.0.0.1', \(port)], ['1.1.1.1', 443]]) {
                await new Promise((res, rej) => { const s = net.connect({ host: h, port: pt, timeout: 1500 }); s.on('connect', () => { s.destroy(); rej(new Error('connected ' + h)); }); s.on('error', () => res()); s.on('timeout', () => { s.destroy(); res(); }); });
              }
              assert.throws(() => fs.writeFileSync('\(outsideWrite)', 'x'));
              fs.writeFileSync('\(marker)', 'x');
            });
            """]
        }
    }

    @Test func bunRunsIsolated() async throws {
        try await probe("bun test", have: Self.haveBun) { list, outsideWrite, marker, port in
            ["probe.test.js": """
            import { test, expect } from 'bun:test'; import fs from 'node:fs'; import net from 'node:net';
            test('isolated', async () => {
              for (const p of `\(list)`.split('\\n')) { let got = ''; try { got = fs.readFileSync(p, 'utf8'); } catch (e) {} expect(got).toBe(''); }
              for (const [h, pt] of [['127.0.0.1', \(port)], ['1.1.1.1', 443]]) {
                const ok = await new Promise((res) => { const s = net.connect({ host: h, port: pt }); s.on('connect', () => { s.destroy(); res(true); }); s.on('error', () => res(false)); setTimeout(() => { s.destroy(); res(false); }, 1500); });
                expect(ok).toBe(false);
              }
              expect(() => fs.writeFileSync('\(outsideWrite)', 'x')).toThrow();
              fs.writeFileSync('\(marker)', 'x');
            });
            """]
        }
    }

    @Test func denoRunsWithoutPermissions() async throws {
        try await probe("deno test --no-check", have: Self.haveDeno, expectMarker: false) { list, outsideWrite, marker, port in
            ["probe_test.ts": """
            Deno.test('no permissions', async () => {
              let threw = 0;
              for (const p of `\(list)`.split('\\n')) { try { Deno.readTextFileSync(p); } catch { threw++; } }
              if (threw !== `\(list)`.split('\\n').length) throw new Error('read a protected file');
              try { await Deno.connect({ hostname: '127.0.0.1', port: \(port) }); throw new Error('connected'); } catch (e) { if (String(e).includes('connected')) throw e; }
              try { Deno.writeTextFileSync('\(outsideWrite)', 'x'); throw new Error('wrote'); } catch (e) { if (String(e).includes('wrote')) throw e; }
            });
            """]
        }
    }

    @Test func rubyRunsIsolated() async throws {
        try await probe("ruby -Itest test/probe_test.rb", have: Self.haveRuby) { list, outsideWrite, marker, port in
            ["test/probe_test.rb": """
            require 'minitest/autorun'
            require 'socket'
            class ProbeTest < Minitest::Test
              def test_isolated
                '\(list)'.split("\\n").each { |p| got = (File.read(p) rescue ''); assert_equal '', got, "read #{p}" }
                [['127.0.0.1', \(port)], ['1.1.1.1', 443]].each do |h, pt|
                  ok = begin; Socket.tcp(h, pt, connect_timeout: 1.5) { true }; rescue StandardError; false; end
                  refute ok, "connected #{h}"
                end
                assert_raises(StandardError) { File.write('\(outsideWrite)', 'x') }
                File.write('\(marker)', 'x')
              end
            end
            """]
        }
    }

    @Test func cargoRunsIsolated() async throws {
        try await probe("cargo test --offline --quiet", have: Self.haveCargo) { list, outsideWrite, marker, port in
            ["Cargo.toml": "[package]\nname = \"probe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
             "src/lib.rs": """
             #[cfg(test)]
             mod tests {
                 use std::{fs, net::{TcpStream, SocketAddr}, time::Duration};
                 #[test]
                 fn isolated() {
                     for p in "\(list)".lines() { assert!(fs::read_to_string(p).map(|s| s.is_empty()).unwrap_or(true), "read {}", p); }
                     for a in ["127.0.0.1:\(port)", "1.1.1.1:443"] {
                         let addr: SocketAddr = a.parse().unwrap();
                         assert!(TcpStream::connect_timeout(&addr, Duration::from_millis(1500)).is_err(), "connected {}", a);
                     }
                     assert!(fs::write("\(outsideWrite)", "x").is_err());
                     fs::write("\(marker)", "x").unwrap();
                 }
             }
             """]
        }
    }

    @Test func pythonRunsIsolated() async throws {
        try await probe("python3 -I -B -m unittest discover -s tests -t .", have: Self.havePython) { list, outsideWrite, marker, port in
            let plist = list.replacingOccurrences(of: "\n", with: "|")
            return ["tests/__init__.py": "",
             "tests/test_probe.py": """
             import socket, unittest
             class Probe(unittest.TestCase):
                 def test_isolated(self):
                     for p in '\(plist)'.split('|'):
                         try:
                             got = open(p).read()
                         except OSError:
                             got = ''
                         self.assertEqual(got, '', 'read ' + p)
                     for h, pt in [('127.0.0.1', \(port)), ('1.1.1.1', 443)]:
                         s = socket.socket()
                         s.settimeout(1.5)
                         with self.assertRaises(OSError):
                             s.connect((h, pt))
                         s.close()
                     with self.assertRaises(OSError):
                         open('\(outsideWrite)', 'w').write('x')
                     open('\(marker)', 'w').write('x')
             """]
        }
    }

    @Test func javaRunnerIsIsolated() async throws {
        let script = try javaRunnerScript()
        try await probe("sh scripts/javatest.sh", have: Self.haveJava) { list, outsideWrite, marker, port in
            ["scripts/javatest.sh": script,
             "src/tests/AllTests.java": """
             package tests;
             import java.io.*; import java.net.*; import java.nio.file.*;
             public class AllTests {
                 public static void main(String[] a) throws Exception {
                     for (String p : "\(list.replacingOccurrences(of: "\n", with: "\\n"))".split("\\n")) { try { String s = new String(Files.readAllBytes(Paths.get(p))); if (!s.isEmpty()) { System.out.println("read " + p); System.exit(1); } } catch (Exception e) {} }
                     for (String h : new String[] {"127.0.0.1:\(port)", "1.1.1.1:443"}) {
                         String[] hp = h.split(":");
                         try (Socket s = new Socket()) { s.connect(new InetSocketAddress(hp[0], Integer.parseInt(hp[1])), 1500); System.out.println("connected " + h); System.exit(1); } catch (IOException e) {}
                     }
                     try { Files.write(Paths.get("\(outsideWrite)"), "x".getBytes()); System.out.println("wrote outside"); System.exit(1); } catch (IOException e) {}
                     Files.write(Paths.get("\(marker)"), "x".getBytes());
                 }
             }
             """]
        }
    }

    // MARK: end to end: the harness verify step, no model

    /// `HarnessRunner.runVerify` with the job runner: a passing project verifies, the same project with a broken assertion fails.
    func verifyE2E(_ command: String, have: Bool, files: [String: String], broken: [String: String]) async throws {
        guard have else { return }
        let base = tmpBase(), work = base + "/work", tmp = base + "/tmp"
        for d in [work, tmp] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        for (rel, body) in files { try put(work, rel, body) }
        let runner = BashTool.makeRunner(workspaceRoot: work, access: .write, jobTmp: tmp)
        let good = await HarnessRunner.runVerify(command, root: work, jobTmp: tmp, runner: runner, timeout: 280)
        #expect(good.status == .verified && good.exitCode == 0, "\(command): \(good.outputTail)")
        for (rel, body) in broken { try put(work, rel, body) }
        let bad = await HarnessRunner.runVerify(command, root: work, jobTmp: tmp, runner: runner, timeout: 280)
        #expect(bad.status == .failed && bad.exitCode != 0, "\(command): \(bad.outputTail)")
    }

    @Test func verifyTypeScriptWithNodeTest() async throws {
        func t(_ expect: Int) -> [String: String] {
            ["sum.ts": "export function sum(a: number, b: number): number { return a + b; }\n",
             "sum.test.ts": "import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport { sum } from './sum.ts';\ntest('sum', () => { assert.equal(sum(1, 2), \(expect)); });\n"]
        }
        try await verifyE2E("node --test --experimental-strip-types", have: Self.haveNode, files: t(3), broken: t(4))
    }

    @Test func verifyPythonUnittest() async throws {
        func t(_ expect: Int) -> [String: String] {
            ["calc.py": "def add(a, b):\n    return a + b\n", "tests/__init__.py": "",
             "tests/test_calc.py": "import unittest\nfrom calc import add\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(1, 2), \(expect))\n"]
        }
        try await verifyE2E("python3 -I -B -m unittest discover -s tests -t .", have: Self.havePython, files: t(3), broken: t(4))
    }

    @Test func verifyRustCargoTest() async throws {
        func t(_ expect: Int) -> [String: String] {
            ["Cargo.toml": "[package]\nname = \"calc\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
             "src/lib.rs": "pub fn add(a: i32, b: i32) -> i32 { a + b }\n#[cfg(test)]\nmod tests {\n    use super::*;\n    #[test]\n    fn adds() { assert_eq!(add(1, 2), \(expect)); }\n}\n"]
        }
        try await verifyE2E("cargo test --offline --quiet", have: Self.haveCargo, files: t(3), broken: t(4))
    }

    @Test func verifyJavaRunner() async throws {
        let script = try javaRunnerScript()
        func t(_ expect: Int) -> [String: String] {
            ["scripts/javatest.sh": script, "src/main/Calc.java": "package main;\npublic class Calc { public static int add(int a, int b) { return a + b; } }\n",
             "src/tests/AllTests.java": "package tests;\nimport main.Calc;\npublic class AllTests {\n  public static void main(String[] a) { if (Calc.add(1, 2) != \(expect)) { System.out.println(\"FAIL\"); System.exit(1); } System.out.println(\"ok\"); }\n}\n"]
        }
        try await verifyE2E("sh scripts/javatest.sh", have: Self.haveJava, files: t(3), broken: t(4))
    }
}

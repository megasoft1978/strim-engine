import Foundation
import Testing
@testable import StrimControl

private func spec(_ home: String) -> LaunchAgentSpec {
    LaunchAgentSpec(binary: "/opt/strim/bin/strim", model: "/models/Qwen3.8-27B", mtpHead: "/models/head", port: 8203,
                    tokenFile: "/Users/u/.strim/token", logDir: home + "/.strim/logs", home: home)
}

@Suite("install-agent plist")
struct LaunchAgentTests {
    @Test("golden plist content")
    func golden() throws {
        let data = try LaunchAgent.plistData(spec("/Users/u"))
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>EnvironmentVariables</key>
        \t<dict>
        \t\t<key>HOME</key>
        \t\t<string>/Users/u</string>
        \t\t<key>PATH</key>
        \t\t<string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
        \t</dict>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>com.strim.host</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/opt/strim/bin/strim</string>
        \t\t<string>serve</string>
        \t\t<string>/models/Qwen3.8-27B</string>
        \t\t<string>/models/head</string>
        \t\t<string>--port</string>
        \t\t<string>8203</string>
        \t\t<string>--token-file</string>
        \t\t<string>/Users/u/.strim/token</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>StandardErrorPath</key>
        \t<string>/Users/u/.strim/logs/host.err.log</string>
        \t<key>StandardOutPath</key>
        \t<string>/Users/u/.strim/logs/host.out.log</string>
        \t<key>ThrottleInterval</key>
        \t<integer>30</integer>
        \t<key>WorkingDirectory</key>
        \t<string>/Users/u</string>
        </dict>
        </plist>

        """
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test("install writes only under the given dir; round-trips; prints (never runs) launchctl bootstrap")
    func install() throws {
        let dir = tmpDir("la").path
        let logs = tmpDir("lalogs").path
        var s = spec("/Users/u"); s.logDir = logs + "/logs"; s.runAtLoad = false; s.label = "com.example.t"
        let o = try LaunchAgent.install(s, dir: dir + "/LaunchAgents", dryRun: false)
        #expect(o.plistPath == dir + "/LaunchAgents/com.example.t.plist" && o.written)
        #expect(o.command == "launchctl bootstrap gui/\(getuid()) \(o.plistPath)")
        let obj = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: o.plistPath)), format: nil) as! [String: Any]
        #expect(obj["Label"] as? String == "com.example.t" && obj["RunAtLoad"] as? Bool == false && obj["KeepAlive"] as? Bool == true)
        #expect(obj["ProgramArguments"] as? [String] == s.programArguments)
        #expect(obj["StandardOutPath"] as? String == logs + "/logs/host.out.log")
        let mode = try FileManager.default.attributesOfItem(atPath: o.plistPath)[.posixPermissions] as! Int
        #expect(mode & 0o022 == 0, "launchd refuses group/world-writable plists")
        #expect(FileManager.default.fileExists(atPath: logs + "/logs"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir + "/LaunchAgents")
        #expect(files == ["com.example.t.plist"], "no temp files left")
        // reinstall replaces in place
        s.port = 9000
        try LaunchAgent.install(s, dir: dir + "/LaunchAgents", dryRun: false)
        let again = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: o.plistPath)), format: nil) as! [String: Any]
        #expect((again["ProgramArguments"] as! [String]).contains("9000"))
    }

    @Test("dry run touches nothing and returns the plist text")
    func dryRun() throws {
        let dir = tmpDir("ladry").path + "/nope"
        let o = try LaunchAgent.install(spec("/Users/u"), dir: dir, dryRun: true)
        #expect(!o.written && o.plist?.contains("com.strim.host") == true)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test("uninstall removes only the regular plist file and prints bootout")
    func uninstall() throws {
        let dir = tmpDir("launinst").path
        var s = spec("/Users/u"); s.logDir = dir + "/l"
        let o = try LaunchAgent.install(s, dir: dir, dryRun: false)
        let dry = try LaunchAgent.uninstall(label: s.label, dir: dir, dryRun: true)
        #expect(dry.command == "launchctl bootout gui/\(getuid())/com.strim.host" && FileManager.default.fileExists(atPath: o.plistPath))
        try LaunchAgent.uninstall(label: s.label, dir: dir, dryRun: false)
        #expect(!FileManager.default.fileExists(atPath: o.plistPath))
        try LaunchAgent.uninstall(label: s.label, dir: dir, dryRun: false)   // already gone: fine
        // a symlink at the plist path is never followed or removed
        let target = dir + "/target"; try "x".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: o.plistPath, withDestinationPath: target)
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.uninstall(label: s.label, dir: dir, dryRun: false) }
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.install(s, dir: dir, dryRun: false) }
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test("labels with path separators or odd characters are rejected")
    func labels() {
        for bad in ["", "../x", "a/b", ".hidden", "sp ace", "x\u{0}y"] {
            #expect(throws: LaunchAgentError.self) { try LaunchAgent.validate(label: bad) }
        }
        #expect(throws: Never.self) { try LaunchAgent.validate(label: "com.strim.host-2_a") }
    }

    @Test("binary validation: resolves, refuses temp dirs, writable files/dirs, non-executables; override allows")
    func binary() throws {
        #expect(try LaunchAgent.validateBinary("/usr/bin/true", allowUnsafe: false).hasSuffix("/true"))
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.validateBinary("/nonexistent/strim", allowUnsafe: false) }
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.validateBinary("/usr/bin", allowUnsafe: false) }   // directory
        // a perfectly good executable, but in the temp dir
        let tmp = tmpDir("bin").path + "/strim"
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: tmp)
        chmod(tmp, 0o755)
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.validateBinary(tmp, allowUnsafe: false) }
        #expect(try LaunchAgent.validateBinary(tmp, allowUnsafe: true).hasSuffix("/strim"))
        // not executable
        let plain = tmpDir("bin2").path + "/x"; try "x".write(toFile: plain, atomically: true, encoding: .utf8)
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.validateBinary(plain, allowUnsafe: true) }
        // world-writable directory / group-writable file outside the temp dirs (under $HOME)
        let home = NSHomeDirectory() + "/.strim-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bin = home + "/strim"
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: bin); chmod(bin, 0o755)
        #expect(try LaunchAgent.validateBinary(bin, allowUnsafe: false).hasSuffix("/strim"))
        chmod(bin, 0o775)
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.validateBinary(bin, allowUnsafe: false) }
        chmod(bin, 0o755); chmod(home, 0o777)
        #expect(throws: LaunchAgentError.self) { try LaunchAgent.validateBinary(bin, allowUnsafe: false) }
        // a relative symlink in a writable place resolves to its real target
        chmod(home, 0o755)
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: "strim")
        #expect(try LaunchAgent.validateBinary(home + "/link", allowUnsafe: false) == (try LaunchAgent.validateBinary(bin, allowUnsafe: false)))
    }

    @Test("currentExecutablePath is absolute and exists")
    func exe() {
        let p = currentExecutablePath()
        #expect(p?.hasPrefix("/") == true && FileManager.default.fileExists(atPath: p ?? ""))
    }
}

import Foundation
import Testing
@testable import StrimAppCore

private func tmpDir() throws -> String {
    let d = NSTemporaryDirectory() + "strim-sl-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func write(_ s: String, _ p: String) throws { try Data(s.utf8).write(to: URL(fileURLWithPath: p)) }
private func perms(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions]) as? Int) ?? -1 }
@discardableResult private func script(_ body: String, at p: String, mode: Int = 0o755) throws -> String {
    try write("#!/bin/sh\n" + body + "\n", p)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: p)
    return p
}

@Suite struct SettingsLoadTests {
    // MARK: older formats and odd shapes

    @Test func firstReleaseFormatLoads() throws {
        // 99d0e6e: host_url, strim_binary, model_path, mtp_path, token_path (later renamed control_token_path).
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"{"host_url":"http://127.0.0.1:9100","strim_binary":"/usr/local/bin/strim","model_path":"/m","mtp_path":"/h","token_path":"/Users/x/.strim/token"}"#, p)
        let s = AppSettings.load(path: p)
        #expect(s.hostURL == "http://127.0.0.1:9100" && s.modelPath == "/m" && s.mtpPath == "/h" && s.port == 9100)
        #expect(s.strimBinary == "/usr/local/bin/strim")
        #expect(s.controlTokenPath == AppPaths.defaultControlTokenPath && s.startServerWhenOpens && s.showSpeedInMenuBar)
        #expect(s.unknownKeys["token_path"] == .string("/Users/x/.strim/token"))
    }
    @Test func emptyAndMinimalObjectsGiveDefaults() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write("{}", p); #expect(AppSettings.load(path: p) == AppSettings())
        #expect(!FileManager.default.fileExists(atPath: d + "/app.json.bad"))
        try write(#"{"project_path":"/p"}"#, p)
        let s = AppSettings.load(path: p)
        #expect(s.projectPath == "/p" && s.modelPath == nil && s.recentProjects.isEmpty)
    }
    @Test func wrongTypesFallBackPerKeyAndKeepTheRest() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"""
        {"start_server_when_opens":"false","show_speed_in_menu_bar":0,"model_path":12,"mtp_path":["a"],
         "host_url":9000,"recent_projects":"x","project_path":true,"strim_binary":{"a":1},"control_token_path":null}
        """#, p)
        let r = AppSettings.loadReport(path: p)
        #expect(r.notice == nil)
        let s = r.settings
        #expect(s.startServerWhenOpens && s.showSpeedInMenuBar)
        #expect(s.modelPath == nil && s.mtpPath == nil && s.projectPath == nil && s.strimBinary == nil)
        #expect(s.hostURL == AppPaths.defaultHostURL && s.recentProjects.isEmpty && s.controlTokenPath == AppPaths.defaultControlTokenPath)
        try write(#"{"model_path":"/ok","start_server_when_opens":"nope"}"#, p)
        #expect(AppSettings.load(path: p).modelPath == "/ok")   // one bad key does not discard a good one
    }
    @Test func blankPathsAreUnset() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"{"model_path":"   ","mtp_path":"\t\n","strim_binary":" ","project_path":""}"#, p)
        let s = AppSettings.load(path: p)
        #expect(s.modelPath == nil && s.mtpPath == nil && s.strimBinary == nil && s.projectPath == nil)
        #expect(HostCommand.arguments(settings: s) == nil)
        #expect(ProcessHostLauncher().start(settings: s) == .needsModel)
    }
    @Test func paddedPathsAreTrimmed() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"{"model_path":"  /m/x \n"}"#, p)
        #expect(AppSettings.load(path: p).modelPath == "/m/x")
    }

    // MARK: corrupt file

    @Test func corruptFileIsBackedUpNotLost() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        let bad = #"{"model_path":"/precious","host_url":"#   // truncated
        try write(bad, p)
        let r = AppSettings.loadReport(path: p, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(r.settings == AppSettings())
        let backup = try #require(r.backupPath)
        let kept = try String(contentsOfFile: backup, encoding: .utf8)
        #expect(backup.hasPrefix(p + ".bad-") && kept == bad)
        #expect(perms(backup) == 0o600)
        #expect(r.notice?.contains(backup) == true)
        // A save after the failed load must not be the only copy of anything.
        try r.settings.save(path: p)
        #expect(FileManager.default.fileExists(atPath: backup))
    }
    @Test func nonObjectJSONCountsAsCorrupt() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        for (i, body) in ["[1,2]", "", "\"str\"", "\u{0}\u{1}garbage"].enumerated() {
            try write(body, p)
            let r = AppSettings.loadReport(path: p, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
            #expect(r.settings == AppSettings() && r.backupPath != nil, "body \(body.debugDescription)")
        }
    }
    @Test func corruptLoadReportsNoticeWithoutGlobalState() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write("{{{", p)
        let r = AppSettings.loadReport(path: p)
        #expect(r.notice?.contains(".bad-") == true && r.backupPath != nil)
        // `load` is a plain wrapper: it returns defaults and reports nothing on its own.
        #expect(AppSettings.load(path: p) == AppSettings())   // file moved away: now simply missing
        #expect(AppSettings.loadReport(path: p).notice == nil)
        #expect(AppSettings.loadReport(path: d + "/other.json").notice == nil)
    }
    @Test func twoCorruptionsInOneSecondKeepBothBackups() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write("one{", p); let a = AppSettings.loadReport(path: p, now: now).backupPath
        try write("two{", p); let b = AppSettings.loadReport(path: p, now: now).backupPath
        #expect(a != nil && b != nil && a != b)
        let ta = try String(contentsOfFile: a!, encoding: .utf8), tb = try String(contentsOfFile: b!, encoding: .utf8)
        #expect(ta == "one{" && tb == "two{")
    }

    // MARK: save

    @Test func saveIsAtomic0600AndLeavesNoTemp() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let dir = d + "/sub"
        let p = dir + "/app.json"
        var s = AppSettings(); s.modelPath = "/m"
        try s.save(path: p)
        #expect(perms(p) == 0o600 && perms(dir) == 0o700)
        s.modelPath = "/m2"; try s.save(path: p)
        #expect(AppSettings.load(path: p).modelPath == "/m2" && perms(p) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["app.json"])
    }
    @Test func roundTripPreservesUnknownKeys() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"{"model_path":"/m","future_flag":true,"future_obj":{"a":[1,"x",null]},"token_path":"/t"}"#, p)
        var s = AppSettings.load(path: p)
        s.modelPath = "/m2"
        try s.save(path: p)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as? [String: Any])
        #expect(obj["future_flag"] as? Bool == true && obj["token_path"] as? String == "/t" && obj["model_path"] as? String == "/m2")
        let nested = (obj["future_obj"] as? [String: Any])?["a"] as? [Any]
        #expect(nested?.count == 3 && nested?[1] as? String == "x" && nested?[2] is NSNull)
        #expect(AppSettings.load(path: p) == s)
    }
    @Test func unknownKeyCannotShadowKnownKey() throws {
        var s = AppSettings(modelPath: "/real"); s.unknownKeys["model_path"] = .string("/shadow")
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        try s.save(path: d + "/a.json")
        #expect(AppSettings.load(path: d + "/a.json").modelPath == "/real")
    }

    // MARK: path expansion

    @Test func tildeAndRelativePathsExpand() {
        #expect(HostCommand.expandPath("~", home: "/h") == "/h")
        #expect(HostCommand.expandPath("~/models/q", home: "/h") == "/h/models/q")
        #expect(HostCommand.expandPath("models/q", home: "/h") == "/h/models/q")
        #expect(HostCommand.expandPath("/abs/q", home: "/h") == "/abs/q")
        #expect(HostCommand.expandPath("~other/q", home: "/h") == "/h/~other/q")   // no user lookup; never silently wrong-user
        let a = HostCommand.arguments(settings: AppSettings(modelPath: "~/m", mtpPath: "rel/h"))
        #expect(a == ["serve", AppPaths.home + "/m", AppPaths.home + "/rel/h", "--port", "8203"])
    }

    // MARK: binary resolution

    @Test func resolutionOrderBundledThenSiblingThenPath() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        for n in ["res", "exe", "p1", "p2"] { try FileManager.default.createDirectory(atPath: d + "/" + n, withIntermediateDirectories: true) }
        let c = HostCommand.defaultBinaries(resourcePath: d + "/res", executableDir: d + "/exe", path: "\(d)/p1:relative:\(d)/p2/", home: d + "/home", fallbacks: ["/fb/strim"])
        #expect(c == [d + "/res/strim", d + "/exe/strim", d + "/home/.strim/bin/strim", d + "/p1/strim", d + "/p2/strim", "/fb/strim"])
        for n in ["p2", "exe", "res"].dropFirst(0) { try script("exit 0", at: d + "/" + n + "/strim") }
        // all three exist: bundled wins
        #expect(HostCommand.resolveBinary(settings: AppSettings(), candidates: c) == .found(d + "/res/strim"))
        try FileManager.default.removeItem(atPath: d + "/res/strim")
        #expect(HostCommand.resolveBinary(settings: AppSettings(), candidates: c) == .found(d + "/exe/strim"))
        try FileManager.default.removeItem(atPath: d + "/exe/strim")
        #expect(HostCommand.resolveBinary(settings: AppSettings(), candidates: c) == .found(d + "/p2/strim"))
    }
    @Test func missingAndNonExecutableBinariesGiveClearResults() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        #expect(HostCommand.resolveBinary(settings: AppSettings(), candidates: [d + "/none"]) == .missing)
        let noexec = try script("exit 0", at: d + "/noexec", mode: 0o644)
        guard case .invalid(let why) = HostCommand.resolveBinary(settings: AppSettings(), candidates: [d + "/none", noexec]) else { Issue.record("expected invalid"); return }
        #expect(why.contains(noexec) && why.contains("not executable"))
        var s = AppSettings(); s.strimBinary = d + "/gone"
        guard case .invalid(let w2) = HostCommand.resolveBinary(settings: s, candidates: []) else { Issue.record("expected invalid"); return }
        #expect(w2.contains("does not exist") && w2.contains(d + "/gone"))
        s.strimBinary = "   "   // blank configured binary means default discovery, not "invalid"
        #expect(HostCommand.resolveBinary(settings: s, candidates: [d + "/none"]) == .missing)
        // a valid candidate after a non-executable one still wins
        let good = try script("exit 0", at: d + "/good")
        #expect(HostCommand.resolveBinary(settings: AppSettings(), candidates: [noexec, good]) == .found(good))
    }

    // MARK: launcher

    private func fixture() throws -> (d: String, model: String, mtp: String, state: String, args: String) {
        let d = try tmpDir()
        let model = d + "/model", mtp = d + "/mtp", state = d + "/state"
        try FileManager.default.createDirectory(atPath: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mtp, withIntermediateDirectories: true)
        return (d, model, mtp, state, d + "/argv")
    }

    @Test func launcherPassesExactArgvAndWritesConfiguredLog() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        let bin = try script("for a in \"$@\"; do echo \"ARG:$a\" > /dev/null; printf '%s\\n' \"$a\" >> \"\(f.args)\"; done\necho hello-log\nsleep 2", at: f.d + "/strim")
        var s = AppSettings(modelPath: f.model, mtpPath: f.mtp); s.strimBinary = bin; s.hostURL = "http://127.0.0.1:9123"
        let l = ProcessHostLauncher(stateDir: f.state, startupGrace: 0.3)
        let r = l.start(settings: s)
        guard case .started(let pid) = r else { Issue.record("got \(r)"); return }
        defer { kill(pid, SIGKILL) }
        #expect(l.logPath == f.state + "/host.log")
        let want = ["serve", f.model, f.mtp, "--port", "9123", "--state-dir", f.state, "--token-file", f.state + "/token"]
        #expect(HostCommand.arguments(settings: s, stateDir: f.state) == want)
        var got = ""
        for _ in 0..<50 { got = (try? String(contentsOfFile: f.args, encoding: .utf8)) ?? ""; if got.split(separator: "\n").count >= want.count { break }; usleep(50_000) }
        #expect(got.split(separator: "\n").map(String.init) == want)
        let log1 = try String(contentsOfFile: l.logPath, encoding: .utf8)
        #expect(log1.contains("hello-log"))
        #expect(perms(l.logPath) == 0o600 && perms(f.state) == 0o700)
    }
    @Test func missingModelReportsWhereAndDoesNotStartAnything() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        let marker = f.d + "/ran"
        let bin = try script("touch \"\(marker)\"", at: f.d + "/strim")
        var s = AppSettings(modelPath: f.d + "/nope"); s.strimBinary = bin
        let r = ProcessHostLauncher(stateDir: f.state, startupGrace: 0.2).start(settings: s)
        guard case .failed(let msg) = r else { Issue.record("got \(r)"); return }
        #expect(msg.contains("model not found at \(f.d)/nope"))
        usleep(200_000)
        #expect(!FileManager.default.fileExists(atPath: marker))
        // tilde form reports the expanded path
        s.modelPath = "~/definitely-not-a-strim-model-\(UUID().uuidString)"
        guard case .failed(let m2) = ProcessHostLauncher(stateDir: f.state, startupGrace: 0.2).start(settings: s) else { Issue.record("expected failure"); return }
        #expect(m2.contains("model not found at \(AppPaths.home)/definitely-not"))
    }
    @Test func modelPathThatIsAFileIsRefusedBeforeLaunch() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        let marker = f.d + "/ran"
        let bin = try script("touch \"\(marker)\"", at: f.d + "/strim")
        let file = f.d + "/model.gguf"
        try write("weights", file)
        var s = AppSettings(modelPath: file); s.strimBinary = bin
        guard case .failed(let msg) = ProcessHostLauncher(stateDir: f.state, startupGrace: 0.2).start(settings: s) else {
            Issue.record("expected failure for a regular file"); return
        }
        #expect(msg == "model not found at \(file): it is not a model folder. Choose a model in Settings or let Strim download one.")
        usleep(200_000)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
    @Test func missingMTPStartsWithoutItAndNotesTheLog() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        let bin = try script("printf '%s\\n' \"$@\" > \"\(f.args)\"\nsleep 2", at: f.d + "/strim")
        var s = AppSettings(modelPath: f.model, mtpPath: f.d + "/no-mtp"); s.strimBinary = bin
        let l = ProcessHostLauncher(stateDir: f.state, startupGrace: 0.3)
        guard case .started(let pid) = l.start(settings: s) else { Issue.record("did not start"); return }
        defer { kill(pid, SIGKILL) }
        var got = ""
        for _ in 0..<50 { got = (try? String(contentsOfFile: f.args, encoding: .utf8)) ?? ""; if got.contains("8203") { break }; usleep(50_000) }
        #expect(got.split(separator: "\n").map(String.init) == ["serve", f.model, "--port", "8203", "--state-dir", f.state, "--token-file", f.state + "/token"])
        let log2 = try String(contentsOfFile: l.logPath, encoding: .utf8)
        #expect(log2.contains("MTP head not found at \(f.d)/no-mtp"))
    }
    @Test func earlyExitSurfacesLastStderrLines() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        let bin = try script("echo old-noise\necho 'strim: bad weights' >&2\necho 'port 8203 in use' >&2\nexit 3", at: f.d + "/strim")
        var s = AppSettings(modelPath: f.model); s.strimBinary = bin
        let l = ProcessHostLauncher(stateDir: f.state, startupGrace: 3)
        // pre-existing log content from an earlier run must not be reported
        try SecureFS.ensureDir(f.state)
        try write("previous-run-line\n", l.logPath)
        let r = l.start(settings: s)
        guard case .failed(let msg) = r else { Issue.record("got \(r)"); return }
        #expect(msg.contains("status 3") && msg.contains("strim: bad weights") && msg.contains("port 8203 in use"))
        #expect(!msg.contains("previous-run-line"))
    }
    @Test func exitWithNoOutputPointsAtTheLog() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        let bin = try script("exit 0", at: f.d + "/strim")
        var s = AppSettings(modelPath: f.model); s.strimBinary = bin
        let l = ProcessHostLauncher(stateDir: f.state, startupGrace: 3)
        guard case .failed(let msg) = l.start(settings: s) else { Issue.record("expected failure"); return }
        #expect(msg.contains(l.logPath))
    }
    @Test func launcherReportsMissingAndNonExecutableBinaryBeforeModelCheck() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(atPath: f.d) }
        var s = AppSettings(modelPath: f.model)
        var r = ProcessHostLauncher(stateDir: f.state, binaryCandidates: [f.d + "/none"]).start(settings: s)
        guard case .binaryMissing(let cmd) = r else { Issue.record("got \(r)"); return }
        #expect(cmd.hasPrefix("strim serve "))
        let noexec = try script("exit 0", at: f.d + "/noexec", mode: 0o644)
        r = ProcessHostLauncher(stateDir: f.state, binaryCandidates: [noexec]).start(settings: s)
        guard case .binaryInvalid(let why, _) = r else { Issue.record("got \(r)"); return }
        #expect(why.contains("not executable"))
        s.strimBinary = f.d + "/absent"
        r = ProcessHostLauncher(stateDir: f.state).start(settings: s)
        guard case .binaryInvalid(let w2, _) = r else { Issue.record("got \(r)"); return }
        #expect(w2.contains("does not exist"))
    }

    // MARK: default thinking and MTP off

    @Test func thinkingDefaultsOnAndRoundTrips() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        #expect(AppSettings().thinkingEnabled)
        try write("{}", p)
        #expect(AppSettings.load(path: p).thinkingEnabled, "a missing key means the default (on)")
        var s = AppSettings(); s.thinkingEnabled = false
        try s.save(path: p)
        #expect(!AppSettings.load(path: p).thinkingEnabled)
        s.thinkingEnabled = true
        try s.save(path: p)
        #expect(AppSettings.load(path: p).thinkingEnabled)
    }
    @Test func thinkingWrongTypeFallsBackPerKey() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"{"thinking_enabled":"no","model_path":"/ok"}"#, p)
        let s = AppSettings.load(path: p)
        #expect(s.thinkingEnabled && s.modelPath == "/ok", "a bad value keeps the default and does not discard the rest")
        try write(#"{"thinking_enabled":false}"#, p)
        #expect(!AppSettings.load(path: p).thinkingEnabled)
    }
    @Test func mtpOffPersistsAndOlderFilesKeepTheirHead() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/app.json"
        try write(#"{"model_path":"/m","mtp_path":"/h"}"#, p)   // written before mtp_disabled existed
        let old = AppSettings.load(path: p)
        #expect(!old.mtpDisabled && old.mtpPath == "/h")
        #expect(HostCommand.arguments(settings: old) == ["serve", "/m", "/h", "--port", "8203"])
        var off = old; off.mtpPath = nil; off.mtpDisabled = true
        try off.save(path: p)
        let back = AppSettings.load(path: p)
        #expect(back.mtpDisabled && back.mtpPath == nil)
        #expect(HostCommand.arguments(settings: back) == ["serve", "/m", "--port", "8203"], "off: no MTP argument")
        try write(#"{"model_path":"/m","mtp_path":"/h","mtp_disabled":"yes"}"#, p)
        #expect(!AppSettings.load(path: p).mtpDisabled, "a bad value means the head stays on")
    }
    @Test func mtpArgumentWithAndWithoutHead() {
        #expect(HostCommand.arguments(settings: AppSettings(modelPath: "/m", mtpPath: "/h")) == ["serve", "/m", "/h", "--port", "8203"])
        #expect(HostCommand.arguments(settings: AppSettings(modelPath: "/m", mtpPath: "/h", mtpDisabled: true)) == ["serve", "/m", "--port", "8203"])
        #expect(HostCommand.arguments(settings: AppSettings(modelPath: "/m", mtpPath: nil)) == ["serve", "/m", "--port", "8203"])
        #expect(HostCommand.commandLine(binary: "strim", settings: AppSettings(modelPath: "/m", mtpPath: "/h", mtpDisabled: true)) == "strim serve /m --port 8203")
    }
}

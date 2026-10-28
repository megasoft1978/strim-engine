import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

private func tmpDir() -> String {
    let d = NSTemporaryDirectory() + "sec-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}
private func mode(_ path: String) -> Int {
    var st = stat(); lstat(path, &st); return Int(st.st_mode & 0o7777)
}
private func touch(_ path: String, _ body: String = "tok\n", mode m: mode_t = 0o600) {
    FileManager.default.createFile(atPath: path, contents: Data(body.utf8), attributes: [.posixPermissions: Int(m)])
}

@Suite struct ControlTokenTests {
    @Test func defaultsToControlToken() {
        #expect(AppPaths.defaultControlTokenPath.hasSuffix("/.strim/control-token"))
        #expect(AppSettings().controlTokenPath == AppPaths.defaultControlTokenPath)
    }
    @Test func jsonKeyAndOldKeyIgnored() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"control_token_path":"~/.strim/ct","token_path":"/etc/passwd"}"#.utf8))
        #expect(s.controlTokenPath == "~/.strim/ct")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"token_path":"/etc/passwd"}"#.utf8))
        #expect(old.controlTokenPath == AppPaths.defaultControlTokenPath)   // MCP token path is never used
    }
    @Test func statusMatrix() throws {
        let home = tmpDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let f = home + "/ct"
        #expect(TokenReader(path: f, home: home).inspect() == .missing)
        touch(f)
        #expect(TokenReader(path: f, home: home).inspect() == .ok)
        chmod(f, 0o644)
        #expect(TokenReader(path: f, home: home).inspect() == .insecure(mode: 0o644))
        chmod(f, 0o640)
        #expect(TokenReader(path: f, home: home).inspect() == .insecure(mode: 0o640))
        chmod(f, 0o604)
        #expect(TokenReader(path: f, home: home).inspect() == .insecure(mode: 0o604))
        chmod(f, 0o400)
        #expect(TokenReader(path: f, home: home).inspect() == .ok)
        chmod(f, 0o600)
        touch(home + "/empty", "\n")
        #expect(TokenReader(path: home + "/empty", home: home).inspect() == .empty)
        try FileManager.default.createDirectory(atPath: home + "/dir", withIntermediateDirectories: true)
        #expect(TokenReader(path: home + "/dir", home: home).inspect() == .notRegular)
        try FileManager.default.createSymbolicLink(atPath: home + "/link", withDestinationPath: f)
        #expect(TokenReader(path: home + "/link", home: home).inspect() == .notRegular)
        #expect(TokenReader(path: "/etc/hosts", home: home).inspect() == .outsideHome)
        #expect(TokenReader(path: home + "/../../etc/hosts", home: home).inspect() == .outsideHome)
        #expect(TokenReader(path: home + "-evil/ct", home: home).inspect() == .outsideHome)   // prefix trick
    }
    @Test func readOnlyWhenUsable() throws {
        let home = tmpDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let f = home + "/ct"; touch(f, "  secret \n")
        #expect(TokenReader(path: f, home: home).read() == "secret")
        chmod(f, 0o644)
        #expect(TokenReader(path: f, home: home).read() == "secret")      // warned, still usable
        #expect(TokenReader(path: "/etc/hosts", home: home).read() == nil)
        #expect(TokenReader(path: home + "/nope", home: home).read() == nil)
    }
    @Test func warningTexts() {
        let r = TokenReader(path: AppPaths.defaultControlTokenPath)
        #expect(TokenFileStatus.missing.banner(path: r.path)?.contains("Start the host once so it creates ~/.strim/control-token") == true)
        #expect(TokenFileStatus.insecure(mode: 0o644).banner(path: r.path)?.contains("chmod 600") == true)
        #expect(TokenFileStatus.insecure(mode: 0o644).banner(path: r.path)?.contains("0644") == true)
        #expect(TokenFileStatus.outsideHome.banner(path: "/etc/x")?.contains("home") == true)
        #expect(TokenFileStatus.ok.banner(path: r.path) == nil)
    }
    @Test @MainActor func modelShowsTokenBanner() async {
        let fake = FakeControlClient()
        let m = AppModel(client: fake, clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(),
                         loginItem: MockLogin(), clipboard: MockClipboard(), persist: { _ in }, pollInterval: nil,
                         tokenStatus: { _ in .missing })
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.tokenWarning?.contains("Start the host once so it creates ~/.strim/control-token") == true)
        m.stop()
        let ok = AppModel(client: fake, clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(),
                          loginItem: MockLogin(), clipboard: MockClipboard(), persist: { _ in }, pollInterval: nil,
                          tokenStatus: { _ in .insecure(mode: 0o664) })
        ok.start()
        #expect(await waitFor { ok.tokenWarning != nil })
        #expect(ok.tokenWarning?.contains("readable by other users") == true)
        ok.stop()
    }
}

@Suite struct HostURLTests {
    @Test func accepted() {
        for u in ["http://127.0.0.1:8203", "http://localhost:8203", "http://[::1]:8203", "http://127.0.0.1:8203/", "http://LOCALHOST:1"] {
            #expect(HostURL.validate(u) == nil, "\(u): \(HostURL.validate(u) ?? "")")
        }
    }
    @Test func matrix() {
        let bad = ["https://127.0.0.1:8203", "http://127.0.0.1", "http://evil.com:80", "http://127.0.0.1@evil.com:80",
                   "http://user:pw@127.0.0.1:8203", "http://evil.com@127.0.0.1:8203", "http://127.0.0.1:8203/path",
                   "http://127.0.0.1:8203?x=1", "http://127.0.0.1:8203#f", "http://127.0.0.1.evil.com:8203",
                   "http://0.0.0.0:8203", "http://127.0.0.2:8203", "http://[::2]:1", "http://localhost.:8203",
                   "http://127.0.0.1:0", "http://127.0.0.1:99999", "ftp://127.0.0.1:21", "", "javascript:alert(1)",
                   " http://127.0.0.1:8203", "http://127.0.0.1:8203\n", "http://localhost:8203\\@evil.com",
                   "http://127.1:8203", "http://2130706433:8203", "//127.0.0.1:8203", "127.0.0.1:8203", "http://:8203",
                   "http://127.0.0.1:8203:9", "http://[::ffff:127.0.0.1]:8203", "http://localhost%2eevil.com:80"]
        for u in bad { #expect(HostURL.validate(u) != nil, "should reject \(u)") }
    }
    @Test func settingsUseValidatedURL() {
        var s = AppSettings(); s.hostURL = "http://evil.com:80"
        #expect(s.validatedURL == nil && s.hostURLProblem != nil)
        s.hostURL = "http://localhost:9000"
        #expect(s.validatedURL?.port == 9000 && s.port == 9000)
    }
    @Test func makeClientForBadSettingsFailsClosed() async {
        var s = AppSettings(); s.hostURL = "http://user@127.0.0.1:8203"
        let c = HTTPControlClient.make(settings: s)
        await #expect(throws: ControlClientError.self) { _ = try await c.status() }
    }
}

@Suite(.serialized) struct HardenedSessionTests {
    @Test func configIsEphemeralWithoutProxiesOrCache() {
        let cfg = HTTPControlClient.hardenedConfiguration()
        #expect((cfg.connectionProxyDictionary as NSDictionary?)?.count == 0)
        #expect(cfg.urlCache == nil && cfg.httpCookieStorage == nil)
        #expect(cfg.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(cfg.httpShouldSetCookies == false)
    }
    @Test func redirectsAreRefused() async {
        let d = NoRedirectDelegate()
        let task = URLSession.shared.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:1")!))
        let resp = HTTPURLResponse(url: URL(string: "http://127.0.0.1:1")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://evil.com/"])!
        var out: URLRequest? = URLRequest(url: URL(string: "http://sentinel")!)
        d.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: "http://evil.com/")!)) { out = $0 }
        #expect(out == nil)
    }
}

@Suite struct FilePermissionTests {
    @Test func settingsSavedPrivately() throws {
        let home = tmpDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = home + "/.strim"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try AppSettings().save(path: dir + "/app.json")
        #expect(mode(dir + "/app.json") == 0o600)
        #expect(mode(dir) == 0o700)           // an existing too-open directory is tightened
        try AppSettings().save(path: dir + "/app.json")   // overwrite keeps 0600
        #expect(mode(dir + "/app.json") == 0o600)
    }
    @Test func atomicWriteNeverFollowsSymlinkTemp() throws {
        let home = tmpDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        try SecureFS.writeAtomically(Data("a".utf8), to: home + "/d/f.txt")
        #expect(mode(home + "/d") == 0o700 && mode(home + "/d/f.txt") == 0o600)
        #expect(try String(contentsOfFile: home + "/d/f.txt", encoding: .utf8) == "a")
    }
    @Test func hostLogIsPrivateAndRefusesSymlink() throws {
        let home = tmpDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let log = home + "/.strim/host.log"
        let h = try SecureFS.openAppend(log); try h.close()
        #expect(mode(log) == 0o600 && mode(home + "/.strim") == 0o700)
        let target = home + "/victim"; touch(target, "keep", mode: 0o644)
        try FileManager.default.createSymbolicLink(atPath: home + "/.strim/evil.log", withDestinationPath: target)
        #expect(throws: (any Error).self) { _ = try SecureFS.openAppend(home + "/.strim/evil.log") }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
    }
    @Test @MainActor func patchesWrittenPrivately() async throws {
        let fake = FakeControlClient()
        let sum = JobSummary(id: "j", source: .mcp, status: .awaitingApproval, started: 1)
        await fake.setJobs([sum]); await fake.setDetail(JobDetail(summary: sum, patch: "diff --git a/x b/x\n"))
        let clip = MockClipboard()
        let m = AppModel(client: fake, clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(),
                         loginItem: MockLogin(), clipboard: clip, persist: { _ in }, pollInterval: nil, tokenStatus: { _ in .ok })
        let dir = tmpDir() + "/patches"; defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        m.patchDirectory = dir
        m.start(); _ = await waitFor { m.connection.isConnected }
        await m.selectJob("j")
        m.copyPatchPath()
        let path = try #require(clip.copied.value.first)
        #expect(mode(path) == 0o600 && mode(dir) == 0o700)
        m.stop()
    }
}

@Suite struct BinaryValidationTests {
    private func make(_ mode: mode_t, in dir: String, name: String = "strim") -> String {
        let p = dir + "/" + name
        FileManager.default.createFile(atPath: p, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: Int(mode)])
        chmod(p, mode)
        return p
    }
    @Test func matrix() throws {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let good = make(0o755, in: d)
        #expect(BinaryValidator.validate(good) == nil)
        #expect(BinaryValidator.validate("/bin/ls") == nil)
        #expect(BinaryValidator.validate("strim") != nil)            // relative
        #expect(BinaryValidator.validate("./strim") != nil)
        #expect(BinaryValidator.validate("~/strim") != nil)
        #expect(BinaryValidator.validate("") != nil)
        #expect(BinaryValidator.validate(d + "/missing") != nil)
        #expect(BinaryValidator.validate(d) != nil)                    // directory
        #expect(BinaryValidator.validate(make(0o644, in: d, name: "noexec")) != nil)
        #expect(BinaryValidator.validate(make(0o757, in: d, name: "worldw")) != nil)
        #expect(BinaryValidator.validate(make(0o777, in: d, name: "allw")) != nil)
        #expect(BinaryValidator.validate(d + "/../" + (d as NSString).lastPathComponent + "/strim") != nil)   // not normalised
        try FileManager.default.createSymbolicLink(atPath: d + "/ln", withDestinationPath: good)
        #expect(BinaryValidator.validate(d + "/ln") == nil)            // symlink to a good file is fine (homebrew)
        #expect(BinaryValidator.validate("/bin/ls\u{0}x") != nil)
    }
    @Test func launcherRefusesBadBinaryAndShowsCommand() {
        var s = AppSettings(modelPath: "/models/q"); s.strimBinary = "relative/strim"
        let r = ProcessHostLauncher().start(settings: s)
        guard case .binaryInvalid(let why, let cmd) = r else { Issue.record("got \(r)"); return }
        #expect(why.contains("absolute") && cmd == "strim serve /models/q --port 8203")
    }
    @Test func optionLikePathsAreNotPassedToServe() {
        var s = AppSettings(modelPath: "--evil"); #expect(HostCommand.arguments(settings: s) == nil)
        s = AppSettings(modelPath: "/m", mtpPath: "-x"); #expect(HostCommand.arguments(settings: s) == nil)
    }
}

@Suite @MainActor struct ChatProjectTests {
    private func model(_ project: String?) -> (AppModel, FakeControlClient) {
        let fake = FakeControlClient()
        let m = AppModel(client: fake, settings: AppSettings(projectPath: project), clock: RecordingClock(auto: 100),
                         launcher: MockLauncher(.needsModel), mcp: MockMcp(), loginItem: MockLogin(), clipboard: MockClipboard(),
                         persist: { _ in }, pollInterval: nil, tokenStatus: { _ in .ok })
        return (m, fake)
    }
    @Test func noProjectNoProbe() async {
        let (m, fake) = model(nil)
        m.start(); _ = await waitFor { m.connection.isConnected }
        await m.probeChat()
        #expect(await fake.calls.isEmpty)
        guard case .unavailable(let why) = m.chat else { Issue.record("not unavailable"); return }
        #expect(why.contains("project folder"))
        m.stop()
    }
    @Test func neverHomeOrRootOrMissingFolder() async {
        for bad in [NSHomeDirectory(), NSHomeDirectory() + "/", "/", "~", "relative/dir", "/definitely/not/a/dir"] {
            let (m, fake) = model(bad)
            m.start(); _ = await waitFor { m.connection.isConnected }
            await m.probeChat()
            #expect(await fake.calls.isEmpty, "\(bad)")
            if case .ready = m.chat { Issue.record("opened chat in \(bad)") }
            m.stop()
        }
    }
    @Test func usesChosenFolder() async {
        let d = tmpDir(); defer { try? FileManager.default.removeItem(atPath: d) }
        let (m, fake) = model(d)
        m.start(); _ = await waitFor { m.connection.isConnected }
        await m.probeChat()
        #expect(await fake.calls == ["chat_open:\(d)"])
        m.stop()
    }
}

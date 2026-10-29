import Foundation
import Testing
@testable import StrimAppCore

@Suite struct SettingsTests {
    @Test func defaultsAndRoundTrip() throws {
        #expect(AppSettings().startServerWhenOpens)
        let dir = NSTemporaryDirectory() + "strim-app-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/app.json"
        #expect(AppSettings.load(path: path) == AppSettings())
        var s = AppSettings(); s.modelPath = "/m"; s.mtpPath = "/h"; s.hostURL = "http://127.0.0.1:9000"
        try s.save(path: path)
        #expect(AppSettings.load(path: path) == s)
        #expect(s.port == 9000)
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(raw.contains("\"model_path\""))
        try Data(#"{"model_path":"/only"}"#.utf8).write(to: URL(fileURLWithPath: path))
        let partial = AppSettings.load(path: path)
        #expect(partial.modelPath == "/only" && partial.hostURL == AppPaths.defaultHostURL)
        #expect(partial.startServerWhenOpens)
    }
    @Test func hostCommand() {
        var s = AppSettings(); s.modelPath = "/models/Qwen 27B"; s.mtpPath = "/models/mtp"
        #expect(HostCommand.arguments(settings: s) == ["serve", "/models/Qwen 27B", "/models/mtp", "--port", "8203"])
        #expect(HostCommand.commandLine(binary: "strim", settings: s) == "strim serve '/models/Qwen 27B' /models/mtp --port 8203")
        #expect(HostCommand.arguments(settings: AppSettings()) == nil)
    }
    @Test func tokenReaderTrimsAndNeverThrows() throws {
        let p = NSTemporaryDirectory() + "tok-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(TokenReader(path: p, home: NSTemporaryDirectory()).read() == nil)
        try "  abc123\n".write(toFile: p, atomically: true, encoding: .utf8)
        #expect(TokenReader(path: p, home: NSTemporaryDirectory()).read() == "abc123")
        try "\n".write(toFile: p, atomically: true, encoding: .utf8)
        #expect(TokenReader(path: p, home: NSTemporaryDirectory()).read() == nil)
    }
    @Test func mcpTemplateNeverContainsTokenValue() {
        let t = McpTemplate.render(port: 8203)
        #expect(t.contains("$(cat ~/.strim/token)"))
        #expect(!t.contains("Bearer abc"))
    }
}

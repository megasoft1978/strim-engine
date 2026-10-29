import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

func tempDir(_ tag: String = "chat") -> String {
    let d = NSTemporaryDirectory() + "strim-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return URL(fileURLWithPath: d).resolvingSymlinksInPath().path
}

private func msg(_ role: String, _ text: String, ts: Double = 1) -> StoredMessage { StoredMessage(role: role, text: text, ts: ts) }

@Suite struct ChatStoreTests {
    @Test func indexAndThreadRoundTrip() throws {
        let root = tempDir()
        let store = FileChatStore(root: root)
        let p = ChatProject(path: "/tmp/proj", addedAt: 1, lastActivity: 2)
        let t = ChatThread(projectId: p.id, title: "Hello", titleIsUser: true, createdAt: 1, lastActivity: 3, thinking: false, unread: true, messageCount: 2)
        try store.save(ChatIndex(projects: [p], threads: [t]))
        var m = msg("tool", "read_file a: 3 lines")
        m.tool = StoredToolCard(name: "read_file", args: "a", result: "3 lines", isError: false)
        m.ledger = StoredLedger(prompt: 10, cached: 4, completion: 3, seconds: 1.5)
        try store.appendThread(t.id, [msg("user", "hi\nthere \"q\""), m])
        try store.appendThread(t.id, [msg("assistant", "ok")])

        let back = FileChatStore(root: root)
        let idx = back.load()
        #expect(idx.projects == [p] && idx.threads == [t] && !idx.isNew && idx.notice == nil)
        let lt = back.loadThread(t.id)
        #expect(lt.skipped == 0 && lt.messages.map(\.text) == ["hi\nthere \"q\"", "read_file a: 3 lines", "ok"])
        #expect(lt.messages[1].tool?.result == "3 lines" && lt.messages[1].ledger?.completion == 3)
        #expect(lt.messages[1].chatMessage?.tool?.finished == true)
        var st = stat()
        #expect(stat(root + "/index.json", &st) == 0 && (st.st_mode & 0o777) == 0o600)
        #expect(stat(root + "/threads/\(t.id).jsonl", &st) == 0 && (st.st_mode & 0o777) == 0o600)
    }

    @Test func missingIndexIsNew() {
        let idx = FileChatStore(root: tempDir()).load()
        #expect(idx.isNew && idx.projects.isEmpty && idx.threads.isEmpty)
    }

    @Test func corruptIndexRebuildsFromThreadFiles() throws {
        let root = tempDir()
        let store = FileChatStore(root: root)
        try store.appendThread("t-one", [msg("user", "First question. More text"), msg("assistant", "a")])
        try store.appendThread("t-two", [msg("user", "Other"), msg("assistant", "b")])
        try SecureFS.writeAtomically(Data("{not json".utf8), to: root + "/index.json")
        let idx = FileChatStore(root: root).load()
        #expect(Set(idx.threads.map(\.id)) == ["t-one", "t-two"])
        #expect(idx.threads.first { $0.id == "t-one" }?.title == "First question. More text")
        #expect(idx.threads.allSatisfy { $0.projectId == idx.projects[0].id } && idx.projects[0].path == "")
        #expect(idx.notice?.contains("rebuilt") == true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(names.contains { $0.hasPrefix("index.corrupt-") })
        #expect(!names.contains("index.json"))
    }

    @Test func badJSONLLineIsSkippedAndCounted() throws {
        let root = tempDir()
        let store = FileChatStore(root: root)
        try store.appendThread("t1", [msg("user", "a")])
        let h = try SecureFS.openAppend(root + "/threads/t1.jsonl")
        try h.write(contentsOf: Data("garbage line\n{\"v\":1,\"id\":\"x\",\"role\":\"alien\",\"text\":\"?\",\"ts\":1}\n".utf8))
        try h.close()
        try store.appendThread("t1", [msg("assistant", "b")])
        let lt = store.loadThread("t1")
        #expect(lt.messages.map(\.text) == ["a", "b"] && lt.skipped == 2)
    }

    @Test func oversizedThreadTrimsOldestWithMarker() throws {
        let store = FileChatStore(root: tempDir(), maxThreadBytes: 4000)
        for i in 0..<30 { try store.appendThread("big", [msg("user", "message \(i) " + String(repeating: "x", count: 200))]) }
        let ms = store.loadThread("big").messages
        #expect(ms.first?.trimMarker == true)
        #expect(ms.first?.chatMessage?.marker == .trimmed)
        #expect(ms.last?.text.hasPrefix("message 29 ") == true)
        #expect(ms.count < 30 && ms.dropFirst().filter { $0.trimMarker == true }.isEmpty)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: store.root + "/threads/big.jsonl"))?[.size] as? Int) ?? 0
        #expect(bytes <= 4000)
    }

    @Test func newerVersionOpensReadOnly() throws {
        let root = tempDir()
        try SecureFS.writeAtomically(Data(#"{"version":9,"projects":[],"threads":[]}"#.utf8), to: root + "/index.json")
        let store = FileChatStore(root: root)
        let idx = store.load()
        #expect(idx.readOnly && idx.notice != nil)
    }

    @Test func toolResultsAreTruncatedOnStore() {
        var m = ChatMessage(role: .tool, text: String(repeating: "r", count: 40_000), tool: ToolCard(name: "bash", args: "ls", result: String(repeating: "r", count: 40_000)))
        m.id = UUID()
        let s = StoredMessage(m, ts: 1)
        #expect(s.text.utf8.count < 17_000 && (s.tool?.result?.utf8.count ?? 0) < 17_000)
        #expect(s.tool?.result?.hasSuffix("[truncated]") == true)
    }

    @Test func unsafeThreadIdsAreRefused() throws {
        let root = tempDir()
        let store = FileChatStore(root: root)
        #expect(throws: Error.self) { try store.appendThread("../evil", [msg("user", "x")]) }
        #expect(store.loadThread("../evil").messages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root + "/evil.jsonl"))
    }

    @Test func memoryStoreMirrorsFileStore() throws {
        let s = MemoryChatStore(maxThreadBytes: 3000)
        for i in 0..<20 { try s.appendThread("t", [msg("user", "m\(i) " + String(repeating: "y", count: 200))]) }
        #expect(s.loadThread("t").messages.first?.trimMarker == true)
        s.deleteThread("t")
        #expect(s.loadThread("t").messages.isEmpty)
    }
}

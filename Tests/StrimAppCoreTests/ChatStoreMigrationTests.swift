import Foundation
import Testing
@testable import StrimAppCore

@Suite struct ChatStoreMigrationTests {
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private func root() throws -> String {
        let path = NSTemporaryDirectory() + "strim-migration-🧪-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func historicalIndexes() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = #"{"id":"p","path":"/tmp/📁","name":"古い","addedAt":1,"lastActivity":2,"isScratch":false"#
        let thread = #"{"id":"t","projectId":"p","title":"💬","titleIsUser":false,"createdAt":1,"lastActivity":2,"thinking":true,"unread":false,"messageCount":1}"#
        for extra in ["", #",\"folderConsent\":5"#, #",\"folderConsent\":5,\"consentRoot\":\"/tmp/📁\""#] {
            let json = "{\"version\":1,\"projects\":[" + project + extra.replacingOccurrences(of: "\\\"", with: "\"") + "}],\"threads\":[" + thread + "]}"
            try Data(json.utf8).write(to: URL(fileURLWithPath: dir + "/index.json"))
            let idx = FileChatStore(root: dir).load()
            #expect(idx.projects.first?.name == "古い")
            #expect(idx.threads.first?.title == "💬")
            #expect(idx.projects.first?.folderConsent == (extra.isEmpty ? nil : 5))
            #expect(idx.projects.first?.consentRoot == (extra.contains("consentRoot") ? "/tmp/📁" : nil))
        }
    }

    @Test func corruptFilesAreAllBackedUpBeforeSaving() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileChatStore(root: dir)
        let samples = [Data("{".utf8), Data(#"{"version":1,"projects":"wrong","threads":[]}"#.utf8), Data(), Data([0xff, 0x00, 0x80])]
        for sample in samples {
            try sample.write(to: URL(fileURLWithPath: dir + "/index.json"))
            let index = store.load()
            #expect(index.notice != nil && index.projects.isEmpty)
            try store.save(index)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("index.corrupt-") }
        let saved = try backups.map { try Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0)) }
        #expect(saved.count == samples.count)
        for sample in samples { #expect(saved.contains(sample)) }
    }

    @Test func truncatedTranscriptAndUnknownFields() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileChatStore(root: dir)
        try store.rewriteThread("t", [StoredMessage(id: "a", role: "user", text: "first"), StoredMessage(id: "b", role: "assistant", text: "second")])
        let path = dir + "/threads/t.jsonl"
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try h.seekToEnd()
        try h.write(contentsOf: Data("{\"v\":1,\"id\":\"x\"".utf8)); try h.close()
        #expect(store.loadThread("t").messages.map(\.text) == ["first", "second"])
        #expect(store.loadThread("t").skipped == 1)
        try store.appendThread("t", [StoredMessage(id: "c", role: "user", text: "after")])
        #expect(store.loadThread("t").messages.map(\.text) == ["first", "second", "after"])
        try Data("{\"v\":1,\"id\":\"x\",\"role\":\"user\",\"text\":\"ok\",\"ts\":1,\"future\":true}\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(store.loadThread("t").messages.map(\.text) == ["ok"])
    }

    @Test func directSaveBacksUpCorruptIndex() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let bad = Data("broken".utf8)
        try bad.write(to: URL(fileURLWithPath: dir + "/index.json"))
        try FileChatStore(root: dir).save(ChatIndex())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("index.corrupt-") }
        #expect(try files.contains { try Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0)) == bad })
    }

    @Test func duplicateIdsAndMissingThread() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileChatStore(root: dir)
        let p = ChatProject(id: "p", path: "/tmp")
        let t = ChatThread(id: "missing", projectId: p.id)
        try store.save(ChatIndex(projects: [p, p], threads: [t, t]))
        #expect(store.load().threads.count == 2)
        #expect(store.loadThread("missing").messages.isEmpty)
        let m = StoredMessage(id: "same", role: "user", text: "duplicate")
        try store.rewriteThread("present", [m, m])
        #expect(store.loadThread("present").messages == [m, m])
    }

    @Test func largeThreadIsTrimmed() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileChatStore(root: dir, maxThreadBytes: 100_000)
        let messages = (0..<5000).map { StoredMessage(id: "\($0)", role: "user", text: String(repeating: "x", count: 200)) }
        try store.rewriteThread("large", messages)
        let loaded = store.loadThread("large")
        #expect(loaded.messages.first?.trimMarker == true && loaded.messages.last?.id == "4999")
        #expect((try Data(contentsOf: URL(fileURLWithPath: dir + "/threads/large.jsonl"))).count <= 100_000)
    }

    @Test func relaunchUnicodeConsentAndAtomicPermissions() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileChatStore(root: dir)
        let p = ChatProject(id: "p", path: "/tmp/🌍", name: "作品 🐈", folderConsent: 4, consentRoot: "/tmp/🌍")
        let t = ChatThread(id: "t", projectId: "p", title: "こんにちは 👋")
        let index = ChatIndex(projects: [p], threads: [t]); let message = StoredMessage(role: "user", text: "🎉")
        try store.save(index); try store.rewriteThread("t", [message])
        let old = try FileHandle(forReadingFrom: URL(fileURLWithPath: dir + "/index.json"))
        try store.save(ChatIndex())
        let prior = try old.readToEnd(); try old.close()
        #expect(try JSONDecoder().decode(ChatIndex.self, from: prior!) == index)
        try store.save(index)
        let reopened = FileChatStore(root: dir)
        #expect(reopened.load() == index && reopened.loadThread("t").messages == [message])
        for path in [dir + "/index.json", dir + "/threads/t.jsonl"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attrs[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test func concurrentStoresWriteWholeIndexes() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = FileChatStore(root: dir), b = FileChatStore(root: dir)
        let first = ChatIndex(projects: [ChatProject(id: "a", path: String(repeating: "a", count: 2000))])
        let second = ChatIndex(projects: [ChatProject(id: "b", path: String(repeating: "b", count: 2000))])
        try a.save(first)
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let store = i.isMultiple(of: 2) ? a : b
            do { try store.save(i.isMultiple(of: 2) ? first : second) } catch { failures.record() }
            let loaded = store.load()
            if loaded != first && loaded != second { failures.record() }
        }
        #expect(failures.value == 0)
        let final = a.load()
        #expect(final == first || final == second)
        try b.save(second)
        #expect(a.load() == second)
    }
}

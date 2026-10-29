import Foundation

// MARK: model

public struct ChatProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var name: String
    public var addedAt: Double
    public var lastActivity: Double
    public var isScratch: Bool
    /// When the user allowed Strim to work in this folder (outside the home folder) through the consent step. Only the
    /// consent sheet sets it; it lets a restarted host be re-granted without asking again. nil: never consented.
    public var folderConsent: Double?
    /// The resolved folder the user allowed (realpath at Allow time). A restarted host is re-granted this exact path, and
    /// only while the project's path still resolves to it. nil (older index): not consented, the user is asked again.
    public var consentRoot: String?
    public init(id: String = UUID().uuidString, path: String, name: String? = nil, addedAt: Double = 0, lastActivity: Double = 0, isScratch: Bool = false,
                folderConsent: Double? = nil, consentRoot: String? = nil) {
        self.id = id; self.path = path; self.addedAt = addedAt; self.lastActivity = lastActivity; self.isScratch = isScratch
        self.folderConsent = folderConsent; self.consentRoot = consentRoot
        self.name = name ?? (path as NSString).lastPathComponent
    }
}

public struct ChatThread: Codable, Equatable, Identifiable, Sendable {
    public static let defaultTitle = "New chat"
    public var id: String
    public var projectId: String
    public var title: String
    public var titleIsUser: Bool
    public var createdAt: Double
    public var lastActivity: Double
    public var thinking: Bool
    public var unread: Bool
    public var messageCount: Int
    public init(id: String = UUID().uuidString, projectId: String, title: String = ChatThread.defaultTitle, titleIsUser: Bool = false,
                createdAt: Double = 0, lastActivity: Double = 0, thinking: Bool = true, unread: Bool = false, messageCount: Int = 0) {
        self.id = id; self.projectId = projectId; self.title = title; self.titleIsUser = titleIsUser
        self.createdAt = createdAt; self.lastActivity = lastActivity; self.thinking = thinking; self.unread = unread
        self.messageCount = messageCount
    }
}

/// Persisted index (`index.json`). `notice`, `readOnly` and `isNew` are load-time facts and never written.
public struct ChatIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = ChatIndex.currentVersion
    public var projects: [ChatProject] = []
    public var threads: [ChatThread] = []
    /// Set by the store when something was repaired or skipped (shown to the user).
    public var notice: String?
    /// The file was written by a newer app version: do not write it back.
    public var readOnly = false
    /// No index existed on disk (first run): the caller may migrate.
    public var isNew = false
    public init(projects: [ChatProject] = [], threads: [ChatThread] = []) { self.projects = projects; self.threads = threads }
    enum CodingKeys: String, CodingKey { case version, projects, threads }
}

public struct StoredToolCard: Codable, Equatable, Sendable {
    public var name: String
    public var args: String
    public var result: String?
    public var isError: Bool
}
public struct StoredLedger: Codable, Equatable, Sendable {
    public var prompt: Int
    public var cached: Int
    public var completion: Int
    public var seconds: Double?
}

/// One transcript line in `threads/<id>.jsonl`.
public struct StoredMessage: Codable, Equatable, Sendable {
    public var v = 1
    public var id: String
    public var role: String
    public var text: String
    public var tool: StoredToolCard?
    public var ledger: StoredLedger?
    public var ts: Double
    public var sessionBreak: Bool?
    public var trimMarker: Bool?

    public static let maxToolBytes = 16 * 1024

    public init(id: String = UUID().uuidString, role: String, text: String, ts: Double = 0) {
        self.id = id; self.role = role; self.text = text; self.ts = ts
    }

    public init(_ m: ChatMessage, ts: Double) {
        id = m.id.uuidString; role = m.role.rawValue; self.ts = ts
        switch m.marker {
        case .sessionBreak?: sessionBreak = true; text = ""
        case .trimmed?: trimMarker = true; text = ""
        case nil: text = m.role == .tool ? Self.clip(m.text) : m.text
        }
        if let t = m.tool { tool = StoredToolCard(name: t.name, args: t.args, result: t.result.map(Self.clip), isError: t.isError) }
        if let l = m.ledger { ledger = StoredLedger(prompt: l.prompt, cached: l.cached, completion: l.completion, seconds: l.seconds) }
    }

    /// nil when the role is unknown (line is then skipped as unreadable).
    public var chatMessage: ChatMessage? {
        let marker: ChatMarker? = sessionBreak == true ? .sessionBreak : trimMarker == true ? .trimmed : nil
        guard let r = ChatMessage.Role(rawValue: role) ?? (marker != nil ? .assistant : nil) else { return nil }
        var m = ChatMessage(role: r, text: marker?.text ?? text)
        m.id = UUID(uuidString: id) ?? UUID()
        m.marker = marker
        if let t = tool { m.tool = ToolCard(name: t.name, args: t.args, result: t.result, isError: t.isError) }
        if let l = ledger { m.ledger = TokenLedger(prompt: l.prompt, cached: l.cached, completion: l.completion, seconds: l.seconds) }
        return m
    }

    static func clip(_ s: String) -> String {
        guard s.utf8.count > maxToolBytes else { return s }
        var out = String(decoding: Array(s.utf8.prefix(maxToolBytes)), as: UTF8.self)
        while out.last == "\u{FFFD}" { out.removeLast() }
        return out + "\n[truncated]"
    }
}

public enum ChatMarker: Equatable, Sendable {
    case sessionBreak, trimmed
    public var text: String {
        switch self {
        case .sessionBreak: "Session ended. The model does not see messages above this line."
        case .trimmed: "Earlier messages trimmed."
        }
    }
}

public struct LoadedThread: Equatable, Sendable {
    public var messages: [StoredMessage]
    /// Lines that could not be decoded.
    public var skipped: Int
    public init(messages: [StoredMessage] = [], skipped: Int = 0) { self.messages = messages; self.skipped = skipped }
}

public enum ChatLimits {
    public static let maxThreadBytes = 4 * 1024 * 1024
    public static let maxThreads = 500
}

// MARK: persistence

public protocol ChatPersisting: Sendable {
    func load() -> ChatIndex
    func save(_ index: ChatIndex) throws
    func loadThread(_ id: String) -> LoadedThread
    /// Appends messages (O(new)); trims the oldest past the byte limit.
    func appendThread(_ id: String, _ messages: [StoredMessage]) throws
    /// Atomic full rewrite (duplicate, edit).
    func rewriteThread(_ id: String, _ messages: [StoredMessage]) throws
    func deleteThread(_ id: String)
    /// Removes every transcript and the index.
    func deleteAll()
}

enum ChatCodec {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()
    static func line(_ m: StoredMessage) throws -> Data {
        var d = try encoder.encode(m); d.append(0x0A); return d
    }
    static func lines(_ ms: [StoredMessage]) throws -> Data {
        var d = Data(); for m in ms { d.append(try line(m)) }; return d
    }
    static func parse(_ data: Data) -> LoadedThread {
        var out = LoadedThread()
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let m = try? JSONDecoder().decode(StoredMessage.self, from: Data(raw)), m.chatMessage != nil { out.messages.append(m) }
            else { out.skipped += 1 }
        }
        return out
    }
    /// Drops the oldest messages until the encoded size fits, then puts a marker first.
    static func trim(_ ms: [StoredMessage], maxBytes: Int) -> [StoredMessage] {
        var sizes = ms.map { ((try? line($0))?.count) ?? 0 }
        var total = sizes.reduce(0, +)
        guard total > maxBytes else { return ms }
        var start = 0
        let target = maxBytes * 3 / 4
        while start < ms.count - 1, total > target { total -= sizes[start]; start += 1 }
        sizes.removeAll()
        var marker = StoredMessage(role: ChatMessage.Role.assistant.rawValue, text: "", ts: ms[start].ts)
        marker.trimMarker = true
        return [marker] + ms[start...].filter { $0.trimMarker != true }
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
}

/// `~/.strim/chats`: `index.json` plus `threads/<id>.jsonl`, 0600 files in 0700 directories.
public final class FileChatStore: ChatPersisting, @unchecked Sendable {
    public let root: String
    public let maxThreadBytes: Int
    private let lock = NSLock()

    public init(root: String = AppPaths.home + "/.strim/chats", maxThreadBytes: Int = ChatLimits.maxThreadBytes) {
        self.root = root; self.maxThreadBytes = maxThreadBytes
    }

    private var indexPath: String { root + "/index.json" }
    private var threadsDir: String { root + "/threads" }
    private func threadPath(_ id: String) -> String { threadsDir + "/" + id + ".jsonl" }
    private var corruptPath: String { root + "/index.corrupt-\(UUID().uuidString).json" }

    public func load() -> ChatIndex {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: indexPath) else {
            var idx = rebuild(reason: nil)
            idx.isNew = idx.threads.isEmpty
            if !idx.threads.isEmpty { idx.notice = "Chat index was missing; rebuilt from saved transcripts." }
            return idx
        }
        struct VersionOnly: Decodable { var version: Int }
        if let v = try? JSONDecoder().decode(VersionOnly.self, from: data), v.version > ChatIndex.currentVersion {
            var idx = (try? JSONDecoder().decode(ChatIndex.self, from: data)) ?? ChatIndex()
            idx.readOnly = true
            idx.notice = "Chat history was saved by a newer version of Strim. It is read-only here."
            return idx
        }
        guard var idx = try? JSONDecoder().decode(ChatIndex.self, from: data) else {
            let backedUp: Bool
            do { try FileManager.default.moveItem(atPath: indexPath, toPath: corruptPath); backedUp = true }
            catch { backedUp = false }
            var rebuilt = rebuild(reason: "corrupt")
            rebuilt.readOnly = !backedUp
            rebuilt.notice = backedUp ? "Chat index was damaged and has been rebuilt (\(rebuilt.threads.count) chats recovered)." : "Chat index was damaged and could not be backed up; history is read-only."
            return rebuilt
        }
        idx.threads = idx.threads.filter { ChatCodec.validID($0.id) }
        return idx
    }

    /// Index from `threads/*.jsonl`, all under one project with an unknown folder.
    private func rebuild(reason: String?) -> ChatIndex {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: threadsDir)) ?? []).filter { $0.hasSuffix(".jsonl") }
        guard !files.isEmpty else { return ChatIndex() }
        let project = ChatProject(path: "", name: "Unknown folder")
        var idx = ChatIndex(projects: [project])
        for f in files {
            let id = String(f.dropLast(6))
            guard ChatCodec.validID(id) else { continue }
            let t = ChatCodec.parse(FileManager.default.contents(atPath: threadPath(id)) ?? Data())
            guard !t.messages.isEmpty else { continue }
            let first = t.messages.first { $0.role == "user" }?.text
            let attrs = try? FileManager.default.attributesOfItem(atPath: threadPath(id))
            let when = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            idx.threads.append(ChatThread(id: id, projectId: project.id, title: first.map(Self.title) ?? ChatThread.defaultTitle,
                                          createdAt: t.messages.first?.ts ?? when, lastActivity: when, messageCount: t.messages.count))
        }
        if idx.threads.isEmpty { return ChatIndex() }
        return idx
    }

    static func title(_ text: String) -> String {
        let s = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(s.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    public func save(_ index: ChatIndex) throws {
        lock.lock(); defer { lock.unlock() }
        guard !index.readOnly else { return }
        if FileManager.default.fileExists(atPath: indexPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: indexPath))
            if (try? JSONDecoder().decode(ChatIndex.self, from: data)) == nil {
                try SecureFS.writeAtomically(data, to: corruptPath)
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SecureFS.writeAtomically(try enc.encode(index), to: indexPath)
    }

    public func loadThread(_ id: String) -> LoadedThread {
        lock.lock(); defer { lock.unlock() }
        guard ChatCodec.validID(id), let d = FileManager.default.contents(atPath: threadPath(id)) else { return LoadedThread() }
        return ChatCodec.parse(d)
    }

    public func appendThread(_ id: String, _ messages: [StoredMessage]) throws {
        lock.lock(); defer { lock.unlock() }
        guard ChatCodec.validID(id) else { throw SecureFSError(message: "invalid thread id") }
        guard !messages.isEmpty else { return }
        let path = threadPath(id)
        let h = try SecureFS.openAppend(path)
        defer { try? h.close() }
        var data = try ChatCodec.lines(messages)
        var st = stat()
        guard fstat(h.fileDescriptor, &st) == 0 else { throw SecureFSError(message: "cannot stat \(path)") }
        if st.st_size > 0 {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw SecureFSError(message: "cannot read \(path)") }
            var last: UInt8 = 0
            let n = pread(fd, &last, 1, st.st_size - 1)
            close(fd)
            guard n == 1 else { throw SecureFSError(message: "cannot read \(path)") }
            if last != 0x0A { data.insert(0x0A, at: 0) }
        }
        try h.write(contentsOf: data)
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        if size > maxThreadBytes {
            let all = ChatCodec.parse(FileManager.default.contents(atPath: path) ?? Data()).messages
            try SecureFS.writeAtomically(try ChatCodec.lines(ChatCodec.trim(all, maxBytes: maxThreadBytes)), to: path)
        }
    }

    public func rewriteThread(_ id: String, _ messages: [StoredMessage]) throws {
        lock.lock(); defer { lock.unlock() }
        guard ChatCodec.validID(id) else { throw SecureFSError(message: "invalid thread id") }
        try SecureFS.writeAtomically(try ChatCodec.lines(ChatCodec.trim(messages, maxBytes: maxThreadBytes)), to: threadPath(id))
    }

    public func deleteThread(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard ChatCodec.validID(id) else { return }
        unlink(threadPath(id))
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: threadsDir)) ?? [] where f.hasSuffix(".jsonl") { unlink(threadsDir + "/" + f) }
        unlink(indexPath)
    }
}

/// In-memory store for tests and snapshot fixtures.
public final class MemoryChatStore: ChatPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var index: ChatIndex
    private var threads: [String: [StoredMessage]] = [:]
    public let maxThreadBytes: Int
    public private(set) var saveCount = 0

    public init(index: ChatIndex? = nil, maxThreadBytes: Int = ChatLimits.maxThreadBytes) {
        var i = index ?? ChatIndex(); if index == nil { i.isNew = true }
        self.index = i; self.maxThreadBytes = maxThreadBytes
    }
    public func seed(_ id: String, _ messages: [StoredMessage]) { lock.lock(); threads[id] = messages; lock.unlock() }
    public var storedIndex: ChatIndex { lock.lock(); defer { lock.unlock() }; return index }
    public func stored(_ id: String) -> [StoredMessage] { lock.lock(); defer { lock.unlock() }; return threads[id] ?? [] }

    public func load() -> ChatIndex { lock.lock(); defer { lock.unlock() }; return index }
    public func save(_ i: ChatIndex) throws {
        lock.lock(); defer { lock.unlock() }
        var n = i; n.isNew = false; n.notice = nil; index = n; saveCount += 1
    }
    public func loadThread(_ id: String) -> LoadedThread { lock.lock(); defer { lock.unlock() }; return LoadedThread(messages: threads[id] ?? []) }
    public func appendThread(_ id: String, _ messages: [StoredMessage]) throws {
        lock.lock(); defer { lock.unlock() }
        threads[id, default: []] += messages
        threads[id] = ChatCodec.trim(threads[id] ?? [], maxBytes: maxThreadBytes)
    }
    public func rewriteThread(_ id: String, _ messages: [StoredMessage]) throws {
        lock.lock(); defer { lock.unlock() }
        threads[id] = ChatCodec.trim(messages, maxBytes: maxThreadBytes)
    }
    public func deleteThread(_ id: String) { lock.lock(); threads[id] = nil; lock.unlock() }
    public func deleteAll() { lock.lock(); threads = [:]; index = ChatIndex(); lock.unlock() }
}

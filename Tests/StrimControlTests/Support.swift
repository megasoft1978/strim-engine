import Foundation
import StrimAPI
import StrimEngine
import StrimHarness
import StrimHost
import StrimHTTP
import StrimJobs
import StrimServer
@testable import StrimControl

// MARK: fakes

final class CtlFakeEngine: EngineClient, @unchecked Sendable {
    private let lock = NSLock(); private var next: UInt64 = 0
    var script: [GenEvent] = []
    var stats0: EngineStats = { var s = EngineStats(); s.mlxActiveBytes = 4 << 30; s.budgetBytes = 20 << 30; s.trieBytes = 1 << 30; s.mlxCacheBytes = 1 << 29; return s }()
    func openSession(_ config: SessionConfig) async throws -> SessionID { lock.withLock { next += 1; return SessionID(raw: next) } }
    func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID { session }
    func append(_ session: SessionID, _ input: TurnInput) async throws -> Int { 1 }
    func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> {
        let evs = script
        return AsyncThrowingStream { c in for e in evs { c.yield(e) }; c.finish() }
    }
    func cancel(_ session: SessionID) async {}
    func prefetch(_ ids: [Int32], priority: Priority) async throws {}
    func ledger(_ session: SessionID) async throws -> LedgerSnapshot { LedgerSnapshot(ids: [], messageCount: 0) }
    func close(_ session: SessionID) async {}
    func stats() -> EngineStats { stats0 }
}

/// Scriptable chat backend. `hang` keeps a turn open until it is cancelled or its stream is dropped.
final class FakeChat: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [(String, String, RunProfile)] = []
    private(set) var cancelTurns: [String] = []
    private(set) var closed: [String] = []
    private(set) var terminated = 0
    private var active: Set<String> = []
    var events: [ChatEvent] = [
        .stepStarted(1), .textDelta("hello "), .toolCallStarted(name: "read_file", summary: "a.txt"),
        .toolCallFinished(name: "read_file", summary: "ok", isError: false), .textDelta("world"),
        .usage(promptTokens: 10, cachedTokens: 4, completionTokens: 2),
        .turnFinished(ChatTurnResult(userTurn: 1, status: .done, summary: "all done", usage: HarnessUsage(), totalUsage: HarnessUsage())),
    ]
    var hang = false
    var openError: Error?

    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws {
        if let e = openError { throw e }
        lock.withLock { opened.append((sessionID, spec.cwd, profile)) }
    }

    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> {
        lock.withLock { _ = active.insert(sessionID) }
        let evs = events, hang = hang
        let (stream, cont) = AsyncStream<ChatEvent>.makeStream()
        let task = Task {
            for e in evs {
                if case .turnFinished = e, hang { try? await Task.sleep(for: .seconds(30)) }
                if Task.isCancelled { cont.finish(); return }
                cont.yield(e)
                try? await Task.sleep(for: .milliseconds(5))
            }
            cont.finish()
        }
        cont.onTermination = { [weak self] reason in
            task.cancel()
            if case .cancelled = reason { self?.lock.withLock { self?.terminated += 1 } }
        }
        return stream
    }

    func cancelTurn(sessionID: String) async { lock.withLock { cancelTurns.append(sessionID) } }
    func closeSession(sessionID: String) async -> HarnessJobResult? {
        lock.withLock { closed.append(sessionID) }
        return HarnessJobResult(status: .done, summary: "session closed")
    }
    var cancelCount: Int { lock.withLock { cancelTurns.count } }
    var terminatedCount: Int { lock.withLock { terminated } }
}

// MARK: rig

func tmpDir(_ tag: String = "ctl") -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

struct Rig {
    let server: StrimOpenAIServer
    let port: UInt16
    let plane: StrimControlPlane
    let slot: EngineSlot
    let jobs: JobManager
    let store: FileJobStore
    let jobsRoot: URL
    let chat: FakeChat
    let engine: CtlFakeEngine
    let token: String?
    let control = "ctl-secret-token"

    func stop() { server.stop() }

    static func make(token: String? = "tok", load: Bool = true, requireApproval: Bool = false,
                     executor: JobExecutor? = nil, patch: String? = nil, policy: HostPolicy = HostPolicy(maxAccess: .write, allowedRoots: []),
                     factory: EngineSlot.Factory? = nil, maxChat: Int = 2,
                     currentPatch: (@Sendable (String) async throws -> String)? = nil,
                     options: StrimControlPlane.Options = {
                         var o = StrimControlPlane.Options()
                         o.statusInterval = .milliseconds(100); o.jobPollInterval = .milliseconds(30); o.pingInterval = .milliseconds(150)
                         o.orphanTurnGrace = .milliseconds(300)
                         o.modelRoots = ["/models"]
                         return o
                     }()) async throws -> Rig {
        let engine = CtlFakeEngine()
        let jobsRoot = tmpDir("jobs")
        let store = FileJobStore(root: jobsRoot)
        let slot = EngineSlot(factory: factory ?? { _, _, _ in engine }, busyProbe: { await StrimControlPlane.activeWork(in: store) })
        if load { try await slot.load(model: "/models/Qwen-27B", mtp: "/models/head") }
        let chat = FakeChat()
        let exec: JobExecutor = executor ?? { spec, id, _ in
            guard let patch else { return HarnessJobResult(status: .done, summary: "ok") }
            let dir = jobsRoot.appendingPathComponent(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("patch.diff").path
            try? patch.write(toFile: path, atomically: true, encoding: .utf8)
            return HarnessJobResult(status: .done, summary: "patched", patchPath: path, verify: VerifyResult(status: .verified, outputTail: "3 passed"))
        }
        let jobs = JobManager(executor: exec, store: store, requireApproval: requireApproval,
                              pollInterval: .seconds(30), chat: chat, maxChatSessions: maxChat)
        let server = StrimOpenAIServer(engine: slot.client, config: ServerConfig(modelId: "m", bearerToken: token))
        let plane = StrimControlPlane(slot: slot, jobs: jobs, store: store, jobsRoot: jobsRoot, policy: policy,
                                      currentPatch: currentPatch, auth: ControlAuth(controlToken: "ctl-secret-token", apiToken: token), options: options)
        plane.register(on: server)
        let port = try await server.start(port: 0)
        return Rig(server: server, port: port, plane: plane, slot: slot, jobs: jobs, store: store, jobsRoot: jobsRoot,
                   chat: chat, engine: engine, token: token)
    }

    func call(_ method: String, _ path: String, body: String? = nil, auth: Bool = true, host: String? = nil,
              headers: [String: String] = [:], json: Bool = true, bearer: String? = nil) async -> HTTPReply {
        var h = headers
        if let bearer { h["Authorization"] = "Bearer \(bearer)" }
        else if auth { h["Authorization"] = "Bearer \(control)" }
        if let body, json, h["Content-Type"] == nil { h["Content-Type"] = "application/json" }
        return await Raw.exchange(port: port, method: method, path: path, host: host ?? "127.0.0.1", headers: h, body: body)
    }
}

// MARK: raw HTTP

struct HTTPReply {
    var status: Int
    var headers: [String: String]
    var body: String
    var data: Data { Data(body.utf8) }
    var code: String { (try? error().code) ?? "" }
    var state: HostState? { try? decode(HostStatus.self).state }
    var detail: JobDetail? { try? decode(JobDetail.self) }
    func decode<T: Decodable>(_ t: T.Type) throws -> T { try JSONDecoder().decode(t, from: data) }
    func error() throws -> APIError { try decode(APIErrorEnvelope.self).error }
    func keys() throws -> Set<String> {
        Set(((try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]).keys)
    }
}

enum Raw {
    static func connect(_ port: UInt16, timeout: Int = 5) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); return -1 }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func request(method: String, path: String, host: String, headers: [String: String], body: String?, close: Bool) -> String {
        var req = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        if close { req += "Connection: close\r\n" }
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        let b = body ?? ""
        if body != nil || method == "POST" { req += "Content-Length: \(b.utf8.count)\r\n" }
        return req + "\r\n" + b
    }

    static func send(_ fd: Int32, _ s: String) {
        _ = Array(s.utf8).withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    static func exchange(port: UInt16, method: String, path: String, host: String, headers: [String: String], body: String?) async -> HTTPReply {
        await Task.detached {
            let fd = connect(port)
            guard fd >= 0 else { return HTTPReply(status: 0, headers: [:], body: "") }
            defer { close(fd) }
            send(fd, request(method: method, path: path, host: host, headers: headers, body: body, close: true))
            var out = [UInt8](); var buf = [UInt8](repeating: 0, count: 8192)
            while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out += buf[0..<n] }
            return parse(String(decoding: out, as: UTF8.self))
        }.value
    }

    static func parse(_ raw: String) -> HTTPReply {
        guard let r = raw.range(of: "\r\n\r\n") else { return HTTPReply(status: 0, headers: [:], body: raw) }
        let head = raw[..<r.lowerBound].components(separatedBy: "\r\n")
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        var h: [String: String] = [:]
        for l in head.dropFirst() { if let c = l.firstIndex(of: ":") { h[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
        var body = String(raw[r.upperBound...])
        if h["transfer-encoding"] == "chunked" { body = dechunk(body) }
        return HTTPReply(status: status, headers: h, body: body)
    }

    static func dechunk(_ s: String) -> String {
        let b = Array(s.utf8)
        var out = [UInt8](); var i = 0
        func crlf(_ at: Int) -> Int? { (at + 1 < b.count) ? (0..<(b.count - 1)).first { $0 >= at && b[$0] == 13 && b[$0 + 1] == 10 } : nil }
        while let e = crlf(i) {
            guard let n = Int(String(decoding: b[i..<e], as: UTF8.self), radix: 16), n > 0 else { break }
            let start = e + 2
            out += b[start..<min(start + n, b.count)]
            i = start + n + 2
            if i >= b.count { break }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// An open SSE connection.
final class SSEClient: @unchecked Sendable {
    let fd: Int32
    private(set) var head = ""
    private var rawAll = [UInt8]()
    init?(port: UInt16, path: String, token: String?, extra: [String: String] = [:]) {
        fd = Raw.connect(port, timeout: 1)
        guard fd >= 0 else { return nil }
        var h = extra
        if let token { h["Authorization"] = "Bearer \(token)" }
        h["Accept"] = "text/event-stream"
        Raw.send(fd, Raw.request(method: "GET", path: path, host: "127.0.0.1", headers: h, body: nil, close: false))
    }
    init?(port: UInt16, method: String, path: String, token: String?, body: String) {
        fd = Raw.connect(port, timeout: 1)
        guard fd >= 0 else { return nil }
        let h = ["Authorization": "Bearer \(token ?? "")", "Accept": "text/event-stream", "Content-Type": "application/json"]
        Raw.send(fd, Raw.request(method: method, path: path, host: "127.0.0.1", headers: h, body: body, close: false))
    }
    deinit { close(fd) }

    /// Reads until `done(decoded text so far)` or `timeout` seconds. Returns the decoded (de-chunked) text.
    func read(timeout: TimeInterval = 5, until done: @escaping @Sendable (String) -> Bool) async -> String {
        await Task.detached { [self] in
            let deadline = Date().addingTimeInterval(timeout)
            var buf = [UInt8](repeating: 0, count: 8192)
            func current() -> String {
                let s = String(decoding: self.rawAll, as: UTF8.self)
                self.head = s.components(separatedBy: "\r\n\r\n").first ?? ""
                return Raw.parse(s).body
            }
            if done(current()) { return current() }
            while Date() < deadline {
                let n = recv(fd, &buf, buf.count, 0)
                if n == 0 { break }
                if n > 0 {
                    self.rawAll += buf[0..<n]
                    if done(current()) { break }
                }
            }
            return current()
        }.value
    }

    func frames(_ text: String) -> [(event: String, data: String)] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var ev = "", data = ""
            for l in block.split(separator: "\n") {
                if l.hasPrefix("event: ") { ev = String(l.dropFirst(7)) } else if l.hasPrefix("data: ") { data = String(l.dropFirst(6)) }
            }
            return ev.isEmpty ? nil : (ev, data)
        }
    }
}

// MARK: git helper

@discardableResult
func git(_ args: [String], in dir: String, stdin: String? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: SandboxProfile.trustedGitPath ?? "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                     "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
    try p.run()
    let out = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: out, as: UTF8.self)
}

/// A repo with `a.txt` ("one\n") and `sub/b.txt` ("bee\n") committed, plus the patch that edits both.
func makeRepo() throws -> (repo: String, patch: String) {
    let repo = tmpDir("repo").resolvingSymlinksInPath().path
    try git(["init", "-q", "-b", "main"], in: repo)
    try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
    try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try "bee\n".write(toFile: repo + "/sub/b.txt", atomically: true, encoding: .utf8)
    try git(["add", "."], in: repo)
    try git(["commit", "-q", "-m", "init"], in: repo)
    try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try "bee\nbuzz\n".write(toFile: repo + "/sub/b.txt", atomically: true, encoding: .utf8)
    let patch = try git(["diff"], in: repo)
    try git(["checkout", "-q", "--", "."], in: repo)
    return (repo, patch)
}

/// Submits a job and waits until it finished.
func runJob(_ r: Rig, cwd: String) async throws -> String {
    let id = try await r.jobs.submit(HarnessJobSpec(task: "fix it", cwd: cwd, access: .write), priority: .normal)
    _ = try await r.jobs.status(id, waitS: 10)
    await r.jobs.flush()
    return id
}

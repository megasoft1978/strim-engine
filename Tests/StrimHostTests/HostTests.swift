import Foundation
import Testing
import StrimEngine
import StrimHarness
import StrimJobs
import StrimServer
@testable import StrimHost

/// Engine stub: the host tests never generate (the executor is injected), so nothing here loads a model.
private final class StubEngine: EngineClient, @unchecked Sendable {
    func openSession(_ config: SessionConfig) async throws -> SessionID { SessionID(raw: 1) }
    func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID { session }
    func append(_ session: SessionID, _ input: TurnInput) async throws -> Int { 1 }
    func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancel(_ session: SessionID) async {}
    func prefetch(_ ids: [Int32], priority: Priority) async throws {}
    func ledger(_ session: SessionID) async throws -> LedgerSnapshot { LedgerSnapshot(ids: [], messageCount: 0, ledger: nil) }
    func close(_ session: SessionID) async {}
    func stats() -> EngineStats { EngineStats() }
}

private func tempRoot() -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strimhost-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func rawPost(port: UInt16, path: String = "/mcp", token: String?, body: String) async -> String {
    await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return "" }
        var req = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { req += "Authorization: Bearer \(token)\r\n" }
        req += "\r\n" + body
        _ = Array(req.utf8).withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }.value
}

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func bump() { l.withLock { n += 1 } }
    var value: Int { l.withLock { n } }
}

@Suite("StrimHost config and lock")
struct HostConfigTests {
    @Test("defaults when file is missing")
    func defaults() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let c = try HostConfig.load(from: root.appendingPathComponent("config.json"))
        #expect(c == HostConfig(requireApproval: false, maxAccess: .write, allowedRoots: []))
    }

    @Test("parses keys and tightens permissions to 0600")
    func parse() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"mcp":{"requireApproval":true,"maxAccess":"read","allowedRoots":["/a","~/b"]}}"#.utf8).write(to: url)
        chmod(url.path, 0o644)
        let c = try HostConfig.load(from: url)
        #expect(c.requireApproval && c.maxAccess == .read)
        #expect(c.allowedRoots == ["/a", (("~/b") as NSString).expandingTildeInPath])
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o600)
    }

    @Test("invalid values are errors, write() is 0600")
    func invalid() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"mcp":{"maxAccess":"admin"}}"#.utf8).write(to: url)
        #expect(throws: HostConfigError.self) { try HostConfig.load(from: url) }
        let out = root.appendingPathComponent("sub/c.json")
        try HostConfig(maxAccess: .read).write(to: out)
        let mode = (try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o600)
        #expect(try HostConfig.load(from: out).maxAccess == .read)
    }

    @Test("second host fails fast naming the pid; release frees it")
    func lockExclusive() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("host.lock")
        let first = try HostLock.acquire(at: url)
        do {
            _ = try HostLock.acquire(at: url)
            Issue.record("second acquire should fail")
        } catch let e as HostLockError {
            #expect(e.pid == getpid())
            #expect(e.description.contains("\(getpid())"))
        }
        first.release()
        let again = try HostLock.acquire(at: url)
        again.release()
    }

    @Test("policy: write vs read-only host, allowed roots incl. traversal")
    func policy() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("proj"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let ro = HostPolicy(maxAccess: .read, allowedRoots: [])
        #expect(ro.violation(access: "write", cwd: "/x") != nil)
        #expect(ro.violation(access: "read", cwd: "/x") == nil)
        let rooted = HostPolicy(maxAccess: .write, allowedRoots: [proj.path])
        #expect(rooted.violation(access: "write", cwd: proj.path) == nil)
        #expect(rooted.violation(access: "read", cwd: proj.path + "/sub") == nil)
        #expect(rooted.violation(access: "read", cwd: root.path) != nil)
        #expect(rooted.violation(access: "read", cwd: proj.path + "/../other") != nil)
        #expect(rooted.violation(access: "read", cwd: proj.path + "-evil") != nil)
        #expect(rooted.violation(access: "read", cwd: nil) != nil)
    }

    @Test("mcp-config output has the flags and no token")
    func mcpConfig() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tokenFile = root.appendingPathComponent("token")
        let secret = "deadbeefcafe0123456789secrettoken"
        try Data((secret + "\n").utf8).write(to: tokenFile)
        let claude = McpConfig.render(.claude, port: 9100)
        let codex = McpConfig.render(.codex, port: 9100)
        let hdr = "-t http strim http://127.0.0.1:9100/mcp -H \"Authorization: Bearer $(cat ~/.strim/token)\""
        #expect(claude.contains("claude mcp add -s local \(hdr)\n"))
        #expect(claude.contains("# Alternative, all projects:\nclaude mcp add -s user \(hdr)\n"))
        #expect(claude.contains("Do NOT use -s project"))
        #expect(!claude.contains("claude mcp add -s project"))
        #expect(codex.contains("export STRIM_TOKEN=$(cat ~/.strim/token)"))
        #expect(codex.contains("codex mcp add strim --url http://127.0.0.1:9100/mcp --bearer-token-env-var STRIM_TOKEN"))
        #expect(codex.contains(#"default_tools_approval_mode = "approve""#))
        #expect(!claude.contains(secret) && !codex.contains(secret))
    }
}

@Suite("StrimHost server", .serialized)
struct HostServerTests {
    private func makeHost(root: URL, config: HostConfig, counter: Counter) -> StrimHost {
        let exec: JobExecutor = { _, _, onEvent in
            counter.bump(); onEvent(.finished(.done))
            return HarnessJobResult(status: .done, summary: "ok")
        }
        return StrimHost(engine: StubEngine(), serverConfig: ServerConfig(modelId: "m", bearerToken: "tok"),
                         hostConfig: config, paths: HostPaths(root: root), sandboxed: false, executor: exec)
    }

    private func call(_ port: UInt16, _ args: String) async -> String {
        await rawPost(port: port, token: "tok", body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"strim_task","arguments":\#(args)}}"#)
    }

    @Test("/mcp is reachable through the host with bearer, 401 without; lock held until shutdown")
    func reachable() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(root: root, config: HostConfig(), counter: Counter())
        let port = try await host.start(port: 0)
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let ok = await rawPost(port: port, token: "tok", body: list)
        #expect(ok.hasPrefix("HTTP/1.1 200") && ok.contains("strim_task") && ok.contains("strim_cancel"))
        #expect(await rawPost(port: port, token: nil, body: list).hasPrefix("HTTP/1.1 401"))
        #expect(await rawPost(port: port, token: "wrong", body: list).hasPrefix("HTTP/1.1 401"))
        // Second host on the same root cannot start while the first is up.
        let second = makeHost(root: root, config: HostConfig(), counter: Counter())
        await #expect(throws: HostLockError.self) { _ = try await second.start(port: 0) }
        await host.shutdown()
        let third = makeHost(root: root, config: HostConfig(), counter: Counter())
        _ = try await third.start(port: 0)
        await third.shutdown()
    }

    @Test("maxAccess=read rejects access=write before submit; read is accepted")
    func maxAccess() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let host = makeHost(root: root, config: HostConfig(maxAccess: .read), counter: counter)
        let port = try await host.start(port: 0)
        let w = await call(port, #"{"task":"t","cwd":"/tmp","access":"write"}"#)
        #expect(w.contains(#""isError": true"#) && w.contains("read access only"))
        let r = await call(port, #"{"task":"t","cwd":"/tmp","access":"read","wait_s":5}"#)
        #expect(!r.contains(#""isError": true"#))
        await host.jobs.flush()
        #expect(counter.value == 1)
        await host.shutdown()
    }

    @Test("allowedRoots rejects cwd outside; accepts inside")
    func allowedRoots() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let proj = root.appendingPathComponent("proj"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let counter = Counter()
        let host = makeHost(root: root, config: HostConfig(allowedRoots: [proj.path]), counter: counter)
        let port = try await host.start(port: 0)
        let bad = await call(port, #"{"task":"t","cwd":"/usr"}"#)
        #expect(bad.contains(#""isError": true"#) && bad.contains("outside the allowed roots"))
        let ask = await rawPost(port: port, token: "tok", body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"strim_ask","arguments":{"question":"q","cwd":"/usr"}}}"#)
        #expect(ask.contains(#""isError": true"#))
        let good = await call(port, #"{"task":"t","cwd":"\#(proj.path)","wait_s":5}"#)
        #expect(!good.contains(#""isError": true"#))
        await host.jobs.flush()
        #expect(counter.value == 1)
        await host.shutdown()
    }
}

@Suite("StrimHost shutdown", .serialized)
struct HostShutdownTests {
    @Test("shutdown while a job runs waits for executor cleanup (no leftover worktree) and releases the lock")
    func shutdownCleansUp() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let wt = root.appendingPathComponent("fake-worktree")
        let started = Counter()
        let exec: JobExecutor = { _, _, onEvent in
            try? FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
            started.bump()
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(300))   // slow cleanup after cancellation
            try? FileManager.default.removeItem(at: wt)
            onEvent(.finished(.cancelled))
            return HarnessJobResult(status: .cancelled, summary: "cancelled")
        }
        let host = StrimHost(engine: StubEngine(), serverConfig: ServerConfig(modelId: "m", bearerToken: "tok"),
                             paths: HostPaths(root: root), sandboxed: false, executor: exec)
        _ = try await host.start(port: 0)
        let id = try await host.jobs.submit(HarnessJobSpec(task: "t", cwd: "/tmp"), priority: .normal)
        for _ in 0..<100 where started.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: wt.path))
        await host.shutdown()
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try await host.jobs.status(id, waitS: 0).status == .cancelled)
        let lock = try HostLock.acquire(at: HostPaths(root: root).lock)   // released
        lock.release()
    }

    @Test("orphan sweep kills a same-uid process carrying STRIM_JOB=, leaves others")
    func orphanSweep() async throws {
        // Platform binaries (/bin/sleep) hide their environment from sysctl, so use a copy.
        let dir = tempRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("sleepcopy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "--force", copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        let marked = Process()
        marked.executableURL = copy; marked.arguments = ["60"]
        marked.environment = ["STRIM_JOB": "orphan-test-\(UUID().uuidString)", "PATH": "/usr/bin:/bin"]
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/sleep"); plain.arguments = ["60"]
        try marked.run(); try plain.run()
        defer { plain.terminate(); marked.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(OrphanSweep.killMarkedProcesses() >= 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!marked.isRunning)
        #expect(plain.isRunning)
    }
}

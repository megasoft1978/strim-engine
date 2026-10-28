import Foundation
@testable import StrimBenchHTTP

enum TestPaths {
    /// Repo root: Tests/StrimBenchHTTPTests/<file> -> three levels up.
    static let root: String = {
        var u = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        for _ in 0 ..< 3 { u.deleteLastPathComponent() }
        return u.path
    }()
    static var committedRun: String { root + "/bench/results/final-20261026" }
    static var hasCommittedRun: Bool { FileManager.default.fileExists(atPath: committedRun + "/results.json") }

    static func tempDir(_ name: String = "l5b") -> String {
        let d = NSTemporaryDirectory() + "strim-\(name)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
}

/// OpenAI-compatible fake server on a loopback socket (one thread per connection). The first path segment picks the
/// behaviour: full, bare, short, reason, slow, early, err500, hang, badjson, tool (tool_calls first), on/off/log (prefix cache model).
final class FakeServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var bodies: [String: [JSONValue]] = [:]
    private var caches: [String: [String]] = [:]
    private var running = true
    var logPath: String?
    var modelsID = "fake-model"
    var tokenDelay: TimeInterval = 0.002
    var prefillPerToken: TimeInterval = 1e-5

    func start(port wanted: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(wanted.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 64) == 0 else { throw BenchError("fake server bind failed") }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: out.sin_port)
        listenFD = fd
        Thread.detachNewThread { [self] in
            while running {
                let c = accept(listenFD, nil, nil)
                if c < 0 { break }
                Thread.detachNewThread { [self] in serve(c) }
            }
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
    }

    func url(_ mode: String = "full") -> String { "http://127.0.0.1:\(port)/\(mode)" }

    func lastBody(_ mode: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return bodies[mode]?.last }
    func bodyCount(_ mode: String) -> Int { lock.lock(); defer { lock.unlock() }; return bodies[mode]?.count ?? 0 }
    func lastSystem(_ mode: String) -> String? {
        guard let b = lastBody(mode), let m = b["messages"].array?.first, m["role"].string == "system" else { return nil }
        return m["content"].string
    }

    private func readRequest(_ fd: Int32) -> (head: String, body: Data)? {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0 ..< n])
            headEnd = buf.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(decoding: buf[..<headEnd!.lowerBound], as: UTF8.self)
        var body = Data(buf[headEnd!.upperBound...])
        var want = 0
        for l in head.split(separator: "\r\n") where l.lowercased().hasPrefix("content-length:") {
            want = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        while body.count < want {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0 ..< n])
        }
        return (head, body)
    }

    private func writeAll(_ fd: Int32, _ s: String) -> Bool {
        let d = Array(s.utf8)
        var off = 0
        while off < d.count {
            let n = d[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private func chunk(_ fd: Int32, _ payload: String) -> Bool {
        writeAll(fd, String(payload.utf8.count, radix: 16) + "\r\n" + payload + "\r\n")
    }

    private func event(_ fd: Int32, _ obj: JSONValue) -> Bool { chunk(fd, "data: \(JSON.dumps(obj))\n\n") }

    static func promptTokens(_ messages: [JSONValue]) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\w+|[^\w\s]"#)
        func words(_ s: String) -> [String] {
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        var out: [String] = []
        for m in messages {
            out.append(m["role"].string ?? "")
            out += words(m["content"].string ?? "")
            if case .object(let o) = m {
                var extra = JSONObject()
                for mem in o.members where mem.key != "role" && mem.key != "content" { extra[mem.key] = mem.value }
                if !extra.members.isEmpty {
                    let sorted = JSONObject.sortedKeys(extra)
                    out += words(JSON.dumps(.object(sorted), ensureASCII: false))
                }
            }
            out.append("<sep>")
        }
        return out
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let (head, bodyData) = readRequest(fd) else { return }
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : "/"
        if method == "GET" {
            if path == "/v1/models" {
                let b = JSON.dumps(.obj(["data": .array([.obj(["id": .string(modelsID)])])]))
                _ = writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(b.utf8.count)\r\nConnection: close\r\n\r\n\(b)")
            } else {
                _ = writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            }
            return
        }
        let mode = path.split(separator: "/").first.map(String.init) ?? ""
        let body = (try? JSON.parse(bodyData)) ?? .null
        lock.lock(); bodies[mode, default: []].append(body); lock.unlock()
        let n = body["max_tokens"].int ?? 8
        let messages = body["messages"].array ?? []
        let ptoks = Self.promptTokens(messages)
        switch mode {
        case "err500":
            _ = writeAll(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\nConnection: close\r\n\r\nboom")
            return
        case "hang":
            sleep(4)
            return
        default: break
        }
        guard writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n") else { return }
        var cached = 0
        if ["on", "log", "nonce"].contains(mode) {
            lock.lock()
            let prev = caches[mode] ?? []
            var l = 0
            while l < min(prev.count, ptoks.count), prev[l] == ptoks[l] { l += 1 }
            caches[mode] = ptoks
            lock.unlock()
            cached = (l / 16) * 16
        }
        if ["on", "off", "log", "nonce"].contains(mode) { Thread.sleep(forTimeInterval: Double(ptoks.count - cached) * prefillPerToken) }
        let toks = mode == "short" ? max(1, n - 1) : n
        let delay = mode == "slow" ? 0.03 : tokenDelay
        if mode == "badjson" {
            _ = event(fd, .obj(["choices": .array([.obj(["delta": .obj(["content": " a"])])])]))
            _ = chunk(fd, "data: {not json}\n\n")
            _ = chunk(fd, "data: [DONE]\n\n")
            _ = writeAll(fd, "0\r\n\r\n")
            return
        }
        for i in 0 ..< toks {
            Thread.sleep(forTimeInterval: delay)
            var delta: JSONValue
            switch mode {
            case "reason": delta = i % 2 == 0 ? .obj(["reasoning_content": .string(" r\(i)")]) : .obj(["reasoning": .string(" r\(i)")])
            case "tool": delta = i == 0 ? .obj(["tool_calls": .array([.obj(["index": 0])])]) : .obj(["content": .string(" t\(i)")])
            default: delta = .obj(["content": .string(" t\(i)")])
            }
            if !event(fd, .obj(["choices": .array([.obj(["index": 0, "delta": delta])])])) { return }
            if mode == "early", i == 1 { return }  // close mid-stream without the terminating chunk
        }
        if mode != "bare" {
            let words = messages.first?["content"].string?.split(separator: " ").count ?? 0
            let pt = ["on", "off", "log", "nonce"].contains(mode) ? ptoks.count : words
            var usage: JSONObject = JSONObject()
            usage["prompt_tokens"] = .int(pt)
            usage["completion_tokens"] = .int(toks)
            usage["total_tokens"] = .int(pt + toks)
            if mode == "full" { usage["prompt_tokens_details"] = .obj(["cached_tokens": 0]) }
            if mode == "on" || mode == "off" || mode == "nonce" { usage["prompt_tokens_details"] = .obj(["cached_tokens": .int(cached)]) }
            if mode == "log", let lp = logPath {
                if let h = FileHandle(forWritingAtPath: lp) { _ = try? h.seekToEnd(); h.write(Data("prefix cache hits=\(cached)\n".utf8)); try? h.close() }
            }
            _ = event(fd, .obj(["choices": .array([]), "usage": .object(usage)]))
        }
        if mode != "nodone" { _ = chunk(fd, "data: [DONE]\n\n") }
        _ = writeAll(fd, "0\r\n\r\n")
    }
}

extension JSONObject {
    static func sortedKeys(_ o: JSONObject) -> JSONObject {
        var out = JSONObject()
        for m in o.members.sorted(by: { $0.key < $1.key }) { out[m.key] = m.value }
        return out
    }
}

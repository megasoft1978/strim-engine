import Foundation
import Testing
@testable import StrimBenchHTTP

/// One token per UTF-8 byte: prompt lengths are exact and the needle position is checkable byte for byte.
struct ByteTokenizer: TextTokenizer {
    func encode(_ text: String) -> [Int] { text.utf8.map { Int($0) } }
    func decode(_ ids: [Int]) -> String { String(decoding: ids.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self) }
}

/// Loopback chat endpoint for the needle client. The first path segment picks the behaviour: `ok` answers the code only when
/// the prompt holds the needle sentence, `err` returns HTTP 500. Every request's Authorization header and body are recorded.
final class NeedleStubServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var seen: [(auth: String?, body: JSONValue)] = []

    var requests: [(auth: String?, body: JSONValue)] { lock.lock(); defer { lock.unlock() }; return seen }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 16) == 0 else { throw BenchError("needle stub bind failed") }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: out.sin_port)
        listenFD = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                Thread.detachNewThread { [self] in serve(c) }
            }
        }
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
    }

    func url(_ mode: String) -> String { "http://127.0.0.1:\(port)/\(mode)" }

    private func sendAll(_ fd: Int32, _ s: String) {
        let d = Array(s.utf8)
        var off = 0
        while off < d.count {
            let n = d[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            off += n
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return }
            buf.append(contentsOf: tmp[0 ..< n])
            headEnd = buf.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(decoding: buf[..<headEnd!.lowerBound], as: UTF8.self)
        var body = Data(buf[headEnd!.upperBound...])
        var want = 0
        var auth: String?
        for line in head.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") { want = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if lower.hasPrefix("authorization:") { auth = line.dropFirst(14).trimmingCharacters(in: .whitespaces) }
        }
        while body.count < want {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0 ..< n])
        }
        let path = head.components(separatedBy: " ").dropFirst().first ?? "/"
        let mode = path.split(separator: "/").first.map(String.init) ?? ""
        let parsed = (try? JSON.parse(body)) ?? .null
        lock.lock()
        seen.append((auth, parsed))
        lock.unlock()
        if mode == "err" {
            sendAll(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\nConnection: close\r\n\r\nboom")
            return
        }
        let content = parsed["messages"].array?.first?["content"].string ?? ""
        let answer = content.contains(Needle.needleText) ? Needle.code : "unknown"
        let reply = JSON.dumps(.obj([
            "choices": .array([.obj(["message": .obj(["role": "assistant", "content": .string(answer)])])]),
            "usage": .obj(["prompt_tokens": .int(content.utf8.count), "completion_tokens": .int(3)]),
        ]))
        sendAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n\(reply)")
    }
}

@Suite struct NeedleTests {
    static let seed = "alpha beta gamma delta epsilon zeta eta theta\n"

    static func run(_ ctx: Int, _ rep: Int, _ answer: String, error: String? = nil) -> Needle.Run {
        var r = Needle.Run(ctx: ctx, rep: rep)
        r.answer = answer
        r.error = error
        return r
    }

    @Test func promptHasExactLengthAndNeedleAtSeventyPercent() throws {
        let tok = ByteTokenizer()
        let needle = Array(Needle.needleText.utf8)
        let question = Array(Needle.questionText.utf8)
        let seedBytes = Array(Self.seed.utf8)
        for ctx in [300, 1000, 4096] {
            let prompt = try Needle.buildPrompt(seed: Self.seed, ctx: ctx, tokenizer: tok)
            #expect(tok.encode(prompt).count == ctx, "ctx \(ctx)")
            let room = ctx - needle.count - question.count
            var haystack: [UInt8] = []
            while haystack.count < room { haystack += seedBytes }
            haystack = Array(haystack.prefix(room))
            let pos = Int(Double(room) * 0.7)
            let expected = Array(haystack[..<pos]) + needle + Array(haystack[pos...]) + question
            #expect(Array(prompt.utf8) == expected, "ctx \(ctx)")
            let at = prompt.range(of: Needle.needleText)!.lowerBound
            #expect(prompt.utf8.distance(from: prompt.startIndex, to: at) == pos)
            #expect(prompt.components(separatedBy: Needle.needleText).count == 2)
            #expect(prompt.hasSuffix(Needle.questionText))
        }
    }

    @Test func tooSmallContextIsRejected() {
        #expect(throws: BenchError.self) { _ = try Needle.buildPrompt(seed: Self.seed, ctx: 50, tokenizer: ByteTokenizer()) }
        #expect(throws: BenchError.self) { _ = try Needle.buildPrompt(seed: "", ctx: 1000, tokenizer: ByteTokenizer()) }
    }

    @Test func answerMatchingIsCaseSensitiveSubstring() {
        #expect(Needle.passes("ZX-4417"))
        #expect(Needle.passes(" ZX-4417.\n"))
        #expect(!Needle.passes("zx-4417"))
        #expect(!Needle.passes("ZX-4418"))
        #expect(!Needle.passes(""))
        #expect(Self.run(300, 1, "ZX-4417").pass)
        #expect(!Self.run(300, 1, "ZX-4417", error: "HTTP Error 500").pass)
    }

    @Test func summaryAggregatesPerLength() {
        let runs = [Self.run(16384, 1, "ZX-4417"), Self.run(16384, 2, "unknown"), Self.run(65536, 1, "ZX-4417"),
                    Self.run(65536, 2, "", error: "HTTP Error 500")]
        let s = Needle.summarize(runs)
        #expect(s.runs == 4 && s.passes == 2 && !s.allPass)
        #expect(s.lengths == [.init(ctx: 16384, runs: 2, passes: 1), .init(ctx: 65536, runs: 2, passes: 1)])
        #expect(Needle.summarize([Self.run(16384, 1, "ZX-4417")]).allPass)
        #expect(!Needle.summarize([]).allPass)
    }

    @Test func markdownAndResultsJSONDescribeTheRun() throws {
        let cfg = Needle.Config(url: "http://127.0.0.1:1/x", model: "m", tokenizerPath: "/tok", seedPath: "/seed.txt", outDir: "/out")
        let runs = [Self.run(300, 1, "ZX-4417"), Self.run(300, 2, "a | b\nc")]
        let s = Needle.summarize(runs)
        let md = Needle.markdown(cfg, runs: runs, summary: s)
        #expect(md.contains("result: **1/2 PASS**"))
        #expect(md.contains("| 300 | 2 | 1/2 |"))
        #expect(md.contains("| 300 | 2 | FAIL |"))
        #expect(md.contains("a \\| b c"))
        let j = Needle.resultsJSON(cfg, runs: runs, summary: s)
        #expect(j["summary"]["passes"].int == 1)
        #expect(j["summary"]["all_pass"] == .bool(false))
        #expect(j["meta"]["token_file"].isNull)
        #expect(j["meta"]["endpoint"].string == "http://127.0.0.1:1/x/v1/chat/completions")
        #expect(j["runs"].array?.count == 2)
        #expect(JSON.dumps(j).contains("\"needle\": \"ZX-4417\""))
    }

    @Test func executeSendsTheRequestWithTokenAndScoresTheStubAnswers() async throws {
        let srv = NeedleStubServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir("needle")
        try Self.seed.write(toFile: tmp + "/seed.txt", atomically: false, encoding: .utf8)
        var cfg = Needle.Config(url: srv.url("ok"), model: "stub-model", tokenizerPath: tmp, seedPath: tmp + "/seed.txt", outDir: tmp + "/out")
        cfg.lengths = [300, 600]
        cfg.reps = 2
        let runs = try await Needle.execute(cfg, tokenizer: ByteTokenizer(), token: "secret-token", log: { _ in })
        #expect(runs.count == 4)
        #expect(runs.allSatisfy { $0.pass })
        #expect(runs.map(\.promptTokens) == [300, 300, 600, 600])
        #expect(runs.map(\.ctx) == [300, 300, 600, 600])
        let reqs = srv.requests
        #expect(reqs.count == 4)
        #expect(reqs.allSatisfy { $0.auth == "Bearer secret-token" })
        #expect(reqs.allSatisfy { $0.body["max_tokens"].int == 24 && $0.body["stream"] == .bool(false) && $0.body["temperature"].double == 0 })
        #expect(reqs.allSatisfy { $0.body["model"].string == "stub-model" })
    }

    @Test func failedRequestIsRecordedAndTheRunContinues() async throws {
        let srv = NeedleStubServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir("needle")
        try Self.seed.write(toFile: tmp + "/seed.txt", atomically: false, encoding: .utf8)
        var cfg = Needle.Config(url: srv.url("err"), model: "stub", tokenizerPath: tmp, seedPath: tmp + "/seed.txt", outDir: tmp + "/out")
        cfg.lengths = [300, 600]
        let runs = try await Needle.execute(cfg, tokenizer: ByteTokenizer(), token: nil, log: { _ in })
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { !$0.pass && $0.error?.contains("500") == true })
        #expect(srv.requests.allSatisfy { $0.auth == nil })
    }

    @Test func needleSubcommandWritesOutputsAndExitCodes() async throws {
        let srv = NeedleStubServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir("needle-cli")
        try Self.seed.write(toFile: tmp + "/seed.txt", atomically: false, encoding: .utf8)
        let factory: TokenizerFactory = { _ in ByteTokenizer() }
        let ok = try await BenchHTTPCLI.run(["needle", "--url", srv.url("ok"), "--model", "stub", "--tokenizer", tmp, "--seed", tmp + "/seed.txt",
                                             "--lengths", "300,600", "--out", tmp + "/out"], tokenizerFactory: factory)
        #expect(ok == 0)
        #expect(FileManager.default.fileExists(atPath: tmp + "/out/results.json"))
        let md = try String(contentsOfFile: tmp + "/out/summary.md", encoding: .utf8)
        #expect(md.contains("result: **2/2 PASS**"))
        let bad = try await BenchHTTPCLI.run(["needle", "--url", srv.url("err"), "--model", "stub", "--tokenizer", tmp, "--seed", tmp + "/seed.txt",
                                              "--lengths", "300", "--out", tmp + "/out-err"], tokenizerFactory: factory)
        #expect(bad == 1)
        let parsed = try JSON.parse(String(contentsOfFile: tmp + "/out-err/results.json", encoding: .utf8))
        #expect(parsed["summary"]["passes"].int == 0)
        #expect(parsed["runs"].array?.first?["error"].string?.contains("500") == true)
    }

    @Test func needleRejectsMissingOrBadOptions() async throws {
        await #expect(throws: BenchError.self) { try await BenchHTTPCLI.run(["needle", "--model", "m", "--tokenizer", "x"], tokenizerFactory: nil) }
        await #expect(throws: BenchError.self) { try await BenchHTTPCLI.run(["needle", "--url", "http://x", "--model", "m"], tokenizerFactory: nil) }
        await #expect(throws: BenchError.self) {
            try await BenchHTTPCLI.run(["needle", "--url", "http://x", "--model", "m", "--tokenizer", "x"], tokenizerFactory: nil)
        }
        await #expect(throws: BenchError.self) {
            try await BenchHTTPCLI.run(["needle", "--url", "http://x", "--model", "m", "--tokenizer", "x", "--lengths", "0"],
                                       tokenizerFactory: { _ in ByteTokenizer() })
        }
    }
}

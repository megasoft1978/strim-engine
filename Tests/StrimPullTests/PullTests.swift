import CryptoKit
import Foundation
import XCTest
@testable import StrimPull

/// In-process stand-in for huggingface.co: serves fixtures, honours Range, records requests. No network.
final class MockHF: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]          // url path -> body
    nonisolated(unsafe) static var requests: [(path: String, range: String?, auth: String?)] = []
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var failFirst = 0                        // 503 this many times
    nonisolated(unsafe) static var corrupt = false                      // flip a byte in served bodies
    static let lock = NSLock()

    static func reset() {
        lock.lock(); files = [:]; requests = []; ignoreRange = false; failFirst = 0; corrupt = false; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        let range = request.value(forHTTPHeaderField: "Range")
        Self.requests.append((url.path, range, request.value(forHTTPHeaderField: "Authorization")))
        var body = Self.files[url.path]
        let fail = Self.failFirst > 0
        if fail { Self.failFirst -= 1 }
        let ignore = Self.ignoreRange, corrupt = Self.corrupt
        Self.lock.unlock()
        func respond(_ code: Int, _ headers: [String: String], _ data: Data) {
            let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            var o = 0
            while o < data.count { let n = min(65536, data.count - o); client?.urlProtocol(self, didLoad: data.subdata(in: o..<o + n)); o += n }
            client?.urlProtocolDidFinishLoading(self)
        }
        if fail { respond(503, [:], Data()); return }
        guard var b = body else { respond(404, [:], Data()); return }
        if corrupt, !b.isEmpty { b[b.startIndex] ^= 0xFF; body = b }
        if let range, !ignore, range.hasPrefix("bytes=") {
            let p = range.dropFirst(6).split(separator: "-").map { Int64($0)! }
            let s = Int(p[0]), e = min(Int(p[1]), b.count - 1)
            respond(206, ["Content-Range": "bytes \(s)-\(e)/\(b.count)"], b.subdata(in: s..<e + 1))
        } else { respond(200, [:], b) }
    }
}

final class PullTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        MockHF.reset()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("strim-pull-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func gitSha1(_ d: Data) -> String {
        var h = Insecure.SHA1(); h.update(data: Data("blob \(d.count)\0".utf8)); h.update(data: d)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func blob(_ n: Int, seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

    let rev = "0123456789abcdef0123456789abcdef01234567"
    var big = PullTests.blob(1_000_003, seed: 7)
    let small = Data("{\"hello\":true}\n".utf8)

    func makeRepo() -> PullRepo {
        MockHF.files["/org/m/resolve/\(rev)/model.safetensors"] = big
        MockHF.files["/org/m/resolve/\(rev)/config.json"] = small
        return PullRepo(name: "m-test", repo: "org/m", revision: rev, files: [
            PullFile(path: "config.json", size: Int64(small.count), gitSha1: Self.gitSha1(small)),
            PullFile(path: "model.safetensors", size: Int64(big.count), sha256: Self.sha256(big)),
        ])
    }
    func options(free: Int64 = .max, token: String? = nil) -> PullOptions {
        var o = PullOptions(dir: tmp)
        o.endpoint = URL(string: "https://hf.test")!
        o.splitThreshold = 100_000
        o.reserveBytes = 1000
        o.backoffSeconds = 0
        o.token = token
        o.freeSpace = { _ in free }
        o.sessionConfiguration = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockHF.self]; return c }
        return o
    }

    func testURLIsPinnedToRevisionNotMain() {
        let r = makeRepo()
        let u = r.url(for: r.files[1], endpoint: URL(string: "https://huggingface.co")!)
        XCTAssertEqual(u.absoluteString, "https://huggingface.co/org/m/resolve/\(rev)/model.safetensors")
        XCTAssertFalse(u.absoluteString.contains("/main/"))
        for repo in PullManifest.repos {
            XCTAssertEqual(repo.revision.count, 40, repo.name)
            XCTAssertTrue(repo.url(for: repo.files[0], endpoint: PullManifest.defaultEndpoint).absoluteString.contains("/resolve/\(repo.revision)/"))
        }
    }

    func testManifestIsConsistent() {
        for t in PullManifest.tiers {
            let repos = PullManifest.repos(for: t)
            XCTAssertFalse(repos.isEmpty, t.name)
            XCTAssertNotNil(PullManifest.repo(named: t.model)); XCTAssertNotNil(PullManifest.repo(named: t.head))
        }
        for r in PullManifest.repos {
            let paths = r.files.map(\.path)
            for need in ["config.json", "tokenizer.json", "model.safetensors.index.json"] { XCTAssertTrue(paths.contains(need), "\(r.name) lacks \(need)") }
            XCTAssertTrue(paths.contains { $0.hasSuffix(".safetensors") })
            for f in r.files { XCTAssertTrue(f.sha256 != nil || f.gitSha1 != nil, "\(r.name)/\(f.path)") }
            for f in r.files where f.path.hasSuffix(".safetensors") { XCTAssertNotNil(f.sha256) }
        }
        XCTAssertEqual(PullManifest.tier("4bit")?.model, "qwen38-4bit")
        XCTAssertEqual(PullManifest.tier("4bit")?.head, "qwen38-mtp-4bit")
    }

    func testFreshDownloadParallelRangesVerifiedAndAtomic() async throws {
        let repo = makeRepo()
        let s = try await Puller(options(token: "tok-123")).pull([repo])
        let dest = tmp.appendingPathComponent("m-test")
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("model.safetensors")), big)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("config.json")), small)
        XCTAssertEqual(s.downloadedFiles, 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertFalse(left.contains { $0.contains(".part") }, "\(left)")
        XCTAssertTrue(left.contains(".strim-pull.json"))
        let ranged = MockHF.requests.filter { $0.path.hasSuffix("model.safetensors") }
        XCTAssertEqual(ranged.count, 4, "4 parallel connections for a big shard")
        XCTAssertTrue(MockHF.requests.allSatisfy { $0.auth == "Bearer tok-123" })
        XCTAssertEqual(s.downloadedBytes, Int64(big.count + small.count))
    }

    func testNoAuthHeaderWithoutToken() async throws {
        _ = try await Puller(options()).pull([makeRepo()])
        XCTAssertTrue(MockHF.requests.allSatisfy { $0.auth == nil })
    }

    func testResumeAfterTruncatedPart() async throws {
        let repo = makeRepo()
        let dir = tmp.appendingPathComponent("m-test"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cut = 600_000
        try big.prefix(cut).write(to: dir.appendingPathComponent("model.safetensors.part"))
        _ = try await Puller(options()).pull([repo])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.safetensors")), big)
        let starts = MockHF.requests.filter { $0.path.hasSuffix("model.safetensors") }.compactMap { $0.range }
            .map { Int($0.dropFirst(6).split(separator: "-")[0])! }
        XCTAssertFalse(starts.isEmpty)
        XCTAssertTrue(starts.allSatisfy { $0 >= cut }, "resumed requests must start at or after the kept prefix: \(starts)")
    }

    func testResumeFromSidecarState() async throws {
        let repo = makeRepo()
        let p = Puller(options())
        let dir = tmp.appendingPathComponent("m-test"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent("model.safetensors.part")
        var sparse = Data(count: big.count)
        sparse.replaceSubrange(0..<250_000, with: big.prefix(250_000))
        try sparse.write(to: part)
        let state = PullPartState(size: Int64(big.count), segments: [PullSegment(start: 0, end: 499_999, done: 250_000),
                                                                      PullSegment(start: 500_000, end: Int64(big.count) - 1, done: 0)])
        try JSONEncoder().encode(state).write(to: dir.appendingPathComponent("model.safetensors.part.state"))
        _ = try await p.pull([repo])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.safetensors")), big)
        let r = MockHF.requests.filter { $0.path.hasSuffix("model.safetensors") }.compactMap(\.range)
        XCTAssertTrue(r.contains("bytes=250000-499999"), "\(r)")
        XCTAssertFalse(r.contains { $0.hasPrefix("bytes=0-") })
    }

    func testHashMismatchRejectedAndNothingKept() async throws {
        let repo = makeRepo()
        MockHF.corrupt = true
        do { _ = try await Puller(options()).pull([repo]); XCTFail("should throw") }
        catch let e as PullError { XCTAssertEqual(e, .hashMismatch("config.json")) }
        let dir = tmp.appendingPathComponent("m-test")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(names.contains("config.json"), "\(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
        XCTAssertNil(try? Data(contentsOf: dir.appendingPathComponent(".strim-pull.json")))
    }

    func testHashMismatchOnLargeShard() async throws {
        var repo = makeRepo()
        repo = PullRepo(name: repo.name, repo: repo.repo, revision: repo.revision, files: [
            PullFile(path: "model.safetensors", size: Int64(big.count), sha256: String(repeating: "0", count: 64))])
        do { _ = try await Puller(options()).pull([repo]); XCTFail("should throw") }
        catch let e as PullError { XCTAssertEqual(e, .hashMismatch("model.safetensors")) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("m-test").path)) ?? []
        XCTAssertFalse(names.contains("model.safetensors")); XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
    }

    func testDiskGuardRefusesBeforeAnyRequest() async throws {
        let repo = makeRepo()
        let need = repo.totalBytes
        do { _ = try await Puller(options(free: need + 999)).pull([repo]); XCTFail("should throw") }   // reserve is 1000
        catch let e as PullError { XCTAssertEqual(e, .insufficientDisk(need: need, free: need + 999, reserve: 1000)) }
        XCTAssertTrue(MockHF.requests.isEmpty)
        _ = try await Puller(options(free: need + 1000)).pull([repo])   // exactly enough passes
    }

    func testDefaultReserveIsFiveGB() { XCTAssertEqual(PullOptions(dir: tmp).reserveBytes, 5_000_000_000) }

    func testSecondRunSkipsAndVerifyRedownloadsCorruptFile() async throws {
        let repo = makeRepo()
        _ = try await Puller(options()).pull([repo])
        MockHF.requests = []
        let s2 = try await Puller(options()).pull([repo])
        XCTAssertEqual(s2.skippedFiles, 2); XCTAssertTrue(MockHF.requests.isEmpty)
        // Same size, different content: only --verify notices.
        let f = tmp.appendingPathComponent("m-test/model.safetensors")
        var bad = big; bad[10] ^= 0x55; try bad.write(to: f)
        let s2b = try await Puller(options()).pull([repo])
        XCTAssertEqual(s2b.skippedFiles, 2)
        var v = options(); v.verify = true
        let s3 = try await Puller(v).pull([repo])
        XCTAssertEqual(s3.downloadedFiles, 1)
        XCTAssertEqual(try Data(contentsOf: f), big)
    }

    func testPreexistingDirWithoutReceiptIsHashedNotTrusted() async throws {
        let repo = makeRepo()
        let dir = tmp.appendingPathComponent("m-test"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bad = big; bad[5] ^= 1; try bad.write(to: dir.appendingPathComponent("model.safetensors"))   // right size, wrong bytes
        try small.write(to: dir.appendingPathComponent("config.json"))
        let s = try await Puller(options()).pull([repo])
        XCTAssertEqual(s.downloadedFiles, 1); XCTAssertEqual(s.skippedFiles, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.safetensors")), big)
    }

    func testServerIgnoringRangeFallsBackToSingleStream() async throws {
        MockHF.ignoreRange = true
        _ = try await Puller(options()).pull([makeRepo()])
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("m-test/model.safetensors")), big)
    }

    func testRetriesTransientServerError() async throws {
        MockHF.failFirst = 2
        _ = try await Puller(options()).pull([makeRepo()])
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("m-test/model.safetensors")), big)
    }

    func testHTTP404IsReportedNotRetriedForever() async throws {
        let repo = PullRepo(name: "m-test", repo: "org/missing", revision: rev, files: [PullFile(path: "config.json", size: 3, gitSha1: "x")])
        do { _ = try await Puller(options()).pull([repo]); XCTFail("should throw") }
        catch let e as PullError { XCTAssertEqual(e, .http(404, "config.json")) }
        XCTAssertEqual(MockHF.requests.count, 1)
    }

    func testRevisionLockRefusesDifferentRevision() async throws {
        let repo = makeRepo()
        _ = try await Puller(options()).pull([repo])
        let other = PullRepo(name: repo.name, repo: repo.repo, revision: String(repeating: "a", count: 40), files: repo.files)
        var o = options(); o.revisionLock = true
        do { _ = try await Puller(o).pull([other]); XCTFail("should throw") }
        catch let e as PullError { XCTAssertEqual(e, .lockConflict(repo: "org/m", locked: rev, pinned: other.revision)) }
    }
}

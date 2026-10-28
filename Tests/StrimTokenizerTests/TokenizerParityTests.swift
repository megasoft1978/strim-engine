import Foundation
import XCTest
@testable import StrimTokenizer

private struct Case: Decodable { let name: String; let text: String?; let ids: [Int32] }
private struct Fixture: Decodable {
    let vocab_size: Int
    let special: [String: Int32]
    let encode: [Case]
    let decode: [DecCase]
    let stream: [DecCase]
}
private struct DecCase: Decodable { let name: String; let ids: [Int32]; let text: String }

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func fnv(_ a: [Int32]) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for x in a { h = (h ^ UInt64(UInt32(bitPattern: x))) &* 0x100000001b3 }
    return String(h, radix: 16)
}

final class TokenizerParityTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("models/qwen38-4bit/tokenizer.json").path),
                          "needs models/qwen38-4bit (weights are not in the repository)")
    }

    static let tok: Tokenizer = {
        let dir = repoRoot.appendingPathComponent("models/qwen38-4bit").path
        return try! Tokenizer.load(modelDir: dir)
    }()
    fileprivate static let fx: Fixture = {
        let d = try! Data(contentsOf: repoRoot.appendingPathComponent("bench/fixtures/tokenizer_parity.json"))
        return try! JSONDecoder().decode(Fixture.self, from: d)
    }()

    func testEncodeParity() throws {
        var bad: [String] = []
        for c in Self.fx.encode {
            let got = Self.tok.encode(c.text ?? "")
            if got != c.ids {
                let i = zip(got, c.ids).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(got.count, c.ids.count)
                bad.append("\(c.name) firstDiff=\(i) exp=\(c.ids.count)/\(fnv(c.ids)) got=\(got.count)/\(fnv(got))")
            }
        }
        print("encode parity: \(Self.fx.encode.count - bad.count)/\(Self.fx.encode.count)")
        XCTAssertTrue(bad.isEmpty, "mismatches: \(bad.prefix(20))")
    }

    func testSpecialIds() {
        for (k, v) in Self.fx.special { XCTAssertEqual(Self.tok.specialIds[k], v, k) }
        XCTAssertEqual(Self.tok.specialIds["<|im_end|>"], 248046)
        XCTAssertEqual(Self.tok.encode("<|im_end|>"), [248046])
        // allowSpecial == false tokenises the literal text instead.
        XCTAssertNotEqual(Self.tok.encode("<|im_end|>", allowSpecial: false), [248046])
        XCTAssertFalse(Self.tok.encode("<|im_end|>", allowSpecial: false).contains(248046))
    }

    func testDecodeParity() {
        var bad: [String] = []
        for c in Self.fx.decode where Self.tok.decode(c.ids) != c.text { bad.append(c.name) }
        print("decode parity: \(Self.fx.decode.count - bad.count)/\(Self.fx.decode.count)")
        XCTAssertTrue(bad.isEmpty, "mismatches: \(bad.prefix(20))")
    }

    func testRoundTrip() {
        // decode(encode(x)) == NFC(x) (ASCII: identical); mixed normalisation + specials skipped.
        var n = 0
        for c in Self.fx.encode {
            let t = c.text ?? ""
            let rt = Self.tok.decode(Self.tok.encode(t))
            if t.utf8.allSatisfy({ $0 < 0x80 }) { XCTAssertEqual(rt, t, c.name); n += 1 }
            else if !t.contains("<") { XCTAssertEqual(rt, t.precomposedStringWithCanonicalMapping, c.name); n += 1 }
        }
        print("round trips: \(n)")
    }

    func testStreamingAllChunkings() {
        var checks = 0
        for c in Self.fx.stream {
            let hasFFFD = c.text.unicodeScalars.contains("\u{FFFD}")
            // Chunk sizes 1..., plus every two-way split point.
            var plans: [[Int]] = [1, 2, 3, 5, 8, c.ids.count].map { sz in
                stride(from: 0, to: c.ids.count, by: max(sz, 1)).map { $0 }
            }
            if c.ids.count <= 80 { plans.append(contentsOf: (0...c.ids.count).map { [0, $0] }) }
            for starts in plans {
                var d = Self.tok.makeStreamDecoder()
                var out = ""
                let bounds = starts + [c.ids.count]
                for j in 0..<starts.count {
                    let piece = d.push(Array(c.ids[bounds[j]..<bounds[j + 1]]))
                    if !hasFFFD { XCTAssertFalse(piece.unicodeScalars.contains("\u{FFFD}"), "\(c.name) partial char emitted") }
                    out += piece
                }
                out += d.flush()
                XCTAssertEqual(out, c.text, c.name)
                checks += 1
            }
            // Token-at-a-time.
            var d = Self.tok.makeStreamDecoder()
            var out = ""
            for id in c.ids {
                let piece = d.push(id)
                if !hasFFFD { XCTAssertFalse(piece.unicodeScalars.contains("\u{FFFD}"), "\(c.name) partial char emitted") }
                out += piece
            }
            out += d.flush()
            XCTAssertEqual(out, c.text, c.name)
            checks += 1
        }
        print("stream chunkings checked: \(checks)")
    }

    func testStreamHoldsPartialUTF8() {
        let ids = Self.tok.encode("\u{1F468}\u{200D}\u{1F4BB}")
        var d = Self.tok.makeStreamDecoder()
        var out = ""
        for id in ids.dropLast() { out += d.push(id); XCTAssertFalse(out.contains("\u{FFFD}")) }
        out += d.push(ids.last!)
        XCTAssertEqual(out + d.flush(), "\u{1F468}\u{200D}\u{1F4BB}")
        // Truncated stream: flush emits replacement, never earlier.
        var d2 = Self.tok.makeStreamDecoder()
        let e = Self.tok.encode("\u{1F600}")
        var got = ""
        for id in e.dropLast() { got += d2.push(id) }
        XCTAssertTrue(got.isEmpty || !got.contains("\u{FFFD}"))
        XCTAssertEqual(got + d2.flush(), Self.tok.decode(Array(e.dropLast())))
    }

    func testSpeed() {
        let words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "latency", "throughput",
                     "cache", "prefix", "func", "let", "return", "12345", "{", "}", "(", ")", ",", "\n", "    "]
        var s = ""; var seed: UInt64 = 42
        while s.utf8.count < 450_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            s += words[Int(seed >> 33) % words.count] + (seed & 8 == 0 ? " " : "")
        }
        let t0 = Date()
        let ids = Self.tok.encode(s)
        let dt1 = Date().timeIntervalSince(t0)
        let t1 = Date()
        let ids2 = Self.tok.encode(s)
        let dt2 = Date().timeIntervalSince(t1)
        XCTAssertEqual(ids, ids2)
        let t2 = Date()
        _ = Self.tok.decode(ids)
        print("speed: \(ids.count) tokens, encode cold \(Int(dt1 * 1000)) ms, warm \(Int(dt2 * 1000)) ms, decode \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
    }

    func testLoadTime() throws {
        let t = Date()
        _ = try Tokenizer.load(modelDir: repoRoot.appendingPathComponent("models/qwen38-4bit").path)
        print("load: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
    }
}

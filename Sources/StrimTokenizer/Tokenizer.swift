import Foundation

public enum TokenizerError: Error, CustomStringConvertible {
    case missingFile(String)
    case badFormat(String)
    public var description: String {
        switch self {
        case .missingFile(let s): return "tokenizer: missing file \(s)"
        case .badFormat(let s): return "tokenizer: bad format: \(s)"
        }
    }
}

/// Byte-level BPE tokenizer driven by a HF `tokenizer.json` (Qwen family layout).
/// Exact id parity with HF `tokenizers`: added tokens are matched first on the raw text,
/// remaining segments are NFC-normalised (if configured), split by the Split regex, and BPE'd.
public final class Tokenizer: @unchecked Sendable {
    // Vocabulary in raw-byte form.
    private let tokenBytes: [[UInt8]]          // id -> bytes (added tokens: utf8 of content)
    private let byteIds: [Int32]               // 256 entries: single byte -> id
    // (leftId << 32 | rightId) -> (rank << 32 | mergedId)
    private let merges: [UInt64: UInt64]
    private let regex: NSRegularExpression
    private let nfc: Bool
    /// Added tokens as (bytes, id, isSpecial); sorted longest first.
    private let added: [(bytes: [UInt8], id: Int32, special: Bool)]
    private let addedByFirstByte: [[Int]]      // first byte -> indices into `added`
    public let specialIds: [String: Int32]
    public let vocabSize: Int

    private var cache: [[UInt8]: [Int32]] = [:]
    private let lock = NSLock()
    private static let cacheLimit = 400_000

    public static func load(modelDir: String) throws -> Tokenizer {
        let path = (modelDir as NSString).appendingPathComponent("tokenizer.json")
        guard let data = FileManager.default.contents(atPath: path) else { throw TokenizerError.missingFile(path) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenizerError.badFormat("root")
        }
        return try Tokenizer(json: root)
    }

    init(json root: [String: Any]) throws {
        guard let model = root["model"] as? [String: Any], (model["type"] as? String) == "BPE",
              let vocab = model["vocab"] as? [String: Int],
              let mergesRaw = model["merges"] as? [Any] else { throw TokenizerError.badFormat("model") }

        // GPT-2 bytes_to_unicode inverse: scalar -> byte.
        var printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var inverse = [UInt32: UInt8]()
        for b in printable { inverse[UInt32(b)] = UInt8(b) }
        var n = 0
        for b in 0..<256 where !printable.contains(b) {
            inverse[UInt32(256 + n)] = UInt8(b); n += 1
        }
        printable.removeAll()
        func raw(_ s: String) -> [UInt8]? {
            var out = [UInt8](); out.reserveCapacity(s.utf8.count)
            for u in s.unicodeScalars {
                guard let b = inverse[u.value] else { return nil }
                out.append(b)
            }
            return out
        }

        var addedList: [(bytes: [UInt8], id: Int32, special: Bool)] = []
        var specials: [String: Int32] = [:]
        var maxId = vocab.values.max() ?? -1
        for a in (root["added_tokens"] as? [[String: Any]]) ?? [] {
            guard let id = a["id"] as? Int, let content = a["content"] as? String else { throw TokenizerError.badFormat("added") }
            let sp = (a["special"] as? Bool) ?? false
            addedList.append((Array(content.utf8), Int32(id), sp))
            specials[content] = Int32(id)
            maxId = max(maxId, id)
        }
        var table = [[UInt8]](repeating: [], count: maxId + 1)
        var rawToId = [[UInt8]: Int32](minimumCapacity: vocab.count)
        for (s, id) in vocab {
            guard let b = raw(s) else { throw TokenizerError.badFormat("vocab char") }
            table[id] = b
            rawToId[b] = Int32(id)
        }
        for a in addedList { table[Int(a.id)] = a.bytes }
        var bi = [Int32](repeating: -1, count: 256)
        for b in 0..<256 {
            guard let id = rawToId[[UInt8(b)]] else { throw TokenizerError.badFormat("byte \(b) missing") }
            bi[b] = id
        }
        var mm = [UInt64: UInt64](minimumCapacity: mergesRaw.count)
        for (rank, m) in mergesRaw.enumerated() {
            var l: String, r: String
            if let pair = m as? [String], pair.count == 2 { l = pair[0]; r = pair[1] }
            else if let s = m as? String, let sp = s.firstIndex(of: " ") {
                l = String(s[s.startIndex..<sp]); r = String(s[s.index(after: sp)...])
            } else { throw TokenizerError.badFormat("merge \(rank)") }
            guard let lb = raw(l), let rb = raw(r), let lid = rawToId[lb], let rid = rawToId[rb],
                  let mid = rawToId[lb + rb] else { throw TokenizerError.badFormat("merge \(rank) unresolved") }
            let key = UInt64(UInt32(lid)) << 32 | UInt64(UInt32(rid))
            if mm[key] == nil { mm[key] = UInt64(rank) << 32 | UInt64(UInt32(mid)) }
        }

        // Normalizer: NFC (directly or inside a Sequence).
        func hasNFC(_ n: Any?) -> Bool {
            guard let d = n as? [String: Any] else { return false }
            if (d["type"] as? String) == "NFC" { return true }
            return ((d["normalizers"] as? [Any]) ?? []).contains { hasNFC($0) }
        }
        // Pre-tokenizer: find Split regex.
        func findRegex(_ p: Any?) -> String? {
            guard let d = p as? [String: Any] else { return nil }
            if (d["type"] as? String) == "Split", let pat = d["pattern"] as? [String: Any], let r = pat["Regex"] as? String { return r }
            for c in (d["pretokenizers"] as? [Any]) ?? [] { if let r = findRegex(c) { return r } }
            return nil
        }
        guard let pattern = findRegex(root["pre_tokenizer"]) else { throw TokenizerError.badFormat("pre_tokenizer regex") }
        self.regex = try NSRegularExpression(pattern: pattern, options: [])
        self.nfc = hasNFC(root["normalizer"])
        self.tokenBytes = table
        self.byteIds = bi
        self.merges = mm
        self.specialIds = specials
        self.vocabSize = table.count
        let sorted = addedList.sorted { $0.bytes.count > $1.bytes.count }
        self.added = sorted
        var byFirst = [[Int]](repeating: [], count: 256)
        for (i, a) in sorted.enumerated() { if let f = a.bytes.first { byFirst[Int(f)].append(i) } }
        self.addedByFirstByte = byFirst
    }

    // MARK: encode

    /// `allowSpecial == false` disables all added-token matching (their text is tokenised as plain text).
    public func encode(_ text: String, allowSpecial: Bool = true) -> [Int32] {
        var out = [Int32](); out.reserveCapacity(text.utf8.count / 3 + 4)
        if !allowSpecial || added.isEmpty {
            encodePlain(text, into: &out)
            return out
        }
        let u8 = Array(text.utf8)
        var segStart = 0, i = 0
        let n = u8.count
        while i < n {
            let cands = addedByFirstByte[Int(u8[i])]
            var hit = -1
            for ci in cands {
                let a = added[ci]
                if i + a.bytes.count <= n && u8[i..<(i + a.bytes.count)].elementsEqual(a.bytes) { hit = ci; break }
            }
            if hit >= 0 {
                if segStart < i { encodePlain(String(decoding: u8[segStart..<i], as: UTF8.self), into: &out) }
                out.append(added[hit].id)
                i += added[hit].bytes.count
                segStart = i
            } else { i += 1 }
        }
        if segStart < n { encodePlain(String(decoding: u8[segStart..<n], as: UTF8.self), into: &out) }
        return out
    }

    private func encodePlain(_ segment: String, into out: inout [Int32]) {
        if segment.isEmpty { return }
        var s = segment
        var u8 = Array(s.utf8)
        let ascii = !u8.contains { $0 >= 0x80 }
        if nfc && !ascii {
            s = s.precomposedStringWithCanonicalMapping
            u8 = Array(s.utf8)
        }
        let ns = ascii ? NSString(string: s) : (s as NSString)
        let full = NSRange(location: 0, length: ns.length)
        var last = 0
        var pieces: [(Int, Int)] = []   // utf16 ranges
        pieces.reserveCapacity(u8.count / 3 + 1)
        regex.enumerateMatches(in: s, options: [], range: full) { m, _, _ in
            guard let r = m?.range else { return }
            if r.location > last { pieces.append((last, r.location - last)) }
            if r.length > 0 { pieces.append((r.location, r.length)) }
            last = r.location + r.length
        }
        if last < ns.length { pieces.append((last, ns.length - last)) }
        for (loc, len) in pieces {
            if ascii {
                bpeCached(u8[loc..<(loc + len)], into: &out)
            } else {
                let sub = ns.substring(with: NSRange(location: loc, length: len))
                bpeCached(Array(sub.utf8)[...], into: &out)
            }
        }
    }

    private func bpeCached(_ piece: ArraySlice<UInt8>, into out: inout [Int32]) {
        let key = Array(piece)
        if key.count <= 128 {
            lock.lock(); let hit = cache[key]; lock.unlock()
            if let hit { out.append(contentsOf: hit); return }
        }
        let ids = bpe(key)
        if key.count <= 128 {
            lock.lock()
            if cache.count < Self.cacheLimit { cache[key] = ids }
            lock.unlock()
        }
        out.append(contentsOf: ids)
    }

    /// Standard BPE: repeatedly merge the lowest-rank adjacent pair (leftmost on ties).
    private func bpe(_ bytes: [UInt8]) -> [Int32] {
        let n = bytes.count
        var ids = bytes.map { byteIds[Int($0)] }
        if n < 2 { return ids }
        var next = [Int32](repeating: 0, count: n), prev = [Int32](repeating: 0, count: n)
        for i in 0..<n { next[i] = Int32(i + 1 < n ? i + 1 : -1); prev[i] = Int32(i - 1) }
        var heap = [UInt64](); heap.reserveCapacity(n)
        @inline(__always) func lookup(_ a: Int32, _ b: Int32) -> UInt64? {
            merges[UInt64(UInt32(a)) << 32 | UInt64(UInt32(b))]
        }
        @inline(__always) func push(_ k: UInt64) {
            heap.append(k)
            var c = heap.count - 1
            while c > 0 {
                let p = (c - 1) >> 1
                if heap[p] <= heap[c] { break }
                heap.swapAt(p, c); c = p
            }
        }
        @inline(__always) func pop() -> UInt64 {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var p = 0
                let cnt = heap.count
                while true {
                    var m = p
                    let l = 2 * p + 1, r = l + 1
                    if l < cnt && heap[l] < heap[m] { m = l }
                    if r < cnt && heap[r] < heap[m] { m = r }
                    if m == p { break }
                    heap.swapAt(p, m); p = m
                }
            }
            return top
        }
        for i in 0..<(n - 1) {
            if let v = lookup(ids[i], ids[i + 1]) { push((v >> 32) << 32 | UInt64(i)) }
        }
        var alive = [Bool](repeating: true, count: n)
        while !heap.isEmpty {
            let k = pop()
            let rank = k >> 32, pos = Int(k & 0xFFFF_FFFF)
            guard alive[pos] else { continue }
            let nx = Int(next[pos])
            guard nx >= 0, let v = lookup(ids[pos], ids[nx]), v >> 32 == rank else { continue }
            ids[pos] = Int32(truncatingIfNeeded: v & 0xFFFF_FFFF)
            alive[nx] = false
            let nn = next[nx]
            next[pos] = nn
            if nn >= 0 { prev[Int(nn)] = Int32(pos) }
            if nn >= 0, let v2 = lookup(ids[pos], ids[Int(nn)]) { push((v2 >> 32) << 32 | UInt64(pos)) }
            let pv = Int(prev[pos])
            if pv >= 0, let v3 = lookup(ids[pv], ids[pos]) { push((v3 >> 32) << 32 | UInt64(pv)) }
        }
        var res = [Int32](); res.reserveCapacity(n)
        var i = 0
        while i >= 0 && i < n { res.append(ids[i]); i = Int(next[i]) }
        return res
    }

    // MARK: decode

    /// Raw bytes of a token id (empty for unknown ids).
    public func bytes(for id: Int32) -> [UInt8] {
        id >= 0 && Int(id) < tokenBytes.count ? tokenBytes[Int(id)] : []
    }

    /// Lossy decode: invalid UTF-8 (e.g. truncated multibyte) becomes U+FFFD, as HF does. Unknown ids are skipped.
    public func decode(_ ids: [Int32]) -> String {
        var buf = [UInt8]()
        for id in ids { buf.append(contentsOf: bytes(for: id)) }
        return String(decoding: buf, as: UTF8.self)
    }

    public func makeStreamDecoder() -> StreamDecoder { StreamDecoder(self) }
}

/// Incremental detokenizer: `push` returns only text made of complete UTF-8 characters;
/// a trailing partial multibyte sequence is held back until completed or `flush`ed.
public struct StreamDecoder {
    private let tok: Tokenizer
    private var pending: [UInt8] = []

    public init(_ tok: Tokenizer) { self.tok = tok }

    public mutating func push(_ id: Int32) -> String {
        pending.append(contentsOf: tok.bytes(for: id))
        return drain()
    }

    public mutating func push(_ ids: [Int32]) -> String {
        for id in ids { pending.append(contentsOf: tok.bytes(for: id)) }
        return drain()
    }

    /// Emit anything still held (a truncated sequence becomes U+FFFD) and reset.
    public mutating func flush() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    private mutating func drain() -> String {
        let n = pending.count
        var cut = n
        // A held tail is a valid-so-far prefix of a longer sequence.
        var k = 1
        while k <= min(3, n) {
            let b = pending[n - k]
            if b & 0xC0 == 0x80 { k += 1; continue }          // continuation, keep looking back
            let need = b >= 0xF0 && b <= 0xF4 ? 4 : b >= 0xE0 ? (b <= 0xEF ? 3 : 0) : b >= 0xC2 && b <= 0xDF ? 2 : 0
            if need > k && Self.validPrefix(pending[(n - k)...]) { cut = n - k }
            break
        }
        if cut == 0 { return "" }
        let s = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return s
    }

    private static func validPrefix(_ t: ArraySlice<UInt8>) -> Bool {
        let b0 = t[t.startIndex]
        var it = t.dropFirst()
        if let b1 = it.first {
            switch b0 {
            case 0xE0: if !(0xA0...0xBF).contains(b1) { return false }
            case 0xED: if !(0x80...0x9F).contains(b1) { return false }
            case 0xF0: if !(0x90...0xBF).contains(b1) { return false }
            case 0xF4: if !(0x80...0x8F).contains(b1) { return false }
            default: if b1 & 0xC0 != 0x80 { return false }
            }
            it = it.dropFirst()
        }
        return it.allSatisfy { $0 & 0xC0 == 0x80 }
    }
}

import CryptoKit
import Foundation

enum PullHash {
    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    /// Streams the file in 4 MiB chunks. For `.sha256` the plain digest; for `.gitBlob` sha1("blob <size>\0" + data).
    static func digest(of url: URL, kind: Kind) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        switch kind {
        case .sha256:
            var hasher = SHA256()
            while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
            return hex(hasher.finalize())
        case .gitBlob:
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\0".utf8))
            while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
            return hex(hasher.finalize())
        }
    }

    enum Kind { case sha256, gitBlob }

    static func matches(_ file: PullFile, at url: URL) throws -> Bool {
        if let s = file.sha256 { return try digest(of: url, kind: .sha256) == s }
        if let g = file.gitSha1 { return try digest(of: url, kind: .gitBlob) == g }
        return true
    }
}

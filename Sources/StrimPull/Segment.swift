import Foundation

struct PullSegment: Codable, Equatable {
    var start: Int64
    var end: Int64        // inclusive
    var done: Int64       // bytes already written for this segment
    var length: Int64 { end - start + 1 }
    var remaining: Int64 { length - done }
}

struct PullPartState: Codable, Equatable {
    var size: Int64
    var segments: [PullSegment]
    var doneBytes: Int64 { segments.reduce(0) { $0 + $1.done } }

    static func split(from offset: Int64, to total: Int64, parts: Int) -> [PullSegment] {
        let remaining = total - offset
        guard remaining > 0 else { return [] }
        let n = Int64(max(1, min(parts, Int(remaining))))
        let chunk = remaining / n
        return (0..<n).map { i in
            let s = offset + i * chunk
            let e = i == n - 1 ? total - 1 : s + chunk - 1
            return PullSegment(start: s, end: e, done: 0)
        }
    }
}

public enum PullError: Error, CustomStringConvertible, Equatable {
    case insufficientDisk(need: Int64, free: Int64, reserve: Int64)
    case hashMismatch(String)
    case sizeMismatch(String, expected: Int64, got: Int64)
    case http(Int, String)
    case rangeIgnored(String)
    case lockConflict(repo: String, locked: String, pinned: String)
    case network(String)

    public var description: String {
        switch self {
        case let .insufficientDisk(need, free, reserve):
            return "not enough free disk: need \(PullFormat.gb(need)) + \(PullFormat.gb(reserve)) headroom, have \(PullFormat.gb(free))"
        case let .hashMismatch(p): return "checksum mismatch for \(p); the partial download was discarded"
        case let .sizeMismatch(p, e, g): return "size mismatch for \(p): expected \(e) bytes, got \(g)"
        case let .http(c, p): return "HTTP \(c) for \(p)\(c == 401 || c == 403 ? " (set HF_TOKEN if the repo needs a login)" : "")"
        case let .rangeIgnored(p): return "server ignored the Range request for \(p)"
        case let .lockConflict(r, l, p): return "\(r) is locked to revision \(l) but this strim pins \(p); remove .strim-pull.json to update"
        case let .network(m): return "network error: \(m)"
        }
    }
}

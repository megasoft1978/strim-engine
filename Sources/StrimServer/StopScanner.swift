import Foundation

/// Cuts streamed text at the first stop string; holds back a tail that could still start one.
struct StopScanner {
    private let stops: [String]
    private let hold: Int
    private var buf = ""
    /// The stop string that matched (nil until a hit).
    private(set) var matched: String?

    init(_ stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }
        hold = (self.stops.map { $0.count }.max() ?? 1) - 1
    }

    var isEmpty: Bool { stops.isEmpty }

    /// Returns text safe to emit and whether a stop string was hit (nothing is emitted after it).
    mutating func feed(_ text: String) -> (String, Bool) {
        guard !stops.isEmpty else { return (text, false) }
        buf += text
        var best: String.Index?
        var bestStop: String?
        for s in stops {
            if let r = buf.range(of: s), best == nil || r.lowerBound < best! { best = r.lowerBound; bestStop = s }
        }
        if let best {
            matched = bestStop
            let out = String(buf[..<best])
            buf = ""
            return (out, true)
        }
        let keep = min(hold, buf.count)
        let cut = buf.index(buf.endIndex, offsetBy: -keep)
        let out = String(buf[..<cut])
        buf = String(buf[cut...])
        return (out, false)
    }

    mutating func flush() -> String {
        defer { buf = "" }
        return buf
    }
}

import Foundation
import StrimAPI

/// Pure formatting for the stats UI.
public enum StatsFormat {
    public static func tps(_ v: Double) -> String { v <= 0 ? "–" : String(format: "%.1f tok/s", v) }
    public static func percent(_ v: Double) -> String { String(format: "%.0f%%", max(0, min(1, v)) * 100) }
    public static func gb(_ v: Double) -> String { String(format: "%.1f GB", v) }
    public static func seconds(_ v: Double) -> String { v < 60 ? String(format: "%.1f s", v) : duration(v) }
    public static func depth(_ v: Double) -> String { String(format: "%.2f", v) }

    public static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: "\(n)"
        case ..<1_000_000: String(format: "%.1fk", Double(n) / 1000)
        default: String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
    public static func duration(_ s: Double) -> String {
        let t = Int(max(0, s))
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m \(t % 60)s" }
        return "\(t)s"
    }

    /// Menu bar title text: `stopped | loading 42% | ready | busy | offline` (+ `error`, `connecting`).
    public static func menuTitle(_ c: ConnectionState) -> String {
        switch c {
        case .disconnected: return "Strim: offline"
        case .connecting: return "Strim: connecting"
        case .connected(let s):
            switch s.state {
            case .loading: return "Strim: loading " + percent(s.loadProgress ?? 0)
            default: return "Strim: " + s.state.rawValue
            }
        }
    }
    public static func menuSymbol(_ c: ConnectionState) -> String {
        switch c {
        case .disconnected: return "bolt.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected(let s):
            switch s.state {
            case .stopped: return "stop.circle"
            case .loading: return "hourglass"
            case .ready: return "bolt.circle.fill"
            case .busy: return "bolt.horizontal.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    public struct MemorySegment: Equatable, Sendable { public var label: String; public var gb: Double; public var fraction: Double }
    /// Segments with fractions of their total (for the stacked bar).
    public static func memorySegments(_ m: MemoryStats) -> [MemorySegment] {
        let parts: [(String, Double)] = [("Weights", m.weightsGB), ("Prefix trie", m.prefixTrieGB),
                                         ("MLX cache", m.mlxCacheGB), ("Headroom", m.headroomGB)]
        let total = parts.reduce(0) { $0 + max(0, $1.1) }
        return parts.map { MemorySegment(label: $0.0, gb: $0.1, fraction: total > 0 ? max(0, $0.1) / total : 0) }
    }

    public static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let s = Int(now.timeIntervalSince(date))
        return s < 2 ? "just now" : s < 60 ? "\(s)s ago" : s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago"
    }
}

/// Offline banner copy: always names the exact reason.
public enum OfflineBanner {
    public static func text(for error: Error, hostURL: String) -> String {
        if let e = error as? ControlClientError {
            switch e {
            case .hostUnreachable(let d): return "Strim host is not running at \(hostURL): \(d)."
            case .timeout: return "Strim host at \(hostURL) did not respond (timeout)."
            case .unauthorized(let present):
                return present ? "Host at \(hostURL) rejected the control token in ~/.strim/control-token (401). Restart the host to regenerate it."
                               : "Host at \(hostURL) requires a control token but ~/.strim/control-token is missing or unusable (401). Start the host once so it creates ~/.strim/control-token."
            case .forbidden: return "Host at \(hostURL) refused this client (403, loopback only)."
            case .invalidConfig(let d): return "\(d). Fix it in Settings or ~/.strim/app.json."
            default: return "Host at \(hostURL): \(e.localizedDescription)."
            }
        }
        return "Lost connection to \(hostURL): \(error.localizedDescription)."
    }
    public static let streamEnded = "Event stream closed by host."
}

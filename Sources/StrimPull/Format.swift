import Foundation

public enum PullFormat {
    public static func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }
    public static func duration(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--" }
        let t = Int(s)
        return t >= 3600 ? "\(t / 3600)h\(t % 3600 / 60)m" : t >= 60 ? "\(t / 60)m\(t % 60)s" : "\(t)s"
    }
}

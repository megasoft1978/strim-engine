/// Admission settings from the `strim serve` command line. Pure (no I/O): the CLI feeds it argv, then builds the gate
/// from `limits(defaultInflight:)`, so flag parsing and defaults are unit-tested here.
public struct AdmissionOptions: Sendable, Equatable {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case badValue(flag: String, value: String)
        public var description: String {
            switch self {
            case let .unknown(a): return "unknown admission option \(a)"
            case let .badValue(f, v): return "bad \(f) value '\(v)' (want an integer >= 1)"
            }
        }
    }

    public static let valuedFlags = ["--max-inflight", "--max-background"]

    /// Enabled unless `--no-admission`.
    public var enabled = true
    public var maxInflight: Int?
    public var maxBackground: Int?

    public init() {}

    /// True when `arg` is one of the admission flags (exact name, or `--flag=value` for the valued ones).
    public static func owns(_ arg: String) -> Bool {
        arg == "--no-admission" || valuedFlags.contains { arg == $0 || arg.hasPrefix($0 + "=") }
    }

    /// Consumes one admission flag. `value` supplies the next argv element for the space-separated form and is only
    /// called for a valued flag without `=`.
    public mutating func parse(_ arg: String, value: () -> String) throws {
        if arg == "--no-admission" { enabled = false; return }
        guard let flag = Self.valuedFlags.first(where: { arg == $0 || arg.hasPrefix($0 + "=") }) else {
            throw ParseError.unknown(arg)
        }
        let raw = arg == flag ? value() : String(arg.dropFirst(flag.count + 1))
        guard let n = Int(raw), n >= 1 else { throw ParseError.badValue(flag: flag, value: raw) }
        if flag == "--max-inflight" { maxInflight = n } else { maxBackground = n }
    }

    /// Effective limits, or nil when disabled. Without `--max-inflight`, `defaultInflight` (the server's concurrency).
    /// Without `--max-background`, inflight - 1 (min 1). `AdmissionLimits` clamps background to inflight - 1 either way.
    public func limits(defaultInflight: Int) -> AdmissionLimits? {
        guard enabled else { return nil }
        let inflight = max(1, maxInflight ?? defaultInflight)
        return AdmissionLimits(maxInflight: inflight, maxBackground: maxBackground ?? max(1, inflight - 1))
    }
}

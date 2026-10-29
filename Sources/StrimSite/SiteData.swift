import Foundation

/// One figure: the raw JSON object (kept for re-serialisation) and its resolved value.
public struct Figure {
    public var raw: JObject
    public var value: PyJSON   // Python `_value`

    public var id: String { raw["id"]?.str ?? "" }
    public var unitJSON: PyJSON { raw["unit"] ?? .null }
    /// `f["unit"] or ""`
    public var unit: String { let u = unitJSON; return u.truthy ? u.pyStr : "" }
    public var dp: Int? { if case .int(let d)? = raw["dp"] { return d }; return nil }
    public var isDerived: Bool { raw["derived_from"]?.truthy ?? false }
    public var best: Bool { raw["best"]?.truthy ?? false }
    public var sourcePath: String { raw["source_path"]?.pyStr ?? "" }
}

public struct SiteData {
    public var raw: PyJSON
    public var meta: PyJSON
    public var figs: [String: Figure] = [:]
    public var order: [String] = []

    public init(raw: PyJSON) throws {
        self.raw = raw
        meta = try raw.get("meta")
        _ = try raw.get("datasets")
        for case .object(let fo) in try raw.get("figures").arr ?? [] {
            guard let id = fo["id"]?.str else { throw SiteError("KeyError: id") }
            if figs[id] != nil { throw SiteError("duplicate figure id \(id)") }
            figs[id] = Figure(raw: fo, value: .null)
            order.append(id)
        }
        for id in order {
            var f = figs[id]!
            if f.isDerived {
                f.value = try derive(f)
            } else {
                guard let v = f.raw["value"] else { throw SiteError("KeyError: value (\(id))") }
                f.value = v
            }
            figs[id] = f
        }
    }

    private func derive(_ f: Figure) throws -> PyJSON {
        var vals: [Double] = []
        for case .string(let i) in f.raw["derived_from"]?.arr ?? [] {
            guard let g = figs[i] else { throw SiteError("\(f.id): derived_from unknown id \(i)") }
            guard let rv = g.raw["value"] else { throw SiteError("KeyError: value (\(i))") }
            if rv.isNull { return .null }
            guard let d = rv.number else { throw SiteError("\(f.id): non-numeric derived_from value") }
            vals.append(d)
        }
        if f.raw["op"]?.str == "ratio" {
            guard vals.count >= 2 else { throw SiteError("\(f.id): ratio needs two inputs") }
            if vals[1] == 0 { throw SiteError("ZeroDivisionError: \(f.id)") }
            return .double(pyRound(vals[0] / vals[1], 2))
        }
        throw SiteError("\(f.id): unknown op \(f.raw["op"]?.pyStr ?? "None")")
    }

    /// A cell where the engine produced no valid value (n/a in the summary): shown as "n/a", not as a pending measurement.
    public func isNA(_ i: String) -> Bool { figs[i].map { $0.value.isNull && ($0.raw["na"]?.truthy ?? false) } ?? false }

    public func pending(_ i: String) -> Bool { figs[i]?.value.isNull ?? true }

    /// Value as displayed (no unit).
    public func text(_ i: String) -> String {
        guard let f = figs[i] else { return "pending" }
        switch f.value {
        case .null: return f.raw["na"]?.truthy ?? false ? "n/a" : "pending"
        case .string(let s): return s
        case .int(let n): return fmtCommas(n)
        case .bool(let b): return b ? "1" : "0"
        case .double(let d):
            if f.isDerived { return fmtFixed(d, 2) }
            if let dp = f.dp { return fmtFixed(d, dp) }
            return pyRepr(d)
        default: return f.value.pyStr
        }
    }
}

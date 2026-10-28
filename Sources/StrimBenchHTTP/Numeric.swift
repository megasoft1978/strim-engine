import Foundation

/// Statistics matching Python's `statistics` module. Mean and variance use double-double
/// accumulation so results agree with Python's exact-arithmetic implementation to the last bit
/// in practice (Python's `statistics.mean/pstdev/stdev` and `fmean` are correctly rounded).
public enum Stats {
    /// Python `statistics.median`; nil for empty input.
    public static func median(_ v: [Double]) -> Double? {
        if v.isEmpty { return nil }
        let s = v.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// `med()` of the Python tools: drops nils first.
    public static func med(_ v: [Double?]) -> Double? { median(v.compactMap { $0 }) }

    public static func mean(_ v: [Double]) -> Double? {
        if v.isEmpty { return nil }
        let (h, l) = ddMean(v)
        return h + l
    }

    public static func pstdev(_ v: [Double]) -> Double? { v.isEmpty ? nil : stdevCore(v, ddof: 0) }

    /// Sample standard deviation; nil for fewer than 2 points.
    public static func stdev(_ v: [Double]) -> Double? { v.count < 2 ? nil : stdevCore(v, ddof: 1) }

    // MARK: double-double helpers

    typealias DD = (Double, Double)

    static func twoSum(_ a: Double, _ b: Double) -> DD {
        let s = a + b
        let bb = s - a
        return (s, (a - (s - bb)) + (b - bb))
    }

    static func ddAdd(_ x: DD, _ y: DD) -> DD {
        let (s, e) = twoSum(x.0, y.0)
        let e2 = e + (x.1 + y.1)
        return twoSum(s, e2)
    }

    static func ddSum(_ v: [Double]) -> DD {
        var acc: DD = (0, 0)
        for x in v { acc = ddAdd(acc, (x, 0)) }
        return acc
    }

    static func ddMean(_ v: [Double]) -> DD {
        let n = Double(v.count)
        let s = ddSum(v)
        let q = s.0 / n
        let r = (fma(-q, n, s.0) + s.1) / n
        return twoSum(q, r)
    }

    static func stdevCore(_ v: [Double], ddof: Int) -> Double {
        let n = Double(v.count)
        let m = ddMean(v)
        var ss: DD = (0, 0)
        for x in v {
            let d = ddAdd(twoSum(x, -m.0), (-m.1, 0))
            let p = d.0 * d.0
            let pe = fma(d.0, d.0, -p) + 2 * d.0 * d.1
            ss = ddAdd(ss, twoSum(p, pe))
        }
        let denom = n - Double(ddof)
        let q = ss.0 / denom
        let r = (fma(-q, denom, ss.0) + ss.1) / denom
        let var_ = twoSum(q, r)
        let s = var_.0.squareRoot()
        if s == 0 { return 0 }
        let corr = (fma(-s, s, var_.0) + var_.1) / (2 * s)
        return s + corr
    }
}

public func pyFormatFixed(_ x: Double, _ dp: Int) -> String { String(format: "%.\(dp)f", x) }

/// Python `fmt(x, dp)` of final_aggregate: "n/a" for nil.
public func fmtOpt(_ x: Double?, _ dp: Int) -> String { x.map { pyFormatFixed($0, dp) } ?? "n/a" }

func finite(_ x: Double?) -> Bool { x.map { $0.isFinite } ?? false }

/// Python's code-point ordering for strings.
func pyLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
}

/// Python `sorted(..., key=, reverse=)`: stable, and `reverse=True` keeps the original order of ties.
func stableSorted<T>(_ items: [T], key: (T) -> Double, reverse: Bool) -> [T] {
    let indexed = items.enumerated().map { ($0.offset, $0.element, key($0.element)) }
    let out = indexed.sorted { a, b in
        if a.2 != b.2 { return reverse ? a.2 > b.2 : a.2 < b.2 }
        return a.0 < b.0
    }
    return out.map { $0.1 }
}

/// Insertion-ordered dictionary (Python dict semantics for iteration order).
public struct OrderedDict<K: Hashable & Sendable, V: Sendable>: Sendable {
    public private(set) var keys: [K] = []
    private var store: [K: V] = [:]
    public init() {}
    public subscript(key: K) -> V? {
        get { store[key] }
        set {
            if let newValue {
                if store[key] == nil { keys.append(key) }
                store[key] = newValue
            } else if store.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    public var values: [V] { keys.map { store[$0]! } }
    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var items: [(K, V)] { keys.map { ($0, store[$0]!) } }
}

/// Python 3.12+ `sum()` of floats (Neumaier compensated, starting from int 0).
public func pySum(_ v: [Double]) -> Double {
    var result = 0.0
    var c = 0.0
    for x in v {
        let t = result + x
        if abs(result) >= abs(x) { c += (result - t) + x } else { c += (x - t) + result }
        result = t
    }
    if c != 0, c.isFinite { result += c }
    return result
}

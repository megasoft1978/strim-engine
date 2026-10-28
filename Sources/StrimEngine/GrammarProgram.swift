import Foundation
import StrimTemplate

/// A grammar the sampler can enforce, compiled from a JSON schema or a tool declaration.
/// Pure and tokenizer independent: HTTP front ends call `GrammarProgram.compile` to reject an
/// unsupported schema with a 400 before any request reaches the engine.
public struct GrammarError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

/// What the client asked to be enforced (Sendable value that crosses the engine API).
public struct ConstraintSpec: Sendable, Equatable {
    public enum JSONFormat: Sendable, Equatable {
        case object                       // response_format {"type":"json_object"}
        case schema(OrderedJSON)          // response_format {"type":"json_schema", ...}
    }
    public struct ToolCalls: Sendable, Equatable {
        public var tools: [ToolSpec]
        /// nil: any declared tool; otherwise the named function only.
        public var name: String?
        /// false: exactly one call (`parallel_tool_calls: false`, Anthropic `disable_parallel_tool_use`).
        public var parallel: Bool
        /// true (`tool_choice: required` / named): the output is a tool call. false (`auto`): the
        /// output is a tool call OR (when `json` is set) the JSON document.
        public var forced: Bool
        public init(tools: [ToolSpec], name: String? = nil, parallel: Bool = true, forced: Bool = true) {
            self.tools = tools; self.name = name; self.parallel = parallel; self.forced = forced
        }
    }
    public var json: JSONFormat?
    public var toolCalls: ToolCalls?
    /// Max reasoning tokens before the think block is force-closed (nil: unlimited).
    public var thinkingBudget: Int?
    public init(json: JSONFormat? = nil, toolCalls: ToolCalls? = nil, thinkingBudget: Int? = nil) {
        self.json = json; self.toolCalls = toolCalls; self.thinkingBudget = thinkingBudget
    }
    /// True when a grammar (not just a thinking budget) is enforced.
    public var hasGrammar: Bool { json != nil || (toolCalls?.forced ?? false) }
    public var isEmpty: Bool { json == nil && toolCalls == nil && thinkingBudget == nil }

    /// Stable key for the engine's compiled-program cache.
    var cacheKey: String {
        var s = ""
        switch json {
        case .none: s += "-"
        case .object?: s += "O"
        case let .schema(j)?: s += "S" + j.serialized()
        }
        if let t = toolCalls {
            s += "|T\(t.forced ? 1 : 0)\(t.parallel ? 1 : 0)\(t.name ?? "*")"
            for tool in t.tools { s += "\u{1}" + tool.json.serialized() }
        }
        return s
    }
}

public final class GrammarProgram: @unchecked Sendable {
    enum Node {
        case lit([UInt8])
        case seq([Int32])
        case alt([Int32])
        case ws                  // bounded run of JSON whitespace, may be empty
        case str                 // complete JSON string including quotes
        case num(integer: Bool)  // JSON number; ends on lookahead (accepting states may exit)
        case raw                 // tool-call parameter text up to and including "\n</parameter>\n"
    }

    static let maxWS: Int32 = 10
    static let paramEnd = Array("\n</parameter>\n".utf8)

    var nodes: [Node] = []
    var root: Int32 = 0

    /// Compiles the constraint into a byte-level grammar. Throws `GrammarError` for unsupported schemas.
    public static func compile(_ spec: ConstraintSpec) throws -> GrammarProgram {
        let c = Compiler()
        var alts: [Int32] = []
        var jsonRoot: Int32?
        if let f = spec.json {
            switch f {
            case .object: jsonRoot = c.seq([c.ws, c.anyObject, c.ws])
            case let .schema(s): jsonRoot = c.seq([c.ws, try c.schema(s, root: s, path: "#"), c.ws])
            }
        }
        var toolRoot: Int32?
        if let t = spec.toolCalls { toolRoot = try c.toolCalls(t) }
        if let t = spec.toolCalls, t.forced {
            alts.append(toolRoot!)
        } else {
            if let j = jsonRoot { alts.append(j) }
            if let r = toolRoot { alts.append(r) }
        }
        guard !alts.isEmpty else { throw GrammarError("no grammar to compile") }
        let p = GrammarProgram()
        p.root = alts.count == 1 ? alts[0] : c.alt(alts)
        p.nodes = c.nodes
        return p
    }

    /// Validation only (HTTP front ends): same errors as `compile`.
    public static func validate(_ spec: ConstraintSpec) throws {
        guard spec.hasGrammar else { return }
        _ = try compile(spec)
    }

    // MARK: compiler

    final class Compiler {
        var nodes: [Node] = []
        var litMemo: [[UInt8]: Int32] = [:]
        var refMemo: [String: Int32] = [:]
        /// Tool parameter schemas: value-narrowing keywords (pattern, format, min/max...) are not enforced and `oneOf`
        /// is read as `anyOf` (a superset). response_format schemas are always strict.
        var lenient = false
        lazy var ws: Int32 = add(.ws)
        lazy var str: Int32 = add(.str)
        lazy var number: Int32 = add(.num(integer: false))
        lazy var integer: Int32 = add(.num(integer: true))
        lazy var empty: Int32 = add(.seq([]))
        lazy var anyPair: (value: Int32, object: Int32) = buildAny()
        var anyValue: Int32 { anyPair.value }
        var anyObject: Int32 { anyPair.object }

        @discardableResult func add(_ n: Node) -> Int32 {
            nodes.append(n)
            return Int32(nodes.count - 1)
        }
        func lit(_ b: [UInt8]) -> Int32 {
            if let i = litMemo[b] { return i }
            let i = add(.lit(b)); litMemo[b] = i; return i
        }
        func lit(_ s: String) -> Int32 { lit(Array(s.utf8)) }
        func seq(_ items: [Int32]) -> Int32 { add(.seq(items)) }
        func alt(_ items: [Int32]) -> Int32 { add(.alt(items)) }

        /// Generic JSON value / object (json_object mode and untyped schemas).
        private func buildAny() -> (value: Int32, object: Int32) {
            let v = add(.seq([])), o = add(.seq([])), a = add(.seq([]))
            let orest = add(.seq([])), arest = add(.seq([]))
            let colon = seq([ws, lit(":"), ws])
            nodes[Int(orest)] = .alt([
                seq([ws, lit("}")]),
                seq([ws, lit(","), ws, str, colon, v, orest]),
            ])
            nodes[Int(o)] = .seq([lit("{"), alt([seq([ws, lit("}")]), seq([ws, str, colon, v, orest])])])
            nodes[Int(arest)] = .alt([seq([ws, lit("]")]), seq([ws, lit(","), ws, v, arest])])
            nodes[Int(a)] = .seq([lit("["), alt([seq([ws, lit("]")]), seq([ws, v, arest])])])
            nodes[Int(v)] = .alt([o, a, str, number, lit("true"), lit("false"), lit("null")])
            return (v, o)
        }

        // MARK: JSON schema

        static let annotations: Set<String> = [
            "$schema", "$id", "$comment", "title", "description", "default", "examples", "example",
            "deprecated", "readOnly", "writeOnly", "name", "strict", "$defs", "definitions",
        ]
        static let narrowing: Set<String> = [
            "pattern", "format", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
            "minLength", "maxLength", "uniqueItems", "minProperties", "maxProperties", "contentEncoding", "contentMediaType",
        ]
        static let structural: Set<String> = [
            "type", "properties", "required", "additionalProperties", "items", "minItems", "maxItems",
            "enum", "const", "anyOf", "nullable", "$ref",
        ]

        func schema(_ s: OrderedJSON, root: OrderedJSON, path: String) throws -> Int32 {
            if case let .bool(b) = s {
                if b { return anyValue }
                throw GrammarError("unsupported JSON schema: 'false' schema at \(path)")
            }
            guard case let .object(members) = s else { throw GrammarError("JSON schema at \(path) must be an object") }
            for m in members where !Self.annotations.contains(m.key) && !Self.structural.contains(m.key) {
                if lenient && (Self.narrowing.contains(m.key) || m.key == "oneOf") { continue }
                throw GrammarError("unsupported JSON schema keyword '\(m.key)' at \(path)")
            }
            if let ref = s["$ref"] {
                guard let r = ref.stringValue else { throw GrammarError("$ref at \(path) must be a string") }
                if let hit = refMemo[r] { return hit }
                let id = add(.seq([]))
                refMemo[r] = id
                let target = try resolve(r, root: root, path: path)
                let inner = try schema(target, root: root, path: r)
                nodes[Int(id)] = .seq([inner])
                return id
            }
            var inner: Int32
            if let c = s["const"] {
                inner = lit(try Self.compact(c, path: path))
            } else if let e = s["enum"] {
                guard let vals = e.arrayItems, !vals.isEmpty else { throw GrammarError("enum at \(path) must be a non-empty array") }
                var seen = Set<[UInt8]>(), items: [Int32] = []
                for v in vals {
                    let b = Array(try Self.compact(v, path: path).utf8)
                    if seen.insert(b).inserted { items.append(lit(b)) }
                }
                inner = items.count == 1 ? items[0] : alt(items)
            } else if let any = s["anyOf"] ?? (lenient ? s["oneOf"] : nil) {
                guard let subs = any.arrayItems, !subs.isEmpty else { throw GrammarError("anyOf at \(path) must be a non-empty array") }
                for k in ["type", "properties", "items"] where s[k] != nil {
                    throw GrammarError("unsupported JSON schema: '\(k)' next to anyOf at \(path)")
                }
                var items: [Int32] = []
                for (i, sub) in subs.enumerated() { items.append(try schema(sub, root: root, path: "\(path)/anyOf/\(i)")) }
                inner = items.count == 1 ? items[0] : alt(items)
            } else if let ty = s["type"] {
                if let name = ty.stringValue {
                    inner = try typed(name, s, root: root, path: path)
                } else if let names = ty.arrayItems, !names.isEmpty, names.allSatisfy({ $0.stringValue != nil }) {
                    inner = alt(try names.map { try typed($0.stringValue!, s, root: root, path: path) })
                } else {
                    throw GrammarError("type at \(path) must be a string or an array of strings")
                }
            } else if s["properties"] != nil {
                inner = try typed("object", s, root: root, path: path)
            } else if s["items"] != nil {
                inner = try typed("array", s, root: root, path: path)
            } else {
                inner = anyValue
            }
            if s["nullable"]?.boolValueOrNil == true { inner = alt([inner, lit("null")]) }
            return inner
        }

        private func resolve(_ ref: String, root: OrderedJSON, path: String) throws -> OrderedJSON {
            if ref == "#" { return root }
            let prefix = ref.hasPrefix("#/$defs/") ? "#/$defs/" : ref.hasPrefix("#/definitions/") ? "#/definitions/" : nil
            guard let prefix else { throw GrammarError("unsupported $ref '\(ref)' at \(path) (only #, #/$defs/NAME and #/definitions/NAME)") }
            let name = String(ref.dropFirst(prefix.count))
            let bag = root[prefix == "#/$defs/" ? "$defs" : "definitions"]
            guard let t = bag?[name] else { throw GrammarError("$ref '\(ref)' at \(path) does not resolve") }
            return t
        }

        private func typed(_ name: String, _ s: OrderedJSON, root: OrderedJSON, path: String) throws -> Int32 {
            switch name {
            case "string": return str
            case "number": return number
            case "integer": return integer
            case "boolean": return alt([lit("true"), lit("false")])
            case "null": return lit("null")
            case "array": return try array(s, root: root, path: path)
            case "object": return try object(s, root: root, path: path)
            default: throw GrammarError("unsupported JSON schema type '\(name)' at \(path)")
            }
        }

        private func array(_ s: OrderedJSON, root: OrderedJSON, path: String) throws -> Int32 {
            let item = try s["items"].map { try schema($0, root: root, path: path + "/items") } ?? anyValue
            func bound(_ k: String) throws -> Int? {
                guard let v = s[k] else { return nil }
                guard let n = v.intValueOrNil, n >= 0, n <= 1000 else { throw GrammarError("\(k) at \(path) must be an integer in 0...1000") }
                return n
            }
            let mn = try bound("minItems") ?? 0
            let mx = try bound("maxItems")
            if let mx, mx < mn { throw GrammarError("minItems > maxItems at \(path)") }
            let close = seq([ws, lit("]")])
            if mx == 0 { return seq([lit("["), close]) }
            var memo: [Int: Int32] = [:]
            let cap = max(mn, 1)
            func rest(_ k: Int) -> Int32 {          // after k items
                let key = mx == nil ? min(k, cap) : k
                if let h = memo[key] { return h }
                let id = add(.seq([]))
                memo[key] = id
                var alts: [Int32] = []
                if k >= mn { alts.append(close) }
                if mx == nil || k < mx! {
                    alts.append(seq([ws, lit(","), ws, item, rest(mx == nil ? min(k + 1, cap) : k + 1)]))
                }
                nodes[Int(id)] = alts.count == 1 ? .seq([alts[0]]) : .alt(alts)
                return id
            }
            var first: [Int32] = []
            if mn == 0 { first.append(close) }
            first.append(seq([ws, item, rest(1)]))
            return seq([lit("["), first.count == 1 ? first[0] : alt(first)])
        }

        private func object(_ s: OrderedJSON, root: OrderedJSON, path: String) throws -> Int32 {
            let props = s["properties"]?.members
            if s["properties"] != nil && props == nil { throw GrammarError("properties at \(path) must be an object") }
            let ap = s["additionalProperties"]
            let required: Set<String>
            if let r = s["required"] {
                guard let a = r.arrayItems, a.allSatisfy({ $0.stringValue != nil }) else {
                    throw GrammarError("required at \(path) must be an array of strings")
                }
                required = Set(a.compactMap(\.stringValue))
            } else { required = [] }

            let declared = props ?? []
            if declared.isEmpty {
                // free-form object / map
                if let ap, ap.boolValueOrNil != true, ap.boolValueOrNil != false, case .object = ap {
                    return map(valueNode: try schema(ap, root: root, path: path + "/additionalProperties"))
                }
                if let b = ap?.boolValueOrNil {
                    if b == false {
                        if !required.isEmpty { throw GrammarError("required without properties at \(path)") }
                        return seq([lit("{"), ws, lit("}")])
                    }
                    return anyObject
                }
                if ap != nil { throw GrammarError("additionalProperties at \(path) must be a boolean or a schema") }
                if !required.isEmpty { throw GrammarError("required without properties at \(path)") }
                return anyObject
            }
            if let ap {
                guard ap.boolValueOrNil == false || lenient else {
                    throw GrammarError("unsupported JSON schema: additionalProperties other than false next to properties at \(path)")
                }
            }
            let names = Set(declared.map(\.key))
            for r in required where !names.contains(r) {
                throw GrammarError("required property '\(r)' at \(path) is not declared in properties")
            }
            var values: [Int32] = []
            for m in declared { values.append(try schema(m.value, root: root, path: "\(path)/properties/\(m.key)")) }
            var memo: [Int: Int32] = [:]
            func members(_ i: Int, _ hasPrev: Bool) -> Int32 {
                let key = i * 2 + (hasPrev ? 1 : 0)
                if let h = memo[key] { return h }
                if i == declared.count { memo[key] = empty; return empty }
                var head: [Int32] = hasPrev ? [lit(",")] : []
                head += [ws, lit(Self.keyBytes(declared[i].key)), ws, lit(":"), ws, values[i]]
                let take = seq(head + [members(i + 1, true)])
                let id: Int32
                if required.contains(declared[i].key) { id = take }
                else { id = alt([take, members(i + 1, hasPrev)]) }
                memo[key] = id
                return id
            }
            return seq([lit("{"), members(0, false), ws, lit("}")])
        }

        private func map(valueNode v: Int32) -> Int32 {
            let rest = add(.seq([]))
            let colon = seq([ws, lit(":"), ws])
            nodes[Int(rest)] = .alt([seq([ws, lit("}")]), seq([ws, lit(","), ws, str, colon, v, rest])])
            return seq([lit("{"), alt([seq([ws, lit("}")]), seq([ws, str, colon, v, rest])])])
        }

        static func keyBytes(_ k: String) -> [UInt8] { Array(OrderedJSON.string(k).serialized().utf8) }

        /// Compact JSON text for enum / const members.
        static func compact(_ v: OrderedJSON, path: String) throws -> String {
            switch v {
            case .null, .bool, .int, .bigInt, .string: return v.serialized()
            case let .double(d):
                guard d.isFinite else { throw GrammarError("non-finite number in enum/const at \(path)") }
                return v.serialized()
            case let .array(a): return "[" + (try a.map { try compact($0, path: path) }).joined(separator: ",") + "]"
            case let .object(m):
                return "{" + (try m.map { OrderedJSON.string($0.key).serialized() + ":" + (try compact($0.value, path: path)) }).joined(separator: ",") + "}"
            }
        }

        // MARK: tool calls (Qwen format)

        func toolCalls(_ t: ConstraintSpec.ToolCalls) throws -> Int32 {
            var tools = t.tools.filter { $0.name != nil }
            if let n = t.name { tools = tools.filter { $0.name == n } }
            guard !tools.isEmpty else {
                throw GrammarError(t.name.map { "tool_choice names function '\($0)' which is not in tools" } ?? "tool_choice requires at least one declared tool")
            }
            var calls: [Int32] = []
            for tool in tools { calls.append(try call(tool)) }
            let one = calls.count == 1 ? calls[0] : alt(calls)
            guard t.parallel else { return seq([ws, one]) }
            let many = add(.seq([]))
            nodes[Int(many)] = .seq([one, alt([empty, seq([lit("\n"), many])])])
            return seq([ws, many])
        }

        private func call(_ tool: ToolSpec) throws -> Int32 {
            let name = tool.name!
            let wasLenient = lenient
            lenient = true
            defer { lenient = wasLenient }
            var parts: [Int32] = [lit("<tool_call>\n<function=\(name)>\n")]
            let params = tool.parameters
            let props = params?["properties"]?.members ?? []
            var required = Set<String>()
            if let r = params?["required"]?.arrayItems { required = Set(r.compactMap(\.stringValue)) }
            for m in props {
                let path = "tools/\(name)/\(m.key)"
                let head = lit("<parameter=\(m.key)>\n")
                let value: Int32
                let sch = m.value
                if sch["type"]?.stringValue == "string", sch["enum"] == nil, sch["const"] == nil, sch["anyOf"] == nil {
                    value = add(.raw)                       // raw text, ends with the parameter terminator
                } else if let e = sch["enum"]?.arrayItems, !e.isEmpty, e.allSatisfy({ $0.stringValue != nil }),
                          sch["type"] == nil || sch["type"]?.stringValue == "string" {
                    let lits = e.compactMap(\.stringValue).map { lit($0) }
                    value = seq([lits.count == 1 ? lits[0] : alt(lits), lit(GrammarProgram.paramEnd)])
                } else {
                    value = seq([try schema(sch, root: params ?? .null, path: path), lit(GrammarProgram.paramEnd)])
                }
                let item = seq([head, value])
                parts.append(required.contains(m.key) ? item : alt([item, empty]))
            }
            parts.append(lit("</function>\n</tool_call>"))
            return seq(parts)
        }
    }
}

extension OrderedJSON {
    var arrayItems: [OrderedJSON]? { if case let .array(a) = self { return a }; return nil }
    var boolValueOrNil: Bool? { if case let .bool(b) = self { return b }; return nil }
    var intValueOrNil: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
        default: return nil
        }
    }
}

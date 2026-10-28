import Foundation
import StrimEngine
import StrimTemplate

/// Defaults applied when a request omits a sampling field (from the model's generation_config.json).
public struct SamplingDefaults: Sendable {
    public var temperature: Double = 1.0
    public var topP: Double = 0.95
    public var topK: Int = 20
    public var maxTokens: Int = 4096
    /// Server-wide ceiling for any client `max_tokens` / `max_completion_tokens` / `max_output_tokens`
    /// (larger values are clamped, not rejected). `STRIM_MAX_OUTPUT_TOKENS`, default 1_048_576.
    public var maxOutputTokens: Int = ServerLimits.maxOutputTokens
    public init() {}

    public static func load(modelDir: String) -> SamplingDefaults {
        var d = SamplingDefaults()
        let url = URL(fileURLWithPath: modelDir).appendingPathComponent("generation_config.json")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let j = try? OrderedJSON.parse(text) else { return d }
        if let v = j["temperature"]?.number { d.temperature = v }
        if let v = j["top_p"]?.number { d.topP = v }
        if let v = j["top_k"]?.number, v >= 0, v < 1e9 { d.topK = Int(v) }
        return d
    }
}

extension OrderedJSON {
    var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [OrderedJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// A parsed /v1/chat/completions request.
struct ChatRequest {
    var messages: [Message]
    var config: SessionConfig
    var params: GenParams
    var stop: [String]
    var stream: Bool
    var includeUsage: Bool
    /// Conversation fingerprint (system + first user message + tools + template config).
    var fingerprint: UInt64
    var hasTools: Bool { !config.tools.isEmpty }

    /// `ceiling` is the class the server derived from the authenticated token: a client-supplied priority may lower
    /// itself below it (background) but never raise itself above it.
    static func parse(_ body: Data, headerPriority: String?, defaults: SamplingDefaults,
                      ceiling: Priority = .interactive) throws -> ChatRequest {
        guard let text = String(data: body, encoding: .utf8), let root = try? OrderedJSON.parse(text),
              case .object = root else { throw APIError.badRequest("body is not a JSON object") }

        guard let raw = root["messages"]?.arrayValue, !raw.isEmpty else {
            throw APIError.badRequest("messages must be a non-empty list")
        }
        if let n = root["n"], !n.isNull, n.intValue != 1 { throw APIError.badRequest("n > 1 is not supported") }

        var priority = Priority.interactive
        let pname = headerPriority ?? root["priority"]?.stringValue ?? root["strim_priority"]?.stringValue
        if let pname {
            switch pname {
            case "interactive": priority = .interactive
            case "background": priority = .background
            default: throw APIError.badRequest("priority must be one of ('interactive', 'background')")
            }
        }
        if priority.rawValue < ceiling.rawValue { priority = ceiling }

        var messages: [Message] = []
        for m in raw {
            guard case .object = m else { throw APIError.badRequest("each message must be an object") }
            if let parts = m["content"]?.arrayValue {
                for p in parts {
                    let t = p["type"]?.stringValue
                    if t == "image_url" || t == "image" || t == "video" || p["image_url"] != nil || p["image"] != nil || p["video"] != nil {
                        throw APIError.badRequest("image and video content parts are not supported")
                    }
                }
            }
            messages.append(try Message(json: m))
        }

        // tools
        var toolChoice: String?
        var toolsDisabled = false
        if let tc = root["tool_choice"] {
            if let s = tc.stringValue { toolChoice = s; toolsDisabled = (s == "none") }
        }
        var tools: [ToolSpec] = []
        if !toolsDisabled, let list = root["tools"]?.arrayValue {
            for t in list {
                if let ty = t["type"]?.stringValue, ty != "function" { continue }
                let fn = t["function"] ?? t
                guard let name = fn["name"]?.stringValue, !name.isEmpty else { continue }
                let params = fn["parameters"] ?? fn["input_schema"]
                    ?? .ordered([("type", .string("object")), ("properties", .object([]))])
                tools.append(ToolSpec(name: name, description: fn["description"]?.stringValue ?? "", parameters: params))
            }
        }

        // template kwargs
        let kwargs = root["chat_template_kwargs"]
        var enableThinking = kwargs?["enable_thinking"]?.boolValue
        if enableThinking == nil { enableThinking = root["enable_thinking"]?.boolValue }
        let preserve = kwargs?["preserve_thinking"]?.boolValue
        let effort = kwargs?["reasoning_effort"]?.stringValue ?? root["reasoning_effort"]?.stringValue

        // sampling
        func num(_ key: String) throws -> Double? {
            guard let v = root[key], !v.isNull else { return nil }
            guard let d = v.number else { throw APIError.badRequest("\(key) must be a number") }
            return d
        }
        let temperature = try num("temperature") ?? defaults.temperature
        let topP = try num("top_p") ?? defaults.topP
        guard temperature >= 0 else { throw APIError.badRequest("temperature must be >= 0") }
        guard topP > 0, topP <= 1 else { throw APIError.badRequest("top_p must be in (0, 1]") }
        var topK = defaults.topK
        if let v = root["top_k"], !v.isNull {
            guard let k = v.intValue, k >= 0 else { throw APIError.badRequest("top_k must be a non-negative integer") }
            topK = k
        }
        var seed: UInt64?
        if let v = root["seed"], !v.isNull {
            guard let s = v.intValue, s >= 0 else { throw APIError.badRequest("seed must be a non-negative integer") }
            seed = UInt64(s)
        }
        var maxTokens = defaults.maxTokens
        for key in ["max_completion_tokens", "max_tokens"] {
            if let v = root[key], !v.isNull {
                guard let n = v.intValue, n >= 1 else { throw APIError.badRequest("max_tokens must be a positive integer") }
                maxTokens = n
                break
            }
        }
        var stop: [String] = []
        if let s = root["stop"], !s.isNull {
            if let one = s.stringValue { stop = [one] }
            else if let arr = s.arrayValue, arr.allSatisfy({ $0.stringValue != nil }) { stop = arr.compactMap(\.stringValue) }
            else { throw APIError.badRequest("stop must be a string or a list of strings") }
        }
        stop = stop.filter { !$0.isEmpty }
        guard stop.count <= ServerLimits.maxStopSequences, stop.allSatisfy({ $0.utf8.count <= ServerLimits.maxStopBytes }) else {
            throw APIError.badRequest("stop: at most \(ServerLimits.maxStopSequences) sequences of \(ServerLimits.maxStopBytes) bytes")
        }
        let ignoreEOS = root["ignore_eos"]?.boolValue ?? false
        let includeUsage = root["stream_options"]?["include_usage"]?.boolValue ?? false

        var config = SessionConfig(tools: tools, enableThinking: enableThinking, toolChoice: toolChoice,
                                   reasoningEffort: effort, preserveThinking: preserve)
        config.reasoningPolicy = .disableWhenTools

        maxTokens = min(maxTokens, defaults.maxOutputTokens)
        if priority != .interactive {
            // Background class cannot pin a slot with a long decode, `ignore_eos` or not.
            maxTokens = min(maxTokens, ServerLimits.backgroundMaxTokens)
        }
        let params = GenParams(maxTokens: maxTokens, temperature: Float(temperature), topP: Float(topP), topK: topK,
                               seed: seed, stopIds: [], priority: priority, ignoreEOS: ignoreEOS)
        return ChatRequest(messages: messages, config: config, params: params, stop: stop,
                           stream: root["stream"]?.boolValue ?? false, includeUsage: includeUsage,
                           fingerprint: fingerprint(raw, tools: tools, config: config))
    }

    /// FNV-1a over: leading system/developer messages, the first user message, the tool declarations and the
    /// template config. Turns of one conversation share it; the later turns only append.
    static func fingerprint(_ raw: [OrderedJSON], tools: [ToolSpec], config: SessionConfig) -> UInt64 {
        var s = ""
        for m in raw {
            let role = m["role"]?.stringValue
            if role == "system" || role == "developer" { s += "S" + m.serialized() + "\u{1}" } else { break }
        }
        if let u = raw.first(where: { $0["role"]?.stringValue == "user" }) { s += "U" + u.serialized() + "\u{1}" }
        for t in tools { s += "T" + t.json.serialized() + "\u{1}" }
        s += "C\(config.enableThinking.map(String.init(describing:)) ?? "-")|\(config.toolChoice ?? "-")|"
        s += "\(config.reasoningEffort ?? "-")|\(config.preserveThinking.map(String.init(describing:)) ?? "-")"
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

import Foundation

public struct TemplateError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum Role: String, Sendable {
    case system, user, assistant, tool
}

/// Message content as the template sees it: a string, a list of typed parts, or none/empty.
public enum MessageContent: Equatable, Sendable {
    case none
    case text(String)
    /// OpenAI-style parts: {"type":"text","text":...}, image / image_url / video items.
    case parts([OrderedJSON])
}

public struct ToolCall: Equatable, Sendable {
    public var name: String
    /// Arguments as an ordered JSON object (insertion order is what the template renders). nil = absent.
    public var arguments: [OrderedJSON.Member]?
    public init(name: String, arguments: [OrderedJSON.Member]? = []) {
        self.name = name
        self.arguments = arguments
    }
    public init(name: String, arguments: [(String, OrderedJSON)]) {
        self.init(name: name, arguments: arguments.map { OrderedJSON.Member($0.0, $0.1) })
    }
}

public struct Message: Equatable, Sendable {
    public var role: Role
    public var content: MessageContent
    /// Only used for assistant messages; non-string reasoning_content is modelled as nil (the template ignores it).
    public var reasoningContent: String?
    public var toolCalls: [ToolCall]

    public init(role: Role, content: MessageContent = .none, reasoningContent: String? = nil, toolCalls: [ToolCall] = []) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
    }

    public static func system(_ t: String) -> Message { .init(role: .system, content: .text(t)) }
    public static func user(_ t: String) -> Message { .init(role: .user, content: .text(t)) }
    public static func assistant(_ t: String?, reasoning: String? = nil, toolCalls: [ToolCall] = []) -> Message {
        .init(role: .assistant, content: t.map { .text($0) } ?? .none, reasoningContent: reasoning, toolCalls: toolCalls)
    }
    public static func tool(_ t: String) -> Message { .init(role: .tool, content: .text(t)) }

    /// Decode an OpenAI/HF-style message object. "developer" maps to system (as the retired strim_front did, removed 2026-10-27);
    /// tool_call `arguments` may be an object or a JSON string; both `{function:{...}}` and flat calls work.
    public init(json: OrderedJSON) throws {
        guard case .object = json else { throw TemplateError("message must be an object") }
        let roleName = json["role"]?.stringValue ?? ""
        switch roleName {
        case "system", "developer": role = .system
        case "user": role = .user
        case "assistant": role = .assistant
        case "tool": role = .tool
        default: throw TemplateError("Unexpected message role.")
        }
        switch json["content"] {
        case nil, .some(.null): content = .none
        case let .some(.string(s)): content = .text(s)
        case let .some(.array(a)): content = .parts(a)
        default: throw TemplateError("Unexpected content type.")
        }
        reasoningContent = json["reasoning_content"]?.stringValue
        toolCalls = []
        if case let .array(calls)? = json["tool_calls"] {
            for c in calls {
                let f = c["function"] ?? c
                guard let name = f["name"]?.stringValue else { throw TemplateError("tool call without name") }
                var args: [OrderedJSON.Member]?
                switch f["arguments"] {
                case nil: args = nil
                case let .some(.object(m)): args = m
                case let .some(.string(s)):
                    if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args = [] } else {
                        guard case let .object(m) = try OrderedJSON.parse(s) else {
                            throw TemplateError("tool_calls arguments must be a JSON object")
                        }
                        args = m
                    }
                default: throw TemplateError("tool_calls arguments must be a JSON object")
                }
                toolCalls.append(ToolCall(name: name, arguments: args))
            }
        }
    }
}

/// A tool declaration, rendered verbatim with `tojson` (insertion order preserved).
public struct ToolSpec: Equatable, Sendable {
    public var json: OrderedJSON
    public init(json: OrderedJSON) { self.json = json }

    /// Builds the standard OpenAI wrapper {"type":"function","function":{"name","description","parameters"}}.
    public init(name: String, description: String, parameters: OrderedJSON) {
        json = .ordered([
            ("type", .string("function")),
            ("function", .ordered([("name", .string(name)), ("description", .string(description)), ("parameters", parameters)])),
        ])
    }

    var function: OrderedJSON { json["function"] ?? json }
    public var name: String? { function["name"]?.stringValue }
    /// The `parameters` JSON schema, used by the tool-call parser for typed argument coercion.
    public var parameters: OrderedJSON? { function["parameters"] }
}

/// Reasoning toggle policy. Default `.disableWhenTools` (rapid-mlx behaviour): when tools are declared and
/// tool_choice != "none", enable_thinking is forced to false so the prompt ends `<think>\n\n</think>\n\n`.
public enum ReasoningPolicy: String, Sendable {
    /// Pass the caller's enable_thinking straight to the template (nil = template default, thinking on).
    case templateDefault
    case disableWhenTools
    case off
    case on

    public func resolve(enableThinking: Bool?, hasTools: Bool, toolChoice: String? = nil) -> Bool? {
        switch self {
        case .templateDefault: return enableThinking
        case .off: return false
        case .on: return true
        case .disableWhenTools: return (hasTools && toolChoice != "none") ? false : enableThinking
        }
    }
}

public struct Segment: Equatable, Sendable {
    /// "system" (tools/system header), "user", "assistant", "tool" (one merged `<|im_start|>user` block of
    /// consecutive tool messages), or "generation_prompt" (the trailing `<|im_start|>assistant\n<think>...`).
    public var role: String
    public var text: String
    /// Indices into the input messages this segment renders (empty for a synthesised header / generation prompt).
    public var messages: Range<Int>
}

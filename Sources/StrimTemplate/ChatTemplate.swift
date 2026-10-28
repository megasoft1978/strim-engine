import Foundation

/// Hand-written renderer for the Qwen3.8 chat template (models/qwen38-4bit/chat_template.jinja).
/// Not a Jinja engine: it reproduces exactly that template, byte for byte (see bench/fixtures/template_parity.json).
public enum ChatTemplate {
    public static let imStart = "<|im_start|>"
    public static let imEnd = "<|im_end|>"

    /// Full prompt text.
    public static func render(
        messages: [Message],
        tools: [ToolSpec] = [],
        addGenerationPrompt: Bool = true,
        enableThinking: Bool? = nil,
        reasoningPolicy: ReasoningPolicy = .disableWhenTools,
        toolChoice: String? = nil,
        reasoningEffort: String? = nil,
        preserveThinking: Bool? = nil
    ) throws -> String {
        try renderSegments(
            messages: messages, tools: tools, addGenerationPrompt: addGenerationPrompt, enableThinking: enableThinking,
            reasoningPolicy: reasoningPolicy, toolChoice: toolChoice, reasoningEffort: reasoningEffort,
            preserveThinking: preserveThinking
        ).map(\.text).joined()
    }

    /// Per-turn pieces whose concatenation equals `render`. A caller that keeps a token ledger renders only
    /// the suffix segments it has no ids for and splices stored ids for earlier assistant turns.
    ///
    /// `enableThinking` is the request value (nil = unset); `reasoningPolicy` decides what the template sees.
    /// `toolChoice == "none"` drops the tools, as the front does.
    public static func renderSegments(
        messages: [Message],
        tools: [ToolSpec] = [],
        addGenerationPrompt: Bool = true,
        enableThinking: Bool? = nil,
        reasoningPolicy: ReasoningPolicy = .disableWhenTools,
        toolChoice: String? = nil,
        reasoningEffort: String? = nil,
        preserveThinking: Bool? = nil
    ) throws -> [Segment] {
        if messages.isEmpty { throw TemplateError("No messages provided.") }
        let activeTools = toolChoice == "none" ? [] : tools
        let thinking = reasoningPolicy.resolve(enableThinking: enableThinking, hasTools: !tools.isEmpty, toolChoice: toolChoice)

        // reasoning instructions
        var reasoningInstructions = ""
        if thinking == nil || thinking == true {
            switch reasoningEffort ?? "xhigh" {
            case "xhigh":
                reasoningInstructions = "Reasoning effort is set to xhigh. Please think carefully through the task, validate key assumptions, consider plausible alternatives, and prioritize correctness, consistency, and clarity in the final answer."
            case "low":
                reasoningInstructions = "Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration."
            case "medium": break
            default:
                throw TemplateError("Unexpected reasoning effort \(reasoningEffort ?? ""). Supported types are xhigh (default), medium, and low.")
            }
        }

        // content of every message (template computes render_content(...)|trim for all of them)
        var contents = [String]()
        contents.reserveCapacity(messages.count)
        for m in messages {
            contents.append(pyTrim(try renderContent(m.content, isSystem: false)))
        }
        // system message content at index 0 is rendered with is_system_content=true (images forbidden)
        var systemContent = ""
        if messages[0].role == .system {
            systemContent = pyTrim(try renderContent(messages[0].content, isSystem: true))
        }

        var segments = [Segment]()
        var header = ""
        if !activeTools.isEmpty {
            header += imStart + "system\n"
            if !reasoningInstructions.isEmpty { header += reasoningInstructions + "\n\n" }
            header += "# Tools\n\nYou have access to the following functions:\n\n<tools>"
            for t in activeTools {
                header += "\n"
                header += t.json.serialized()
            }
            header += "\n</tools>"
            header += toolInstructions
            if !systemContent.isEmpty { header += "\n\n" + systemContent }
            header += imEnd + "\n"
        } else if messages[0].role == .system {
            if !systemContent.isEmpty {
                header += imStart + "system\n" + (reasoningInstructions.isEmpty ? "" : reasoningInstructions + "\n\n")
                    + systemContent + imEnd + "\n"
            } else if !reasoningInstructions.isEmpty {
                header += imStart + "system\n" + reasoningInstructions + imEnd + "\n"
            }
        } else if !reasoningInstructions.isEmpty {
            header += imStart + "system\n" + reasoningInstructions + imEnd + "\n"
        }
        if !header.isEmpty {
            segments.append(Segment(role: "system", text: header, messages: messages[0].role == .system ? 0..<1 : 0..<0))
        }

        // last_query_index: last user message that is not a lone <tool_response> wrapper
        var lastQueryIndex = messages.count - 1
        var multiStep = true
        for index in stride(from: messages.count - 1, through: 0, by: -1) where multiStep && messages[index].role == .user {
            let c = contents[index]
            if !(c.hasPrefixScalars("<tool_response>") && c.hasSuffixScalars("</tool_response>")) {
                multiStep = false
                lastQueryIndex = index
            }
        }
        if multiStep { throw TemplateError("No user query found in messages.") }

        var i = 0
        while i < messages.count {
            let message = messages[i]
            let content = contents[i]
            switch message.role {
            case .system:
                if i != 0 { throw TemplateError("System message must be at the beginning.") }
                i += 1
            case .user:
                segments.append(Segment(role: "user", text: imStart + "user\n" + content + imEnd + "\n", messages: i..<i + 1))
                i += 1
            case .assistant:
                var s = imStart + "assistant\n"
                let reasoning = pyTrim(message.reasoningContent ?? "")
                if preserveThinking ?? true || i > lastQueryIndex {
                    s += "<think>\n" + reasoning + "\n</think>\n\n" + content
                } else {
                    s += content
                }
                for (n, call) in message.toolCalls.enumerated() {
                    if n == 0 {
                        s += content.isEmpty ? "<tool_call>\n<function=\(call.name)>\n" : "\n\n<tool_call>\n<function=\(call.name)>\n"
                    } else {
                        s += "\n<tool_call>\n<function=\(call.name)>\n"
                    }
                    for arg in call.arguments ?? [] {
                        s += "<parameter=" + arg.key + ">\n"
                        if case let .string(v) = arg.value { s += v } else { s += arg.value.serialized() }
                        s += "\n</parameter>\n"
                    }
                    s += "</function>\n</tool_call>"
                }
                s += imEnd + "\n"
                segments.append(Segment(role: "assistant", text: s, messages: i..<i + 1))
                i += 1
            case .tool:
                // consecutive tool messages share one `<|im_start|>user` block (none if it is the first message)
                var s = i > 0 ? imStart + "user" : ""
                var j = i
                while j < messages.count, messages[j].role == .tool {
                    s += "\n<tool_response>\n" + contents[j] + "\n</tool_response>"
                    j += 1
                }
                s += imEnd + "\n"
                segments.append(Segment(role: "tool", text: s, messages: i..<j))
                i = j
            }
        }

        if addGenerationPrompt {
            let think = thinking == false ? "<think>\n\n</think>\n\n" : "<think>\n"
            segments.append(Segment(role: "generation_prompt", text: imStart + "assistant\n" + think, messages: messages.count..<messages.count))
        }
        return segments
    }

    static let toolInstructions =
        "\n\nIf you choose to call a function ONLY reply in the following format with NO suffix:\n\n<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n</parameter>\n<parameter=example_parameter_2>\nThis is the value for the second parameter\nthat can span\nmultiple lines\n</parameter>\n</function>\n</tool_call>\n\n<IMPORTANT>\nReminder:\n- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags\n- Required parameters MUST be specified\n- You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after\n- If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls\n</IMPORTANT>"

    /// The template's `render_content` macro.
    static func renderContent(_ content: MessageContent, isSystem: Bool) throws -> String {
        switch content {
        case .none: return ""
        case let .text(s): return s
        case let .parts(items):
            var out = ""
            for item in items {
                guard case .object = item else { throw TemplateError("Unexpected item type in content.") }
                let type = item["type"]?.stringValue
                if item["image"] != nil || item["image_url"] != nil || type == "image" {
                    if isSystem { throw TemplateError("System message cannot contain images.") }
                    out += "<|vision_start|><|image_pad|><|vision_end|>"
                } else if item["video"] != nil || type == "video" {
                    if isSystem { throw TemplateError("System message cannot contain videos.") }
                    out += "<|vision_start|><|video_pad|><|vision_end|>"
                } else if let text = item["text"] {
                    guard case let .string(s) = text else { throw TemplateError("non-string text part") }
                    out += s
                } else {
                    throw TemplateError("Unexpected item type in content.")
                }
            }
            return out
        }
    }
}

// MARK: Python string semantics

/// Python `str.isspace()` for a scalar (what `str.strip()` and Jinja `trim` remove).
func isPySpace(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

/// Jinja `trim` = Python `str.strip()`.
func pyTrim(_ s: String) -> String {
    let u = s.unicodeScalars
    guard let first = u.firstIndex(where: { !isPySpace($0) }) else { return "" }
    let last = u.lastIndex(where: { !isPySpace($0) })!
    return String(u[first...last])
}

extension String {
    /// Scalar-wise prefix test (String.hasPrefix compares Characters, which merges combining marks).
    func hasPrefixScalars(_ p: String) -> Bool { unicodeScalars.starts(with: p.unicodeScalars) }
    func hasSuffixScalars(_ p: String) -> Bool { unicodeScalars.reversed().starts(with: p.unicodeScalars.reversed()) }
}

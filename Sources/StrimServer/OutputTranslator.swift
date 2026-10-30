import Foundation
import StrimEngine
import StrimTemplate

/// OpenAI-level output events.
enum Out {
    case content(String)
    case reasoning(String)
    case toolStart(index: Int, id: String, name: String)
    case toolArgs(index: Int, fragment: String)
    case done(finishReason: String, usage: Usage)
}

/// Turns engine `GenEvent`s into OpenAI-level events: applies stop strings to the content text, streams tool
/// call arguments as JSON fragments (their concatenation is the full arguments object), and picks the final
/// finish reason (tool_calls beats stop/length, as in the Python reference front, but only for calls that completed).
struct OutputTranslator {
    private var scanner: StopScanner
    private var toolIndex = -1
    private var argCount = 0
    private var openCall = false
    /// Calls whose `toolCallEnd` arrived; a truncated call never counts.
    private(set) var completedCalls = 0
    /// Indices of calls cut off inside the function body (`toolCallError` while open). Never executable.
    private(set) var abortedCalls: Set<Int> = []
    /// A stop string matched; the caller should cancel the generation and keep draining to `.finished`.
    private(set) var stopHit = false

    /// The stop string that matched, if any.
    var stopMatched: String? { scanner.matched }

    init(stop: [String]) { scanner = StopScanner(stop) }

    mutating func handle(_ ev: GenEvent) -> [Out] {
        if case let .finished(reason, usage) = ev {
            var outs: [Out] = []
            if !stopHit {
                let tail = scanner.flush()
                if !tail.isEmpty { outs.append(.content(tail)) }
            }
            var fr: String
            switch reason {
            case .length: fr = stopHit ? "stop" : "length"
            case .stop, .cancelled: fr = "stop"
            }
            if completedCalls > 0 { fr = "tool_calls" }
            outs.append(.done(finishReason: fr, usage: usage))
            return outs
        }
        if stopHit { return [] }
        switch ev {
        case let .tokens(_, text):
            guard !text.isEmpty else { return [] }
            let (out, hit) = scanner.feed(text)
            if hit { stopHit = true }
            return out.isEmpty ? [] : [.content(out)]
        case let .reasoning(t):
            return t.isEmpty ? [] : [.reasoning(t)]
        case let .toolCallBegin(name):
            var outs: [Out] = []
            let held = scanner.flush()
            if !held.isEmpty { outs.append(.content(held)) }
            toolIndex += 1; openCall = true; argCount = 0
            outs.append(.toolStart(index: toolIndex, id: "call_" + Self.randomId(), name: name))
            return outs
        case let .toolCallArg(key, value):
            let frag = (argCount == 0 ? "{" : ", ") + OrderedJSON.string(key).serialized() + ": " + value.serialized()
            argCount += 1
            return [.toolArgs(index: toolIndex, fragment: frag)]
        case .toolCallEnd:
            openCall = false; completedCalls += 1
            return [.toolArgs(index: toolIndex, fragment: argCount == 0 ? "{}" : "}")]
        case .toolCallError:
            // Parser diagnostics are for the harness, never assistant content for API clients. A call cut off
            // mid-body was already announced (begin), so its args must never parse as valid JSON.
            guard openCall else { return [] }
            openCall = false; abortedCalls.insert(toolIndex)
            return argCount == 0 ? [.toolArgs(index: toolIndex, fragment: "{")] : []
        case .finished:
            return []
        }
    }

    static func randomId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
    }
}

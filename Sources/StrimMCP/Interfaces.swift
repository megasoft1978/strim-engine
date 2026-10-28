import Foundation
import StrimEngine
import StrimTemplate

// Interfaces for the streamable-HTTP `/mcp` route (W2 wires it into StrimOpenAIServer).

public enum MCPProtocol {
    public static let v20250326 = "2025-03-26"
    public static let v20250618 = "2025-06-18"
    public static let v20251125 = "2025-11-25"
    /// Newest first; negotiation picks the client's version if listed, else the newest.
    public static let supported = [v20251125, v20250618, v20250326]
}

/// One tool in `tools/list` (`strim_task`, `strim_job`, `strim_cancel`, `strim_ask`).
public struct MCPToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: OrderedJSON
    /// Optional display title and MCP tool annotations (readOnlyHint etc.); omitted from `tools/list` when nil.
    public var title: String?
    public var annotations: OrderedJSON?
    public init(name: String, description: String, inputSchema: OrderedJSON,
                title: String? = nil, annotations: OrderedJSON? = nil) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
        self.title = title; self.annotations = annotations
    }
}

/// Outcome of one tool call. Failures are results with `isError` true, not protocol errors.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var structured: OrderedJSON?
    public var isError: Bool
    public init(text: String, structured: OrderedJSON? = nil, isError: Bool = false) {
        self.text = text; self.structured = structured; self.isError = isError
    }
}

/// Backend for `tools/list` and `tools/call`. `progress` may be called from any thread; the route
/// coalesces reports and forwards at most one `notifications/progress` per progress interval.
public protocol MCPToolProvider: Sendable {
    func definitions() -> [MCPToolDefinition]
    func call(name: String, arguments: OrderedJSON, progress: @Sendable (Double, String) -> Void) async -> MCPToolResult
}

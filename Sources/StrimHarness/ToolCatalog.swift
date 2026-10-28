import Foundation

/// The fixed, ordered tool list. Order and spec JSON are part of the prompt prefix: changing either
/// invalidates the prefix cache (guarded by a golden test). A `task` tool is added later, before `finish`.
public enum ToolCatalog {
    public static let names = ["read_file", "list_files", "grep", "edit_file", "write_file", "bash", "finish"]

    public static func all(runner: CommandRunner) -> [HarnessTool] {
        [ReadFileTool(), ListFilesTool(), GrepTool(), EditFileTool(), WriteFileTool(), BashTool(runner: runner), FinishTool()]
    }

    /// Specs rendered as the model sees them, one JSON object per line (for fingerprints and golden tests).
    public static func renderedSpecs(_ tools: [HarnessTool]) -> String {
        tools.map { $0.spec.json.serialized() }.joined(separator: "\n")
    }
}

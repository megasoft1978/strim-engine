import Testing
import Foundation
import CryptoKit
import StrimTemplate
@testable import StrimHarness

@Suite struct ToolCatalogTests {
    private func tools() -> [HarnessTool] {
        let runner = BashTool.makeRunner(workspaceRoot: "/tmp/x", access: .read, jobTmp: "/tmp/y")
        return ToolCatalog.all(runner: runner)
    }

    @Test func fixedOrder() {
        #expect(tools().map(\.name) == ["read_file", "list_files", "grep", "edit_file", "write_file", "bash", "finish"])
        #expect(tools().map(\.name) == ToolCatalog.names)
        // Spec name matches tool name.
        for t in tools() { #expect(t.spec.json["function"]?["name"]?.stringValue == t.name) }
    }

    @Test func descriptionsAreShort() {
        for t in tools() {
            let d = t.spec.json["function"]?["description"]?.stringValue ?? ""
            #expect(d.split(whereSeparator: \.isWhitespace).count <= 60, "\(t.name) description too long")
        }
    }

    @Test func specIsIndependentOfRunnerAndStable() {
        let a = ToolCatalog.renderedSpecs(tools())
        let other = BashTool.makeRunner(workspaceRoot: "/somewhere/else", access: .write, jobTmp: "/tmp/z")
        #expect(a == ToolCatalog.renderedSpecs(ToolCatalog.all(runner: other)))
        #expect(a == ToolCatalog.renderedSpecs(tools()))
    }

    /// Golden hash of the rendered tool JSON. The tool list is part of the prompt prefix; any change here
    /// invalidates the prefix cache for every job. Update this hash deliberately (and only then).
    /// Updated deliberately: `finish` gained `declined` and `reason` (early decline).
    static let goldenSHA256 = "d522ded721f53ec7d015fdedead3b62c2ce223991a307710c91884f237432138"

    @Test func goldenRenderedToolJSON() {
        let rendered = ToolCatalog.renderedSpecs(tools())
        let hash = SHA256.hash(data: Data(rendered.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(hash == Self.goldenSHA256, "tool JSON changed (new hash \(hash)); update goldenSHA256 deliberately\n\(rendered)")
    }

    @Test func bashSpecShape() {
        let spec = BashTool(runner: BashTool.makeRunner(workspaceRoot: "/tmp/x", access: .read, jobTmp: "/tmp/y")).spec.json.serialized()
        #expect(spec.contains("\"command\"") && spec.contains("\"timeout_s\"") && spec.contains("[exit code: N]"))
    }
}

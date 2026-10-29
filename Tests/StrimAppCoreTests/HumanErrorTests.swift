import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@Suite struct HumanErrorTests {
    @Test func apiErrorIsHumanNotSwiftDump() {
        let e: Error = APIError(code: "load_failed", message: "The model is still loading")
        #expect(e.localizedDescription == "The model is still loading. Try again in a moment.")
        #expect(!e.localizedDescription.contains("StrimAPI"))
        #expect(APIError(code: "max_sessions", message: "x").localizedDescription.hasPrefix("Too many chats"))
        #expect(APIError(code: "weird", message: "").localizedDescription.contains("weird"))
    }

    @Test func unreachableNamesHostAndFix() {
        let d = ControlClientError.hostUnreachable("127.0.0.1:8203").errorDescription
        #expect(d == "Strim server isn't responding on 127.0.0.1:8203. Start it from the menu bar.")
    }

    @Test func toolResultPreviewKeepsNewlinesAndTrims() {
        let ten = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let p = ToolResultPreview.split(ten)
        #expect(p.shown == (1...8).map { "line \($0)" }.joined(separator: "\n"))
        #expect(p.hidden == 2)
        let short = ToolResultPreview.split("a\n  b\nc\n\n")
        #expect(short.shown == "a\n  b\nc" && short.hidden == 0)
        #expect(ToolResultPreview.split(ten, maxLines: .max).hidden == 0)
    }

    @Test func fixtureDisplayMapShowsProjectsPath() {
        PathDisplay.displayMap = ("/tmp/strim-fx", "~/Projects")
        defer { PathDisplay.displayMap = nil }
        #expect(PathDisplay.tilde("/tmp/strim-fx/notes-app") == "~/Projects/notes-app")
    }
}

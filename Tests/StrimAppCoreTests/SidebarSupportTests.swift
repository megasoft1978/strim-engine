import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@MainActor
@Suite struct SidebarSupportTests {
    @Test func relativeTime() {
        #expect(RelativeTime.short(1000, now: 1030) == "now")
        #expect(RelativeTime.short(1000, now: 1000 + 240) == "4m")
        #expect(RelativeTime.short(1000, now: 1000 + 7300) == "2h")
        #expect(RelativeTime.short(1000, now: 1000 + 86_400 * 3) == "3d")
        #expect(RelativeTime.short(1000, now: 1000 + 86_400 * 15) == "2w")
        #expect(RelativeTime.short(2000, now: 1000) == "now")
    }

    @Test func pathDisplay() {
        #expect(PathDisplay.tilde("/Users/me/dev/app", home: "/Users/me") == "~/dev/app")
        #expect(PathDisplay.tilde("/Users/me", home: "/Users/me") == "~")
        #expect(PathDisplay.tilde("/Users/meow/x", home: "/Users/me") == "/Users/meow/x")
        let long = "/Users/me/" + String(repeating: "abcdefghij/", count: 8)
        let out = PathDisplay.tilde(long, home: "/Users/me", maxLength: 30)
        #expect(out.count == 30 && out.contains("…") && out.hasPrefix("~/") && out.hasSuffix("/"))
    }

    private func model(_ index: ChatIndex) -> AppModel {
        AppModel(client: FakeControlClient(), settings: AppSettings(), persist: { _ in }, pollInterval: nil,
                 modelDownloader: ModelDownloader(modelExists: { true }), chatStore: MemoryChatStore(index: index))
    }

    @Test func orderingAndAdjacency() {
        let a = ChatProject(id: "a", path: "/a", lastActivity: 10)
        let b = ChatProject(id: "b", path: "/b", lastActivity: 20)
        let s = ChatProject(id: "s", path: "/s", name: "Scratch", lastActivity: 99, isScratch: true)
        let t = [ChatThread(id: "a1", projectId: "a", lastActivity: 5), ChatThread(id: "a2", projectId: "a", lastActivity: 9),
                 ChatThread(id: "b1", projectId: "b", lastActivity: 1, unread: true), ChatThread(id: "s1", projectId: "s", lastActivity: 50)]
        let m = model(ChatIndex(projects: [a, s, b], threads: t))
        #expect(m.sidebarProjects.map(\.id) == ["b", "a", "s"])
        #expect(m.sidebarThreadOrder == ["b1", "a2", "a1", "s1"])
        #expect(m.adjacentThread(from: "b1", step: 1) == "a2")
        #expect(m.adjacentThread(from: "a1", step: -1) == "a2")
        #expect(m.adjacentThread(from: "b1", step: -1) == nil)
        #expect(m.adjacentThread(from: "s1", step: 1) == nil)
        #expect(m.adjacentThread(from: nil, step: 1) == "b1" && m.adjacentThread(from: nil, step: -1) == "s1")
        #expect(m.lastThreadID == "s1")
        m.selectThread("a1")
        #expect(m.lastThreadID == "a1")
        #expect(m.threadBadge("a2") == .none && m.threadBadge("b1") == .unread)
    }
}

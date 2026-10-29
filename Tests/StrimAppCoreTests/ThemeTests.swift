import Testing
import AppKit
import StrimAPI
@testable import StrimAppCore

@Suite struct ThemeTests {
    private func status(_ s: HostState, progress: Double? = nil) -> ConnectionState {
        .connected(HostStatus(state: s, loadProgress: progress, memory: MemoryStats(weightsGB: 1, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 1)))
    }

    @Test func orbStateMapsConnection() {
        #expect(OrbState(status(.ready)) == .running)
        #expect(OrbState(status(.busy)) == .busy)
        #expect(OrbState(status(.stopped)) == .stopped)
        #expect(OrbState(status(.error)) == .error)
        #expect(OrbState(status(.loading, progress: 0.4)) == .loading(0.4))
        #expect(OrbState(.disconnected(reason: "x")) == .offline)
        #expect(OrbState.running.isLive)
        #expect(!OrbState.stopped.isLive)
    }

    /// State is never colour alone: each state carries a distinct label and icon.
    @Test func everyStateHasADistinctWordAndIcon() {
        let all: [OrbState] = [.running, .busy, .loading(0.5), .stopped, .error, .offline]
        #expect(Set(all.map(\.word)).count == all.count)
        #expect(Set(all.map(\.icon)).count == all.count)
    }

    @Test func menuBarGlyphIsTemplate18pt() {
        for b in [MenuBarGlyph.Badge.none, .dot, .ring, .diamond] {
            let img = MenuBarGlyph.image(badge: b)
            #expect(img.isTemplate)
            #expect(img.size == NSSize(width: 18, height: 18))
        }
        #expect(MenuBarGlyph.badge(for: status(.ready)) == .dot)
        #expect(MenuBarGlyph.badge(for: status(.stopped)) == .ring)
        #expect(MenuBarGlyph.badge(for: status(.error)) == .diamond)
    }
}

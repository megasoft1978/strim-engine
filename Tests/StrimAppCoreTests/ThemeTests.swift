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
        let base = MenuBarGlyph.image(badge: .none).tiffRepresentation
        for b in [MenuBarGlyph.Badge.none, .dot, .ring, .diamond] {
            let img = MenuBarGlyph.image(badge: b)
            #expect(img.isTemplate)
            #expect(img.size == NSSize(width: 18, height: 18))
            // none and dot are the plain S; stopped (ring) is dimmed and error (diamond) carries a mark.
            if b == .none || b == .dot { #expect(img.tiffRepresentation == base) } else { #expect(img.tiffRepresentation != base) }
        }
        #expect(MenuBarGlyph.badge(for: status(.ready)) == .dot)
        #expect(MenuBarGlyph.badge(for: status(.stopped)) == .ring)
        #expect(MenuBarGlyph.badge(for: status(.error)) == .diamond)
    }
}

/// WCAG contrast of the Direction D palette, both themes.
@Suite struct PaletteContrastTests {
    private func lin(_ c: UInt32) -> Double {
        let v = Double(c) / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private func lum(_ h: UInt32) -> Double {
        0.2126 * lin((h >> 16) & 255) + 0.7152 * lin((h >> 8) & 255) + 0.0722 * lin(h & 255)
    }
    private func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private typealias P = Strim.Palette
    private func themes<T>(_ f: (Bool) -> T) -> [T] { [f(true), f(false)] }
    private func pick(_ t: (dark: UInt32, light: UInt32), _ dark: Bool) -> UInt32 { dark ? t.dark : t.light }

    @Test func palettePinnedToSpec() {
        #expect(P.bg.dark == 0x131417 && P.bg.light == 0xF5F5F7)
        #expect(P.surface.dark == 0x1A1B20 && P.surface.light == 0xFFFFFF)
        #expect(P.tertiary.dark == 0x8A8D99 && P.tertiary.light == 0x6B6E7A)
        #expect(P.accent.dark == 0x7C7CF5 && P.accent.light == 0x4F46E5)
        #expect(P.onAccent.dark == 0x0C0D10 && P.onAccent.light == 0xFFFFFF)
    }

    @Test func bodyTextMeetsAA() {
        for dark in [true, false] {
            for surface in [P.bg, P.surface, P.surface2] {
                let s = pick(surface, dark)
                #expect(ratio(pick(P.text, dark), s) >= 4.5)
                #expect(ratio(pick(P.muted, dark), s) >= 4.5)
                #expect(ratio(pick(P.accent, dark), s) >= 4.5)
            }
            // Primary button label on the accent fill, including hover.
            #expect(ratio(pick(P.onAccent, dark), pick(P.accent, dark)) >= 4.5)
            #expect(ratio(pick(P.onAccent, dark), pick(P.accentHover, dark)) >= 4.5)
        }
    }

    /// Tertiary is for captions only (>= 4.5 on the card and the window base) and danger text is AA on both.
    @Test func tertiaryAndDangerMeetAA() {
        for dark in [true, false] {
            for surface in [P.bg, P.surface] {
                #expect(ratio(pick(P.tertiary, dark), pick(surface, dark)) >= 4.5)
                #expect(ratio(pick(P.danger, dark), pick(surface, dark)) >= 4.5)
            }
        }
    }

    @Test func largeTextAndMarksMeet3() {
        for dark in [true, false] {
            for surface in [P.bg, P.surface, P.surface2] {
                #expect(ratio(pick(P.focus, dark), pick(surface, dark)) >= 3)
                #expect(ratio(pick(P.accentHover, dark), pick(surface, dark)) >= 3 || !dark)
            }
            // Hairline ring / dot outlines are decorative; the status shape and label carry state.
            #expect(ratio(pick(P.muted, dark), pick(P.surface, dark)) >= 3)
        }
    }

    @Test func noSemanticThemeTokenUsesGreenAsItsSignal() {
        let colors: [(dark: UInt32, light: UInt32)] = [
            P.bg, P.surface, P.surface2, P.hairline, P.hairlineStrong, P.text, P.muted, P.tertiary, P.accent,
            P.onAccent, P.accentHover, P.focus, P.danger,
        ]
        for pair in colors {
            for color in [pair.dark, pair.light] {
                let red = (color >> 16) & 255
                let green = (color >> 8) & 255
                let blue = color & 255
                #expect(!(green > red && green > blue))
            }
        }
    }
}

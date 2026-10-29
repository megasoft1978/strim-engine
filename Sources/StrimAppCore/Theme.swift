import SwiftUI
import AppKit
import StrimAPI

/// Design tokens of the Strim app, "Direction D: quiet modern" (shared with the website).
/// Neutral flat surfaces with 1 px hairlines, one indigo accent used only for the primary button, the active tab,
/// key numerals, gauge arcs, focus and the mark. No gradients, glows, glass or ambient motion.
/// Rules: no green anywhere, state is never colour alone (shape + word), text pairs meet WCAG AA (see ThemeTests),
/// fonts are semantic (Dynamic Type), mono for numbers.
public enum Strim {
    // MARK: colour

    static func ns(_ v: UInt32, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    /// Colour that resolves per appearance (SwiftUI and AppKit both honour it).
    static func dyn(dark: UInt32, light: UInt32, darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark, darkAlpha) : ns(light, lightAlpha)
        })
    }
    public static func hex(_ v: UInt32, _ a: Double = 1) -> Color { Color(nsColor: ns(v, a)) }

    /// Raw palette values (dark, light) so tests can check contrast without resolving dynamic colours.
    public enum Palette {
        public static let bg: (dark: UInt32, light: UInt32) = (0x131417, 0xF5F5F7)
        public static let surface: (dark: UInt32, light: UInt32) = (0x1A1B20, 0xFFFFFF)
        public static let surface2: (dark: UInt32, light: UInt32) = (0x22232A, 0xF0F1F4)
        public static let hairline: (dark: UInt32, light: UInt32) = (0x2C2E36, 0xE2E3E8)
        /// Increase Contrast variant of the hairline.
        public static let hairlineStrong: (dark: UInt32, light: UInt32) = (0x3A3C45, 0xC9CAD1)
        public static let text: (dark: UInt32, light: UInt32) = (0xECEDEF, 0x131419)
        public static let muted: (dark: UInt32, light: UInt32) = (0xA3A6B1, 0x595C68)
        /// Captions only.
        public static let tertiary: (dark: UInt32, light: UInt32) = (0x8A8D99, 0x6B6E7A)
        public static let accent: (dark: UInt32, light: UInt32) = (0x7C7CF5, 0x4F46E5)
        public static let onAccent: (dark: UInt32, light: UInt32) = (0x0C0D10, 0xFFFFFF)
        public static let accentHover: (dark: UInt32, light: UInt32) = (0x9393FF, 0x4338CA)
        public static let focus: (dark: UInt32, light: UInt32) = (0x9393FF, 0x4F46E5)
        /// App errors and destructive actions only.
        public static let danger: (dark: UInt32, light: UInt32) = (0xFF7A7A, 0xC62828)
    }

    public enum C {
        static func p(_ t: (dark: UInt32, light: UInt32), _ da: Double = 1, _ la: Double = 1) -> Color {
            dyn(dark: t.dark, light: t.light, darkAlpha: da, lightAlpha: la)
        }
        public static let bg = p(Palette.bg)
        /// Card surface.
        public static let panel = p(Palette.surface)
        public static let surface = panel
        public static let surface2 = p(Palette.surface2)
        public static let text = p(Palette.text)
        /// Secondary text (AA on bg, surface and surface2 in both themes).
        public static let muted = p(Palette.muted)
        /// Captions and chart legends only.
        public static let tertiary = p(Palette.tertiary)
        public static let hairline = Color(nsColor: NSColor(name: nil) { ap in
            let hc = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let dark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let t = hc ? Palette.hairlineStrong : Palette.hairline
            return ns(dark ? t.dark : t.light)
        })
        public static let field = surface2
        public static let track = hairline
        public static let accent = p(Palette.accent)
        public static let accentHover = p(Palette.accentHover)
        public static let focus = p(Palette.focus)
        public static let onAccent = p(Palette.onAccent)
        /// Errors and destructive actions (the only red in the app).
        public static let danger = p(Palette.danger)
    }

    // MARK: metrics

    public enum R { public static let card: CGFloat = 10, control: CGFloat = 6, tile: CGFloat = 10 }
    public enum S { public static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }

    // MARK: type

    public enum F {
        /// Details, labels and numbers: mono.
        public static func mono(_ style: Font.TextStyle = .caption, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .monospaced, weight: weight)
        }
        public static func label() -> Font { .system(.caption, design: .default, weight: .medium) }
    }
}

// MARK: - background, cards, labels

/// Flat window base. The main window uses the system window colour; `bg` is the token fallback for popovers and snapshots.
public struct StrimBackground: View {
    public init() {}
    public var body: some View { Strim.C.bg.ignoresSafeArea() }
}

public struct CardStyle: ViewModifier {
    var padding: CGFloat
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Strim.C.surface, in: RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
    }
}
public extension View {
    /// Flat card: surface fill plus a 1 px hairline, no shadow.
    func card(padding: CGFloat = Strim.S.lg) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Small muted label ("Engine", "Memory"), sentence case.
public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(Strim.F.label()).foregroundStyle(Strim.C.muted)
    }
}

// MARK: - pills

public enum PillTone { case neutral, accent, warn, error }

/// Small outlined tag: icon plus word, neutral unless it reports an error.
public struct StrimPill: View {
    let text: String
    var icon: String?
    var tone: PillTone
    public init(_ text: String, icon: String? = nil, tone: PillTone = .neutral) { self.text = text; self.icon = icon; self.tone = tone }
    public var body: some View {
        let fg: Color = tone == .error ? Strim.C.danger : Strim.C.muted
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
    }
}

// MARK: - buttons and toggle

public enum StrimButtonKind { case primary, secondary, danger }

public struct StrimButtonStyle: ButtonStyle {
    var kind: StrimButtonKind
    var large: Bool
    @Environment(\.isEnabled) private var enabled
    public init(_ kind: StrimButtonKind = .secondary, large: Bool = false) { self.kind = kind; self.large = large }
    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous)
        let label = configuration.label.font(.system(size: large ? 14 : 13, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, large ? 18 : 12).padding(.vertical, large ? 9 : 6)
        Group {
            switch kind {
            case .primary:
                label.foregroundStyle(Strim.C.onAccent).background(configuration.isPressed ? Strim.C.accentHover : Strim.C.accent, in: shape)
            case .secondary:
                label.foregroundStyle(Strim.C.text).background(Strim.C.surface2, in: shape)
                    .overlay(shape.strokeBorder(Strim.C.hairline, lineWidth: 1))
            case .danger:
                label.foregroundStyle(Strim.C.danger).background(Strim.C.surface2, in: shape)
                    .overlay(shape.strokeBorder(Strim.C.danger.opacity(0.45), lineWidth: 1))
            }
        }
        .opacity(enabled ? (configuration.isPressed && kind != .primary ? 0.8 : 1) : 0.4)
        .contentShape(shape)
    }
}

/// The paired-stream S (site Mark.swift, viewBox 64x64): two offset capsule strokes, 10 wide, round caps, ink x 12..52, y 9..55.
public struct StrimSPath: Shape {
    public static let strokeWidth: CGFloat = 10
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let r = 9.0, k = 0.5523 * r
        var p = Path()
        // upper stream: right to left, turning down to the middle bar
        p.move(to: CGPoint(x: 47, y: 14))
        p.addLine(to: CGPoint(x: 27, y: 14))
        p.addCurve(to: CGPoint(x: 27 - r, y: 23), control1: CGPoint(x: 27 - k, y: 14), control2: CGPoint(x: 27 - r, y: 23 - k))
        p.addCurve(to: CGPoint(x: 27, y: 32), control1: CGPoint(x: 27 - r, y: 23 + k), control2: CGPoint(x: 27 - k, y: 32))
        p.addLine(to: CGPoint(x: 34, y: 32))
        // lower stream: from the middle, turning down and out to the left
        p.move(to: CGPoint(x: 30, y: 32))
        p.addLine(to: CGPoint(x: 37, y: 32))
        p.addCurve(to: CGPoint(x: 37 + r, y: 41), control1: CGPoint(x: 37 + k, y: 32), control2: CGPoint(x: 37 + r, y: 41 - k))
        p.addCurve(to: CGPoint(x: 37, y: 50), control1: CGPoint(x: 37 + r, y: 41 + k), control2: CGPoint(x: 37 + k, y: 50))
        p.addLine(to: CGPoint(x: 17, y: 50))
        let s = min(rect.width, rect.height) / 64
        return p.applying(CGAffineTransform(scaleX: s, y: s))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}


/// App mark: near-black tile with the packaged accent paired-stream S (same viewBox bounds as the app icon). `size` is the tile edge.
public struct StrimMarkView: View {
    var size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous).fill(Strim.C.surface2)
            RoundedRectangle(cornerRadius: size * 0.2237 - 0.5, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1)
            StrimSPath()
                .stroke(Strim.C.accent, style: StrokeStyle(lineWidth: StrimSPath.strokeWidth * size / 64, lineCap: .round))
                .scaleEffect(0.49 * 64 / 46)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - the status indicator

public enum OrbState: Equatable, Sendable {
    case running, busy, loading(Double), stopped, error, offline

    public init(_ c: ConnectionState) {
        switch c {
        case .disconnected, .connecting: self = .offline
        case .connected(let s):
            switch s.state {
            case .ready: self = .running
            case .busy: self = .busy
            case .loading: self = .loading(s.loadProgress ?? 0)
            case .stopped: self = .stopped
            case .error: self = .error
            }
        }
    }
    public var isLive: Bool { self == .running || self == .busy }
    public var icon: String {
        switch self {
        case .running: "bolt.fill"
        case .busy: "waveform"
        case .loading: "hourglass"
        case .stopped: "stop.fill"
        case .error: "exclamationmark"
        case .offline: "bolt.slash.fill"
        }
    }
    /// Word shown next to the indicator: state is never colour alone.
    public var word: String {
        switch self {
        case .running: "Running"
        case .busy: "Generating"
        case .loading(let p): "Loading \(StatsFormat.percent(p))"
        case .stopped: "Stopped"
        case .error: "Error"
        case .offline: "Offline"
        }
    }
}

// MARK: - menu bar glyph

/// Pure-alpha template image of the paired-stream S mark at 18 pt. Connection state is exposed separately by badge(for:).
public enum MenuBarGlyph {
    public enum Badge: Equatable, Sendable { case none, dot, ring, diamond }

    public static func badge(for c: ConnectionState) -> Badge {
        switch c {
        case .disconnected: return .ring
        case .connecting: return .none
        case .connected(let s):
            switch s.state {
            case .ready, .busy: return .dot
            case .stopped, .loading: return .ring
            case .error: return .diamond
            }
        }
    }

    public static func image(badge: Badge = .none, points: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Scale the mark to 84% of the 18 pt glyph box, centred with balanced optical padding.
            let s = points * 0.84 / 56
            let ox = points / 2 - 32 * s, oy = points / 2 - 32 * s
            let sp = StrimSPath().path(in: CGRect(x: 0, y: 0, width: 64, height: 64))
            var t = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
            guard let cg = sp.cgPath.copy(using: &t) else { return false }
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(badge == .ring ? 0.5 : 1).cgColor)
            ctx.setLineWidth(StrimSPath.strokeWidth * s); ctx.setLineCap(.round)
            ctx.addPath(cg); ctx.strokePath()
            if badge == .diamond {
                // Error: knock a 7 pt diamond out of the bottom-right of the S, then fill a 5 pt diamond in the gap.
                func diamond(_ w: CGFloat) -> CGPath {
                    let k = w / 2 * points / 18, cx = points - 4.5 * points / 18, cy = points - 4.5 * points / 18
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: cx, y: cy - k)); p.addLine(to: CGPoint(x: cx + k, y: cy))
                    p.addLine(to: CGPoint(x: cx, y: cy + k)); p.addLine(to: CGPoint(x: cx - k, y: cy)); p.closeSubpath()
                    return p
                }
                ctx.saveGState(); ctx.setBlendMode(.clear); ctx.addPath(diamond(8)); ctx.fillPath(); ctx.restoreGState()
                ctx.setFillColor(NSColor.black.cgColor); ctx.addPath(diamond(5.5)); ctx.fillPath()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Strim"
        return img
    }
}

public extension View {
    /// Filled capsule with a hairline, drawn as one background so no stroke fragments appear at the ends.
    func capsuleSurface<F: ShapeStyle, S: ShapeStyle>(_ fill: F, stroke: S, lineWidth: CGFloat = 1) -> some View {
        background { Stadium().fill(fill).overlay(Stadium().strokeBorder(stroke, lineWidth: lineWidth)) }
    }
}

/// Stadium (fully rounded) shape built from a rounded rectangle; avoids end-cap stroke fragments seen with `Capsule`
/// in offscreen AppKit renders.
public struct Stadium: InsettableShape {
    var amount: CGFloat = 0
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: amount, dy: amount)
        return RoundedRectangle(cornerRadius: min(r.width, r.height) / 2, style: .circular).path(in: r)
    }
    public func inset(by a: CGFloat) -> Stadium { var s = self; s.amount += a; return s }
}

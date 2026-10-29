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
        public static let bg: (dark: UInt32, light: UInt32) = (0x0C0D10, 0xFAFAFB)
        public static let surface: (dark: UInt32, light: UInt32) = (0x14151A, 0xFFFFFF)
        public static let surface2: (dark: UInt32, light: UInt32) = (0x1B1C22, 0xF1F2F5)
        public static let hairline: (dark: UInt32, light: UInt32) = (0x2A2C34, 0xE1E3E8)
        public static let text: (dark: UInt32, light: UInt32) = (0xECEDEF, 0x131419)
        public static let muted: (dark: UInt32, light: UInt32) = (0xA3A6B1, 0x595C68)
        public static let accent: (dark: UInt32, light: UInt32) = (0x7C7CF5, 0x4F46E5)
        public static let onAccent: (dark: UInt32, light: UInt32) = (0x0C0D10, 0xFFFFFF)
        public static let accentHover: (dark: UInt32, light: UInt32) = (0x9393FF, 0x4338CA)
        public static let focus: (dark: UInt32, light: UInt32) = (0x9393FF, 0x4F46E5)
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
        public static let hairline = p(Palette.hairline)
        /// Flat card fill (was the glass fill).
        public static let glass = surface
        /// Raised / selected fill.
        public static let glassStrong = surface2
        public static let field = surface2
        public static let track = hairline
        public static let accent = p(Palette.accent)
        public static let accentHover = p(Palette.accentHover)
        public static let focus = p(Palette.focus)
        public static let onAccent = p(Palette.onAccent)
        public static let indigo = accent
        /// Accent for small text and icons on the base (AA on both).
        public static let accentText = accent
        /// Errors, warnings and destructive actions stay neutral; their icon and label carry state.
        public static let coral = muted
        public static let coralFill = surface2
        public static let amber = muted
        public static let amberFill = surface2
        /// Flat backing for selected or informational content.
        public static let accentFill = surface2
    }

    // MARK: metrics

    public enum R { public static let card: CGFloat = 12, control: CGFloat = 8, tile: CGFloat = 10 }
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

public struct GlassCard: ViewModifier {
    var padding: CGFloat
    var strong: Bool
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(strong ? Strim.C.surface2 : Strim.C.surface, in: RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
    }
}
public extension View {
    /// Flat card: surface fill plus a 1 px hairline.
    func glassCard(padding: CGFloat = Strim.S.lg, strong: Bool = false) -> some View { modifier(GlassCard(padding: padding, strong: strong)) }
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

public struct StrimPill: View {
    let text: String
    var icon: String?
    var tone: PillTone
    public init(_ text: String, icon: String? = nil, tone: PillTone = .neutral) { self.text = text; self.icon = icon; self.tone = tone }
    public var body: some View {
        let (fg, bg): (Color, Color) = switch tone {
        case .neutral: (Strim.C.muted, Strim.C.surface2)
        case .accent: (Strim.C.accentText, Strim.C.accentFill)
        case .warn: (Strim.C.amber, Strim.C.amberFill)
        case .error: (Strim.C.coral, Strim.C.coralFill)
        }
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(Strim.F.mono(.caption2, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(bg, in: Stadium())
        .overlay(Stadium().strokeBorder(Strim.C.hairline, lineWidth: 1))
    }
}

// MARK: - buttons and toggle

public enum StrimButtonKind { case primary, secondary, danger }

public struct StrimButtonStyle: ButtonStyle {
    var kind: StrimButtonKind
    @Environment(\.isEnabled) private var enabled
    public init(_ kind: StrimButtonKind = .secondary) { self.kind = kind }
    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous)
        let label = configuration.label.font(.callout.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 7)
        Group {
            switch kind {
            case .primary:
                label.foregroundStyle(Strim.C.onAccent).background(configuration.isPressed ? Strim.C.accentHover : Strim.C.accent, in: shape)
            case .secondary:
                label.foregroundStyle(Strim.C.text).background(Strim.C.surface2, in: shape)
                    .overlay(shape.strokeBorder(Strim.C.hairline, lineWidth: 1))
            case .danger:
                label.foregroundStyle(Strim.C.coral).background(Strim.C.coralFill, in: shape)
                    .overlay(shape.strokeBorder(Strim.C.coral.opacity(0.4), lineWidth: 1))
            }
        }
        .opacity(enabled ? (configuration.isPressed && kind != .primary ? 0.8 : 1) : 0.4)
        .contentShape(shape)
    }
}

/// Capsule switch. State is conveyed by the knob side and the check / minus icon as well as the fill.
public struct StrimToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label.font(.callout.weight(.medium)).foregroundStyle(Strim.C.text)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Stadium().fill(configuration.isOn ? Strim.C.accent : Strim.C.surface2)
                        .overlay(Stadium().strokeBorder(Strim.C.hairline, lineWidth: 1))
                    Circle().fill(configuration.isOn ? Strim.C.onAccent : Strim.C.muted).padding(2.5)
                        .overlay(Image(systemName: configuration.isOn ? "checkmark" : "minus").font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(configuration.isOn ? Strim.C.accent : Strim.C.surface))
                }
                .frame(width: 36, height: 20)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// The S of four token capsules (logo-c.svg, viewBox 64x64): one S path, stroked with a dash pattern and round caps.
public struct StrimSPath: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let k = 0.5523 * 8.5, r = 8.5
        var p = Path()
        p.move(to: CGPoint(x: 46, y: 19))
        p.addLine(to: CGPoint(x: 28, y: 19))
        p.addCurve(to: CGPoint(x: 28 - r, y: 27.5), control1: CGPoint(x: 28 - k, y: 19), control2: CGPoint(x: 28 - r, y: 27.5 - k))
        p.addCurve(to: CGPoint(x: 28, y: 36), control1: CGPoint(x: 28 - r, y: 27.5 + k), control2: CGPoint(x: 28 - k, y: 36))
        p.addLine(to: CGPoint(x: 36, y: 36))
        p.addCurve(to: CGPoint(x: 36 + r, y: 44.5), control1: CGPoint(x: 36 + k, y: 36), control2: CGPoint(x: 36 + r, y: 44.5 - k))
        p.addCurve(to: CGPoint(x: 36, y: 53), control1: CGPoint(x: 36 + r, y: 44.5 + k), control2: CGPoint(x: 36 + k, y: 53))
        p.addLine(to: CGPoint(x: 17, y: 53))
        let s = min(rect.width, rect.height) / 64
        return p.applying(CGAffineTransform(scaleX: s, y: s).translatedBy(x: 0, y: 0))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}


/// App mark: flat indigo tile, four capsules in two tints (viewBox 64x64). `size` is the tile edge.
public struct StrimMarkView: View {
    var size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }
    private func dash(_ phase: CGFloat) -> StrokeStyle {
        let s = size / 64
        return StrokeStyle(lineWidth: 8.5 * s, lineCap: .round, dash: [14.5 * s, 36.5 * s], dashPhase: phase * s)
    }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Strim.C.surface2)
            RoundedRectangle(cornerRadius: size * 0.25 - 0.5, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1)
            StrimSPath().stroke(Strim.C.accent, style: dash(-1))
            StrimSPath().stroke(Strim.C.accentHover, style: dash(-1 - 25.5))
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

/// Flat status dot inside a thin ring. Shape carries the state: filled dot (running), dot + waveform (generating),
/// progress arc (loading), square (stopped), exclamation (error), dashed ring (offline). No glow, no animation.
public struct StrimOrb: View {
    let state: OrbState
    var size: CGFloat
    public init(_ state: OrbState, size: CGFloat = 88) { self.state = state; self.size = size }

    public var body: some View {
        let ring = max(1.5, size * 0.04)
        ZStack {
            switch state {
            case .running, .busy:
                Circle().strokeBorder(Strim.C.accent, lineWidth: ring)
                Circle().fill(Strim.C.accent).padding(size * 0.2)
                Image(systemName: state.icon).font(.system(size: size * 0.26, weight: .bold)).foregroundStyle(Strim.C.onAccent)
            case .loading(let p):
                Circle().strokeBorder(Strim.C.hairline, lineWidth: ring)
                Circle().trim(from: 0, to: max(0.04, p)).stroke(Strim.C.accent, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(ring / 2)
                Image(systemName: state.icon).font(.system(size: size * 0.30, weight: .semibold)).foregroundStyle(Strim.C.muted)
            case .stopped:
                Circle().strokeBorder(Strim.C.muted, lineWidth: ring)
                RoundedRectangle(cornerRadius: size * 0.04, style: .continuous).fill(Strim.C.muted).frame(width: size * 0.26, height: size * 0.26)
            case .error:
                Circle().strokeBorder(Strim.C.coral, lineWidth: ring)
                Circle().fill(Strim.C.coralFill).padding(size * 0.12)
                Image(systemName: state.icon).font(.system(size: size * 0.40, weight: .heavy)).foregroundStyle(Strim.C.coral)
            case .offline:
                Circle().strokeBorder(Strim.C.muted, style: StrokeStyle(lineWidth: ring, dash: [3, 3]))
                Image(systemName: state.icon).font(.system(size: size * 0.30, weight: .semibold)).foregroundStyle(Strim.C.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Engine \(state.word)")
    }
}

// MARK: - menu bar glyph

/// Monochrome template image of the S capsule mark, 18 pt, optionally with a small state shape in the corner
/// (filled dot = running, ring = stopped or loading, diamond = error). A cut-out keeps the shape legible over the S.
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
            // logo-c viewBox crop x 11..55, y 12..60, scaled into the left/top of the image so the badge has room.
            let s = points * 0.84 / 48
            let ox = -11 * s + points * 0.02, oy = -12 * s + points * 0.04
            let sp = StrimSPath().path(in: CGRect(x: 0, y: 0, width: 64, height: 64))
            var t = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
            guard let cg = sp.cgPath.copy(using: &t) else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(8.5 * s); ctx.setLineCap(.round)
            ctx.setLineDash(phase: -1 * s, lengths: [14.5 * s, 11 * s])
            ctx.addPath(cg); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if badge != .none {
                let c = CGPoint(x: points - 3.6, y: points - 3.6), r: CGFloat = 3.1
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: c.x - r - 1.3, y: c.y - r - 1.3, width: 2 * (r + 1.3), height: 2 * (r + 1.3)))
                ctx.restoreGState()
                ctx.setFillColor(NSColor.black.cgColor); ctx.setStrokeColor(NSColor.black.cgColor)
                switch badge {
                case .dot: ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                case .ring:
                    ctx.setLineWidth(1.3)
                    ctx.strokeEllipse(in: CGRect(x: c.x - r + 0.65, y: c.y - r + 0.65, width: 2 * r - 1.3, height: 2 * r - 1.3))
                case .diamond:
                    ctx.move(to: CGPoint(x: c.x, y: c.y - r - 0.4)); ctx.addLine(to: CGPoint(x: c.x + r + 0.4, y: c.y))
                    ctx.addLine(to: CGPoint(x: c.x, y: c.y + r + 0.4)); ctx.addLine(to: CGPoint(x: c.x - r - 0.4, y: c.y))
                    ctx.closePath(); ctx.fillPath()
                case .none: break
                }
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

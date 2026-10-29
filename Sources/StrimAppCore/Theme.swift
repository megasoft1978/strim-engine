import SwiftUI
import AppKit
import StrimAPI

/// Design tokens of the Strim app, shared with the website's "Aurora glass" direction (docs/design/index-c.html):
/// night #0A0920, text #F1EFFF, gradient #6E6BFF -> #B25CFF -> #FF4FD0, light base #F6F4FF, glass cards, mono details.
/// Rules: no green anywhere (running/ok is the blue-violet gradient plus an icon and a word, errors are warm coral),
/// state is never colour alone, text pairs meet WCAG AA, fonts are semantic (Dynamic Type), motion honours Reduce Motion.
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

    public enum C {
        public static let bg = dyn(dark: 0x0A0920, light: 0xF6F4FF)
        public static let panel = dyn(dark: 0x12102E, light: 0xFFFFFF)
        public static let text = dyn(dark: 0xF1EFFF, light: 0x15123A)
        /// Secondary text. 7.9:1 on night, 6.4:1 on the light base.
        public static let muted = dyn(dark: 0xA9A6CF, light: 0x56538A)
        public static let hairline = dyn(dark: 0xFFFFFF, light: 0x15123A, darkAlpha: 0.13, lightAlpha: 0.11)
        public static let glass = dyn(dark: 0xFFFFFF, light: 0xFFFFFF, darkAlpha: 0.055, lightAlpha: 0.72)
        public static let glassStrong = dyn(dark: 0xFFFFFF, light: 0xFFFFFF, darkAlpha: 0.10, lightAlpha: 0.92)
        public static let field = dyn(dark: 0x000000, light: 0x15123A, darkAlpha: 0.28, lightAlpha: 0.05)
        public static let track = dyn(dark: 0xFFFFFF, light: 0x15123A, darkAlpha: 0.10, lightAlpha: 0.10)
        public static let indigo = dyn(dark: 0x6E6BFF, light: 0x4F4BFF)
        public static let violet = dyn(dark: 0xB25CFF, light: 0x9240FF)
        public static let pink = dyn(dark: 0xFF4FD0, light: 0xE0309E)
        /// Accent for small text and icons on the base (AA on both).
        public static let accentText = dyn(dark: 0xB4B2FF, light: 0x4339E0)
        /// Errors and destructive actions: warm coral, never red-green ambiguity.
        public static let coral = dyn(dark: 0xFF8577, light: 0xB8321F)
        public static let coralFill = dyn(dark: 0xFF6B5A, light: 0xD9442F, darkAlpha: 0.16, lightAlpha: 0.10)
        /// Warnings (paused, estimate): amber.
        public static let amber = dyn(dark: 0xFFC27A, light: 0x8F4A00)
        public static let amberFill = dyn(dark: 0xFFB259, light: 0xD98A1F, darkAlpha: 0.16, lightAlpha: 0.14)
        /// Darker stops so white button text keeps >= 4.5:1.
        public static let ctaA = hex(0x4640F0), ctaB = hex(0x8A38E6), ctaC = hex(0xB8309E)
    }

    public static let gradient = LinearGradient(colors: [C.indigo, C.violet, C.pink], startPoint: .leading, endPoint: .trailing)
    public static let gradientDiagonal = LinearGradient(colors: [C.indigo, C.violet, C.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let ctaGradient = LinearGradient(colors: [C.ctaA, C.ctaB, C.ctaC], startPoint: .leading, endPoint: .trailing)

    // MARK: metrics

    public enum R { public static let card: CGFloat = 16, control: CGFloat = 10, tile: CGFloat = 12 }
    public enum S { public static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }

    // MARK: type

    public enum F {
        /// Details, labels and numbers: mono.
        public static func mono(_ style: Font.TextStyle = .caption, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .monospaced, weight: weight)
        }
        public static func label() -> Font { .system(.caption2, design: .monospaced, weight: .semibold) }
    }
}

// MARK: - background, cards, labels

/// Night or light base with two soft aurora glows (indigo top-left, magenta top-right), like the site hero.
public struct StrimBackground: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View {
        ZStack {
            Strim.C.bg
            RadialGradient(colors: [Strim.C.indigo.opacity(scheme == .dark ? 0.34 : 0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Strim.C.pink.opacity(scheme == .dark ? 0.20 : 0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

public struct GlassCard: ViewModifier {
    var padding: CGFloat
    var strong: Bool
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(strong ? Strim.C.glassStrong : Strim.C.glass, in: RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
    }
}
public extension View {
    func glassCard(padding: CGFloat = Strim.S.lg, strong: Bool = false) -> some View { modifier(GlassCard(padding: padding, strong: strong)) }
}

/// Small mono uppercase label ("ENGINE", "MEMORY") as on the site.
public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased()).font(Strim.F.label()).tracking(1.2).foregroundStyle(Strim.C.muted)
    }
}

/// Gradient-filled text (large numerals and headlines only; small text uses `accentText`).
public extension View {
    func gradientFill() -> some View { overlay(Strim.gradient).mask(self) }
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
        case .neutral: (Strim.C.muted, Strim.C.track)
        case .accent: (Strim.C.accentText, Strim.C.indigo.opacity(0.16))
        case .warn: (Strim.C.amber, Strim.C.amberFill)
        case .error: (Strim.C.coral, Strim.C.coralFill)
        }
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(Strim.F.mono(.caption2, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(bg, in: Stadium())
        .overlay(Stadium().strokeBorder(fg.opacity(0.28), lineWidth: 0.75))
    }
}

// MARK: - buttons and toggle

public enum StrimButtonKind { case primary, secondary, danger }

public struct StrimButtonStyle: ButtonStyle {
    var kind: StrimButtonKind
    @Environment(\.isEnabled) private var enabled
    public init(_ kind: StrimButtonKind = .secondary) { self.kind = kind }
    public func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label.font(.callout.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 7)
        Group {
            switch kind {
            case .primary:
                label.foregroundStyle(.white).background(Strim.ctaGradient, in: Stadium())
                    .shadow(color: Strim.C.violet.opacity(enabled ? 0.45 : 0), radius: 10, y: 3)
            case .secondary:
                label.foregroundStyle(Strim.C.text).background(Strim.C.glassStrong, in: Stadium())
                    .overlay(Stadium().strokeBorder(Strim.C.hairline, lineWidth: 1))
            case .danger:
                label.foregroundStyle(Strim.C.coral).background(Strim.C.coralFill, in: Stadium())
                    .overlay(Stadium().strokeBorder(Strim.C.coral.opacity(0.4), lineWidth: 1))
            }
        }
        .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        .contentShape(Stadium())
    }
}

/// Capsule switch. Label text carries the state too ("On"/"Off" is conveyed by the knob side and the check icon).
public struct StrimToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label.font(.callout.weight(.medium)).foregroundStyle(Strim.C.text)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Stadium().fill(configuration.isOn ? AnyShapeStyle(Strim.ctaGradient) : AnyShapeStyle(Strim.C.track))
                        .overlay(Stadium().strokeBorder(Strim.C.hairline, lineWidth: 1))
                    Circle().fill(.white).padding(2.5)
                        .overlay(Image(systemName: configuration.isOn ? "checkmark" : "minus").font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(configuration.isOn ? Strim.C.ctaA : Strim.hex(0x56538A)))
                }
                .frame(width: 36, height: 20)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

// MARK: - the mark

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

/// App mark on its navy tile, with the glow. `size` is the tile edge.
public struct StrimMarkView: View {
    var size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }
    public var body: some View {
        let s = size / 64
        let dash = StrokeStyle(lineWidth: 8.5 * s, lineCap: .round, dash: [14.5 * s, 11 * s], dashPhase: -1 * s)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [Strim.hex(0x2A2470), Strim.hex(0x120F33)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.25 - 0.5, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1)
            StrimSPath().stroke(Strim.gradientDiagonal, style: dash).blur(radius: 2.2 * s).opacity(0.7)
            StrimSPath().stroke(Strim.gradientDiagonal, style: dash)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - the status orb

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
    /// Word shown next to the orb: state is never colour alone.
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

/// Glows with the gradient while the engine is running (slow pulse; static under Reduce Motion), a quiet ring otherwise.
public struct StrimOrb: View {
    let state: OrbState
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    public init(_ state: OrbState, size: CGFloat = 88) { self.state = state; self.size = size }

    public var body: some View {
        ZStack {
            switch state {
            case .running, .busy:
                Circle().fill(Strim.gradientDiagonal).blur(radius: size * 0.30).opacity(pulse ? 0.85 : 0.55).scaleEffect(1.25)
                Circle().strokeBorder(Strim.gradientDiagonal, lineWidth: 1.5).scaleEffect(pulse ? 1.32 : 1.12).opacity(pulse ? 0 : 0.6)
                Circle().fill(AngularGradient(colors: [Strim.C.indigo, Strim.C.violet, Strim.C.pink, Strim.C.violet, Strim.C.indigo], center: .center, angle: .degrees(-40)))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: UnitPoint(x: 0.34, y: 0.26), startRadius: 0, endRadius: size * 0.55))
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                Image(systemName: state.icon).font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.white)
            case .loading(let p):
                Circle().strokeBorder(Strim.C.track, lineWidth: size * 0.07)
                Circle().trim(from: 0, to: max(0.04, p)).stroke(Strim.gradientDiagonal, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(size * 0.035)
                Image(systemName: state.icon).font(.system(size: size * 0.30, weight: .semibold)).foregroundStyle(Strim.C.accentText)
            case .stopped:
                Circle().fill(Strim.C.glass)
                Circle().strokeBorder(Strim.C.hairline.opacity(1.8), lineWidth: 1.5)
                Image(systemName: state.icon).font(.system(size: size * 0.28, weight: .bold)).foregroundStyle(Strim.C.muted)
            case .error:
                Circle().fill(Strim.C.coralFill)
                Circle().strokeBorder(Strim.C.coral, lineWidth: 2)
                Image(systemName: state.icon).font(.system(size: size * 0.40, weight: .heavy)).foregroundStyle(Strim.C.coral)
            case .offline:
                Circle().fill(Strim.C.glass)
                Circle().strokeBorder(Strim.C.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                Image(systemName: state.icon).font(.system(size: size * 0.30, weight: .semibold)).foregroundStyle(Strim.C.muted)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard state.isLive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { pulse = true }
        }
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

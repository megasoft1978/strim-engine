import SwiftUI
import StrimAPI
import StrimAppCore

private struct LayoutClassKey: EnvironmentKey { static let defaultValue: LayoutClass = .regular }
extension EnvironmentValues {
    /// Width class of the detail column (compact < 760 pt, wide >= 1200 pt). Set by `MainWindow`.
    var layoutClass: LayoutClass {
        get { self[LayoutClassKey.self] }
        set { self[LayoutClassKey.self] = newValue }
    }
}

/// Dismissible neutral banners above the page content.
struct TokenWarningView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let w = model.tokenWarning {
            Label(w, systemImage: "key.slash").font(.system(size: 12)).foregroundStyle(Strim.C.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(Strim.S.md).frame(maxWidth: .infinity, alignment: .leading).card(padding: 0)
        }
    }
}

struct NoticeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let n = model.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Strim.C.muted)
                Text(n).font(.system(size: 12)).foregroundStyle(Strim.C.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { model.dismissNotice() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Strim.C.muted).help("Dismiss").accessibilityLabel("Dismiss notice")
            }
            .padding(Strim.S.md).card(padding: 0)
        }
    }
}

/// One-line reason for an offline host (first line, no doubled periods).
enum OfflineReason {
    static func oneLine(_ reason: String, hostURL: String? = nil) -> String {
        let first = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        var s = first.trimmingCharacters(in: .whitespaces)
        if s.contains("not running at") || s.contains("Could not connect to the server") {
            s = hostURL.map { "Could not connect to \($0)" } ?? "Could not connect to the host"
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

extension AppModel {
    /// The server process is up and a model is (being) served.
    var serverIsUp: Bool { connection.isConnected && status?.state != .stopped }
    /// "qwen38-4bit" style short name of the model being served or selected.
    var modelShortName: String {
        let raw = status?.model ?? settings.modelPath.map { ($0 as NSString).lastPathComponent } ?? "qwen38-4bit"
        return raw
    }
    var modelLabel: String { status?.mtp != nil ? modelShortName + " + MTP" : modelShortName }
    var modelWeightsText: String { ModelDisk.gb(ModelDownloader.modelBytes) }
    var endpointURL: String { settings.hostURL.hasSuffix("/") ? settings.hostURL + "v1" : settings.hostURL + "/v1" }
}

/// Start / Stop server. One control for the toolbar, the popover and the Status page.
struct ServerToggleButton: View {
    @ObservedObject var model: AppModel
    var large = false
    var fullWidth = false
    var toolbar = false
    /// Toolbar at compact widths: play / stop glyph only (the help text keeps the full description).
    var iconOnly = false
    @State private var confirmStop = false
    var body: some View {
        let up = model.serverIsUp
        Button {
            if up {
                if (model.status?.activeJobs ?? 0) > 0 { confirmStop = true } else { Task { await model.stopServer() } }
            } else { Task { await model.startServer() } }
        } label: {
            if iconOnly {
                Image(systemName: up ? "stop.fill" : "play.fill")
            } else {
                Text(up ? "Stop server" : "Start server")
                    .lineLimit(1).fixedSize(horizontal: !fullWidth, vertical: false)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
            }
        }
        .buttonStyle(StrimButtonStyle(up || toolbar ? .secondary : .primary, large: large))
        .disabled(!(up ? model.serverStopAvailability : model.serverStartAvailability).enabled)
        .accessibilityLabel(up ? "Stop server" : "Start server")
        .help(up ? "Frees about \(model.modelWeightsText) of memory" : (model.serverStartAvailability.reason ?? "Start the Strim server"))
        .confirmationDialog("Stop the Strim server?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop server", role: .destructive) { Task { await model.stopServer() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Active jobs will be interrupted.") }
    }
}

/// Segmented memory bar: weights (accent), prefix trie (accent 55%), MLX cache (tertiary grey), headroom as the track.
struct MemoryBar: View {
    let memory: MemoryStats
    var height: CGFloat = 8
    var showLegend = true
    private var fills: [AnyShapeStyle] {
        [AnyShapeStyle(Strim.C.accent), AnyShapeStyle(Strim.C.accent.opacity(0.55)), AnyShapeStyle(Strim.C.tertiary.opacity(0.7)), AnyShapeStyle(Strim.C.hairline)]
    }
    private func legendItem(_ i: Int, _ s: StatsFormat.MemorySegment) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(fills[i % fills.count]).frame(width: 8, height: 8)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Strim.C.hairline, lineWidth: 0.5))
            Text("\(s.label) \(StatsFormat.gb(s.gb))").font(.system(size: 11)).foregroundStyle(Strim.C.muted).lineLimit(1)
        }
        .fixedSize()
    }
    var body: some View {
        let segs = StatsFormat.memorySegments(memory)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                        Rectangle().fill(fills[i % fills.count]).frame(width: max(0, (geo.size.width - 6) * s.fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            }.frame(height: height)
            if showLegend {
                let shown = Array(segs.enumerated()).filter { $0.element.gb >= 0.05 }
                // One line when it fits, otherwise two columns.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        ForEach(shown, id: \.offset) { i, s in legendItem(i, s) }
                        Spacer(minLength: 0)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { r in
                            GridRow {
                                legendItem(shown[r].offset, shown[r].element)
                                if r + 1 < shown.count { legendItem(shown[r + 1].offset, shown[r + 1].element) } else { Color.clear.frame(width: 0, height: 0) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory: " + segs.map { "\($0.label) \(StatsFormat.gb($0.gb))" }.joined(separator: ", "))
    }
}

/// Decode tok/s over the last minute: one 1.5 pt accent line, no fill.
struct Sparkline: View {
    let samples: [Double]
    var color: Color = Strim.C.accent
    var body: some View {
        GeometryReader { geo in
            let hi = max(samples.max() ?? 1, 1), n = samples.count
            Path { p in
                for (i, v) in samples.enumerated() {
                    let x = n > 1 ? geo.size.width * CGFloat(i) / CGFloat(n - 1) : 0
                    let y = geo.size.height - geo.size.height * CGFloat(v / hi) * 0.92 - 2
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Decode speed over the last minute")
        .accessibilityValue(samples.last.map { "\(Int($0.rounded())) tokens per second now" } ?? "no data")
    }
}

/// Label / value row of the engine card (24 pt).
struct KeyValueRow: View {
    let label: String, value: String
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Strim.C.muted).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Strim.C.text).lineLimit(1).truncationMode(.middle)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }
}

struct VerifyBadge: View {
    let verify: VerifyResult?
    var body: some View {
        switch verify {
        case .verified: Label("Verified", systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(Strim.C.muted)
        case .failed: Label("Verify failed", systemImage: "xmark.seal").font(.system(size: 11)).foregroundStyle(Strim.C.danger)
        case .unverified: Label("Unverified", systemImage: "questionmark.circle").font(.system(size: 11)).foregroundStyle(Strim.C.muted)
        case nil: EmptyView()
        }
    }
}

struct Badge: View {
    let text: String
    var tone: PillTone = .neutral
    var body: some View { StrimPill(text, tone: tone) }
}

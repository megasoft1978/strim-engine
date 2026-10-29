import SwiftUI
import StrimAPI
import StrimAppCore

struct OfflineBannerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let reason = model.offlineBanner {
            VStack(alignment: .leading, spacing: 8) {
                Label("Engine offline", systemImage: "bolt.slash.fill").font(.headline).foregroundStyle(Strim.C.coral)
                Text(reason).font(.callout).foregroundStyle(Strim.C.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Start host") { model.startHost() }.buttonStyle(StrimButtonStyle(.primary))
                    Button("Retry now") { model.reconnectNow() }.buttonStyle(StrimButtonStyle(.secondary))
                }
                if model.reconnectAttempts > 0 {
                    Text("reconnect attempts: \(model.reconnectAttempts)").font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Strim.S.lg)
            .background(Strim.C.coralFill, in: RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous).strokeBorder(Strim.C.coral.opacity(0.35), lineWidth: 1))
        } else if case .connecting = model.connection {
            Label("Connecting to \(model.settings.hostURL)...", systemImage: "arrow.triangle.2.circlepath")
                .font(Strim.F.mono(.callout)).foregroundStyle(Strim.C.muted)
        }
    }
}

struct TokenWarningView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let w = model.tokenWarning {
            Label(w, systemImage: "key.slash").font(.caption).foregroundStyle(Strim.C.amber)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(Strim.S.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(Strim.C.amberFill, in: RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous))
        }
    }
}

struct NoticeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let n = model.notice {
            HStack(alignment: .top) {
                Image(systemName: "info.circle.fill").foregroundStyle(Strim.C.accentText)
                Text(n).font(.caption).foregroundStyle(Strim.C.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                Button { model.dismissNotice() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Strim.C.muted).help("Dismiss").accessibilityLabel("Dismiss notice")
            }
            .padding(Strim.S.md)
            .background(Strim.C.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous).strokeBorder(Strim.C.indigo.opacity(0.3), lineWidth: 1))
        }
    }
}

/// Label / value row; values are mono.
struct StatRow: View {
    let label: String, value: String
    var note: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.callout).foregroundStyle(Strim.C.muted)
            if let note { StrimPill(note, tone: .warn) }
            Spacer(minLength: 8)
            Text(value).font(Strim.F.mono(.callout, weight: .medium)).foregroundStyle(Strim.C.text)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
    }
}

/// Value tile: mono numeral, optional unit, small label. Used for the Status grid.
struct MetricTile: View {
    let label: String, value: String
    var unit: String? = nil
    var note: String? = nil
    var ring: Double? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let ring {
                ZStack {
                    Circle().stroke(Strim.C.track, lineWidth: 5)
                    Circle().trim(from: 0, to: max(0.01, min(1, ring))).stroke(Strim.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                }.frame(width: 36, height: 36).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(label).lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(.title2, design: .monospaced, weight: .semibold)).foregroundStyle(Strim.C.text)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    if let unit { Text(unit).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted) }
                }
                if let note { StrimPill(note, tone: .warn) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .glassCard(padding: Strim.S.md)
        .accessibilityElement(children: .combine)
    }
}

/// Stacked capsule bar: weights, prefix trie, MLX cache, headroom. Segments are separated by gaps and every
/// segment is named with its GB in the legend, so no meaning rides on colour alone.
struct MemoryBar: View {
    let memory: MemoryStats
    var height: CGFloat = 12
    var compact = false
    private var fills: [AnyShapeStyle] {
        [AnyShapeStyle(LinearGradient(colors: [Strim.C.indigo, Strim.C.violet], startPoint: .leading, endPoint: .trailing)),
         AnyShapeStyle(Strim.C.pink),
         AnyShapeStyle(Strim.C.accentText.opacity(0.85)),
         AnyShapeStyle(Strim.C.track)]
    }
    var body: some View {
        let segs = StatsFormat.memorySegments(memory)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let gap: CGFloat = 3
                let usable = geo.size.width - gap * CGFloat(max(0, segs.count - 1))
                HStack(spacing: gap) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                        Stadium().fill(fills[i % fills.count]).frame(width: max(0, usable * s.fraction))
                    }
                }
            }.frame(height: height)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact ? 2 : 4), alignment: .leading, spacing: 6) {
                ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 5) {
                        Stadium().fill(fills[i % fills.count]).frame(width: 12, height: 5)
                            .overlay(Stadium().strokeBorder(Strim.C.hairline, lineWidth: 0.5))
                        Text(s.label).font(.caption2).foregroundStyle(Strim.C.muted)
                        Text(StatsFormat.gb(s.gb)).font(Strim.F.mono(.caption2, weight: .medium)).foregroundStyle(Strim.C.text)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory: " + segs.map { "\($0.label) \(StatsFormat.gb($0.gb))" }.joined(separator: ", "))
    }
}

/// Compact stats block for the menu popover.
struct StatsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let s = model.status {
            VStack(alignment: .leading, spacing: 6) {
                if s.state == .loading { ProgressView(value: s.loadProgress ?? 0).tint(Strim.C.violet) }
                StatRow(label: "Model", value: s.model ?? "none")
                StatRow(label: "MTP head", value: s.mtp ?? "none")
                MemoryBar(memory: s.memory, height: 8, compact: true).padding(.vertical, 2)
                StatRow(label: "Decode", value: StatsFormat.tps(s.decodeTPS))
                StatRow(label: "MTP acceptance / depth", value: "\(StatsFormat.percent(s.mtpAcceptance)) / \(StatsFormat.depth(s.mtpDepth))")
                StatRow(label: "Prefix-cache hits", value: StatsFormat.percent(s.prefixHitRate))
                StatRow(label: "Jobs active / queued", value: "\(s.activeJobs) / \(s.queuedJobs)")
                StatRow(label: "Tokens today", value: StatsFormat.tokens(s.tokensToday))
                StatRow(label: "Uptime", value: StatsFormat.duration(s.uptimeSeconds))
                if let c = s.lastCrash { StatRow(label: "Last crash", value: c) }
            }
        }
    }
}

struct ControlButtons: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let load = model.loadAvailability, unload = model.unloadAvailability, pause = model.pauseAvailability
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { Task { await model.loadModel() } } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(StrimButtonStyle(.primary)).disabled(!load.enabled).help(load.reason ?? "Load the configured model")
                Button { Task { await model.unloadModel() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(StrimButtonStyle(.secondary)).disabled(!unload.enabled).help(unload.reason ?? "Unload the model")
                Button { Task { await model.togglePause() } } label: {
                    Label(model.pauseButtonTitle, systemImage: model.jobsPaused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(StrimButtonStyle(.secondary)).disabled(!pause.enabled)
                .help(pause.reason ?? (model.jobsPaused ? "Admit background jobs again" : "Stop starting background jobs; running ones finish. Chat is not affected."))
            }
            if model.jobsPaused {
                Label("Background jobs are paused. Chat still works.", systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(Strim.C.amber)
            }
            if model.connection.isConnected, load.reason != nil || unload.reason != nil {
                Text([load.reason.map { "Start: \($0)" }, unload.reason.map { "Stop: \($0)" }].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted)
            }
        }
    }
}

struct VerifyBadge: View {
    let verify: VerifyResult?
    var body: some View {
        switch verify {
        case .verified: StrimPill("verified", icon: "checkmark", tone: .accent)
        case .failed: StrimPill("failed", icon: "xmark", tone: .error)
        case .unverified: StrimPill("unverified", icon: "questionmark", tone: .warn)
        case nil: EmptyView()
        }
    }
}

struct Badge: View {
    let text: String
    var tone: PillTone = .neutral
    var body: some View { StrimPill(text, tone: tone) }
}


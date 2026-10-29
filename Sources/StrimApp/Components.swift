import SwiftUI
import StrimAPI
import StrimAppCore

/// Single offline banner: icon, "Host offline", a one-line reason (no trailing period doubling), Start host + Retry now.
struct OfflineBannerView: View {
    @ObservedObject var model: AppModel
    /// First line of the reason, trailing periods trimmed, so a sentence ending in "." never renders "..".
    static func oneLine(_ reason: String, hostURL: String? = nil) -> String {
        let first = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        var s = first.trimmingCharacters(in: .whitespaces)
        if s.contains("not running at") || s.contains("Could not connect to the server") {
            s = hostURL.map { "Could not connect to \($0)" } ?? "Could not connect to the host"
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }
    var body: some View {
        if let reason = model.offlineBanner {
            VStack(alignment: .leading, spacing: 8) {
                Label("Host offline", systemImage: "bolt.slash.fill").font(.headline).foregroundStyle(Strim.C.coral)
                let line = Self.oneLine(reason, hostURL: model.settings.hostURL)
                if !line.isEmpty {
                    Text(line).font(.callout).foregroundStyle(Strim.C.text).lineLimit(1).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if model.serverStartAvailability.enabled {
                        Button("Start server") { model.startHost() }.buttonStyle(StrimButtonStyle(.primary))
                    } else {
                        Label(model.serverStartAvailability.reason ?? "Server cannot start", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(Strim.C.muted)
                    }
                    Button("Retry now") { model.reconnectNow() }.buttonStyle(StrimButtonStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Strim.S.md)
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
            .background(Strim.C.accentFill, in: RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        }
    }
}

struct ModelDownloadCard: View {
    @ObservedObject var model: AppModel
    var compact = false

    private var confirmationPresented: Binding<Bool> {
        Binding(get: {
            if case .confirming = model.modelDownloadState { true } else { false }
        }, set: { shown in if !shown { model.dismissModelDownloadConfirmation() } })
    }

    var body: some View {
        Group {
            switch model.modelDownloadState {
            case .idle, .done: EmptyView()
            case let .needsDownload(size, free, resumable): needsDownload(size: size, free: free, resumable: resumable)
            case .confirming: needsDownload(size: ModelDownloader.modelBytes, free: ModelDownloader.reserveBytes + ModelDownloader.modelBytes, resumable: false)
            case .downloading(let progress): downloading(progress)
            case .verifying(let file): verifying(file)
            case let .failed(message, resumable): failed(message, resumable: resumable)
            }
        }
        .confirmationDialog("Download 15.2 GB from Hugging Face?", isPresented: confirmationPresented, titleVisibility: .visible) {
            Button("Download") { model.beginModelDownload() }
            Button("Cancel", role: .cancel) { model.dismissModelDownloadConfirmation() }
        }
    }

    private func needsDownload(size: Int64, free: Int64, resumable: Bool) -> some View {
        let needed = size + ModelDownloader.reserveBytes
        let shortfall = max(0, needed - free)
        return VStack(alignment: .leading, spacing: compact ? 9 : Strim.S.md) {
            Label("Model needed before Strim can run", systemImage: "arrow.down.circle")
                .font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(Strim.C.text)
            Text("Strim needs the Qwen3.8-27B model (about 15 GB) before it can run. It downloads once and stays on this Mac.")
                .font(.callout).foregroundStyle(Strim.C.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Free disk space: \(ModelDisk.gb(free))")
                Text(shortfall == 0
                     ? "\(ModelDisk.gb(needed)) needed, including 5 GB of headroom."
                     : "\(ModelDisk.gb(needed)) needed, including 5 GB of headroom. Missing \(ModelDisk.gb(shortfall)).")
            }
            .font(Strim.F.mono(.caption)).foregroundStyle(shortfall == 0 ? Strim.C.muted : Strim.C.text)
            Button {
                model.confirmModelDownload()
            } label: {
                Label(resumable ? "Resume download" : "Download model (15.2 GB)", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(StrimButtonStyle(.primary)).disabled(shortfall > 0)
            .help(shortfall > 0 ? "Free \(ModelDisk.gb(shortfall)) more disk space to download the model" : "Download the model from Hugging Face")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: compact ? Strim.S.md : Strim.S.xl, strong: true)
    }

    private func downloading(_ progress: ModelDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : Strim.S.md) {
            Label("Downloading Qwen3.8-27B", systemImage: "arrow.down.circle")
                .font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
            ProgressView(value: progress.fraction).tint(Strim.C.accent)
            HStack {
                Text("\(Int(progress.fraction * 100))%")
                Spacer()
                Text("\(ModelDisk.gb(progress.doneBytes)) / \(ModelDisk.gb(progress.totalBytes))")
            }.font(Strim.F.mono(.callout, weight: .medium))
            HStack {
                Text(String(format: "%.1f MB/s", progress.bytesPerSec / 1_000_000))
                Spacer()
                Text(progress.etaSec.map { "\(StatsFormat.duration($0)) left" } ?? "Estimating time")
            }.font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
            Text(progress.file).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                .lineLimit(1).truncationMode(.middle)
            Button("Pause / cancel") { model.cancelModelDownload() }
                .buttonStyle(StrimButtonStyle(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: compact ? Strim.S.md : Strim.S.xl, strong: true)
    }

    private func verifying(_ file: String) -> some View {
        VStack(alignment: .leading, spacing: Strim.S.md) {
            Label("Verifying download", systemImage: "checkmark.shield")
                .font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
            ProgressView().tint(Strim.C.accent)
            Text(file).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted).lineLimit(1).truncationMode(.middle)
        }.frame(maxWidth: .infinity, alignment: .leading).glassCard(padding: compact ? Strim.S.md : Strim.S.xl, strong: true)
    }

    private func failed(_ message: String, resumable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Strim.S.md) {
            Label("Model download failed", systemImage: "exclamationmark.triangle")
                .font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(Strim.C.text).fixedSize(horizontal: false, vertical: true)
            Button(resumable ? "Retry / resume" : "Retry") { model.retryModelDownload() }
                .buttonStyle(StrimButtonStyle(.primary))
        }.frame(maxWidth: .infinity, alignment: .leading).glassCard(padding: compact ? Strim.S.md : Strim.S.xl, strong: true)
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
                    Circle().trim(from: 0, to: max(0.01, min(1, ring))).stroke(Strim.C.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
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
        [AnyShapeStyle(Strim.C.accent),
         AnyShapeStyle(Strim.C.accent.opacity(0.55)),
         AnyShapeStyle(Strim.C.muted.opacity(0.6)),
         AnyShapeStyle(Strim.C.hairline)]
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
                if s.state == .loading { ProgressView(value: s.loadProgress ?? 0).tint(Strim.C.accent) }
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
    @State private var confirmStopServer = false
    var body: some View {
        let load = model.loadAvailability, unload = model.unloadAvailability, pause = model.pauseAvailability
        VStack(alignment: .leading, spacing: 8) {
            if model.connection.isConnected {
                Button {
                    if (model.status?.activeJobs ?? 0) > 0 { confirmStopServer = true }
                    else { Task { await model.stopServer() } }
                } label: { Label("Stop server (frees ~15-30 GB)", systemImage: "power") }
                    .buttonStyle(StrimButtonStyle(.danger)).disabled(!model.serverStopAvailability.enabled)
                    .help(model.serverStopAvailability.reason ?? "Stop Strim and release its memory")
            } else {
                Button { model.startHost() } label: { Label("Start server", systemImage: "play.fill") }
                    .buttonStyle(StrimButtonStyle(.primary)).disabled(!model.serverStartAvailability.enabled)
                    .help(model.serverStartAvailability.reason ?? "Start Strim")
            }
            HStack(spacing: 8) {
                Button { Task { await model.loadModel() } } label: { Label("Load model", systemImage: "play.fill") }
                    .buttonStyle(StrimButtonStyle(.primary)).disabled(!load.enabled).help(load.reason ?? "Load the configured model")
                Button { Task { await model.unloadModel() } } label: { Label("Unload model", systemImage: "stop.fill") }
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
        .confirmationDialog("Stop the Strim server?", isPresented: $confirmStopServer, titleVisibility: .visible) {
            Button("Stop server", role: .destructive) { Task { await model.stopServer() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active jobs will be interrupted.")
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


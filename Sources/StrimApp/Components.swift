import SwiftUI
import StrimAPI
import StrimAppCore

struct OfflineBannerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let reason = model.offlineBanner {
            VStack(alignment: .leading, spacing: 6) {
                Label("Host offline", systemImage: "bolt.slash.fill").font(.headline).foregroundStyle(.orange)
                Text(reason).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Start host") { model.startHost() }
                    Button("Retry now") { model.reconnectNow() }
                }
                if model.reconnectAttempts > 0 {
                    Text("Reconnect attempts: \(model.reconnectAttempts)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else if case .connecting = model.connection {
            Label("Connecting to \(model.settings.hostURL)...", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct TokenWarningView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let w = model.tokenWarning {
            Label(w, systemImage: "key.slash").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

struct NoticeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let n = model.notice {
            HStack(alignment: .top) {
                Text(n).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                Button { model.dismissNotice() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
            }
            .padding(8).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct StatRow: View {
    let label: String, value: String
    var note: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption2).padding(.horizontal, 4).background(.yellow.opacity(0.3), in: Capsule()) }
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

struct MemoryBar: View {
    let memory: MemoryStats
    var height: CGFloat = 10
    private let colors: [Color] = [.blue, .purple, .teal, .gray.opacity(0.35)]
    var body: some View {
        let segs = StatsFormat.memorySegments(memory)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                        Rectangle().fill(colors[i % colors.count]).frame(width: max(0, geo.size.width * s.fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }.frame(height: height)
            HStack(spacing: 10) {
                ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 3) {
                        Circle().fill(colors[i % colors.count]).frame(width: 6, height: 6)
                        Text("\(s.label) \(StatsFormat.gb(s.gb))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Stats block shared by the menu and the Status tab.
struct StatsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let s = model.status {
            VStack(alignment: .leading, spacing: 5) {
                StatRow(label: "State", value: s.state == .loading ? "loading \(StatsFormat.percent(s.loadProgress ?? 0))" : s.state.rawValue)
                if s.state == .loading { ProgressView(value: s.loadProgress ?? 0) }
                StatRow(label: "Model", value: s.model ?? "none")
                StatRow(label: "MTP head", value: s.mtp ?? "none")
                MemoryBar(memory: s.memory)
                Divider()
                StatRow(label: "Decode", value: StatsFormat.tps(s.decodeTPS))
                StatRow(label: "Prefill", value: StatsFormat.tps(s.prefillTPS))
                StatRow(label: "MTP acceptance / depth", value: "\(StatsFormat.percent(s.mtpAcceptance)) / \(StatsFormat.depth(s.mtpDepth))")
                StatRow(label: "Prefix-cache hit rate", value: StatsFormat.percent(s.prefixHitRate))
                StatRow(label: "Prefill saved", value: StatsFormat.seconds(s.savedPrefillSeconds))
                Divider()
                StatRow(label: "Jobs active / queued", value: "\(s.activeJobs) / \(s.queuedJobs)")
                ForEach(model.sourceCounts.filter { $0.active + $0.queued > 0 }) { c in
                    StatRow(label: "  \(c.source.rawValue)", value: "\(c.active) active, \(c.queued) queued")
                }
                StatRow(label: "Tokens today", value: StatsFormat.tokens(s.tokensToday))
                StatRow(label: "Parent tokens saved", value: s.parentTokensSavedEstimate.map(StatsFormat.tokens) ?? "n/a", note: "estimate")
                StatRow(label: "Uptime", value: StatsFormat.duration(s.uptimeSeconds))
                StatRow(label: "Last crash", value: s.lastCrash ?? "none")
            }
            .font(.callout)
        }
    }
}

struct ControlButtons: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let load = model.loadAvailability, unload = model.unloadAvailability, pause = model.pauseAvailability
        HStack {
            Button("Load") { Task { await model.loadModel() } }.disabled(!load.enabled).help(load.reason ?? "Load the configured model")
            Button("Unload") { Task { await model.unloadModel() } }.disabled(!unload.enabled).help(unload.reason ?? "Unload the model")
            Button(model.pauseButtonTitle) { Task { await model.togglePause() } }.disabled(!pause.enabled)
                .help(pause.reason ?? (model.jobsPaused ? "Admit background jobs again" : "Stop starting background jobs; running ones finish. Chat is not affected."))
        }
        if model.jobsPaused {
            Label("Background jobs are paused. Chat still works.", systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
        }
        if model.connection.isConnected, load.reason != nil || unload.reason != nil {
            Text([load.reason.map { "Load: \($0)" }, unload.reason.map { "Unload: \($0)" }].compactMap { $0 }.joined(separator: "  |  "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TestBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.showTestBanner {
            VStack(alignment: .leading, spacing: 3) {
                Text("TEST BANNER").font(.caption.bold())
                Text("state: \(model.rawState)   last event: \(StatsFormat.relative(model.lastEventTime, now: Date()))")
                Text("last error: \(model.lastError ?? "none")")
                Text(model.eventLogTail.isEmpty ? "(no events yet)" : model.eventLogTail.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.25))
            .overlay(Rectangle().stroke(.yellow, lineWidth: 1))
        }
    }
}

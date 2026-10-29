import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

struct StatusView: View {
    @ObservedObject var model: AppModel
    @State private var detailsOpen = false
    @State private var contentWidth: CGFloat = 840
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutClass) private var layout
    @Environment(\.strimNow) private var strimNow

    private var maxContentWidth: CGFloat? {
        switch layout { case .wide: 1080; case .regular: 880; case .compact: nil }
    }
    private var heroNumberSize: CGFloat { contentWidth < 520 ? 34 : 44 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Strim.S.md) {
                TokenWarningView(model: model)
                NoticeView(model: model)
                hero
                if let s = model.status, s.state != .stopped, s.state != .error {
                    if layout == .wide, s.state != .loading {
                        // Wide: memory and engine side by side.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: Strim.S.md, alignment: .top)], alignment: .leading, spacing: Strim.S.md) {
                            memory(s)
                            engine(s)
                        }
                    } else {
                        memory(s)
                        if s.state != .loading { engine(s) }
                    }
                }
                if let s = model.status { details(s) }
            }
            .padding(layout == .compact ? 16 : Strim.S.xl)
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
    }

    // MARK: hero

    @ViewBuilder private var hero: some View {
        let orb = OrbState(model.connection)
        switch orb {
        case .error: errorHero
        case .stopped, .offline: stoppedHero(orb)
        case .loading(let p): loadingHero(p)
        case .running, .busy: liveHero(orb)
        }
    }

    private func liveHero(_ orb: OrbState) -> some View {
        let s = model.status!
        let v = s.decodeTPS
        let shown = v > 0 ? v : (model.decodeHistory.last(where: { $0 > 0 }) ?? 0)
        let numbers = liveNumbers(s, orb: orb, shown: shown)
        let spark = model.decodeHistory.count > 1
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Strim.S.xl) {
                numbers.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if spark { Sparkline(samples: model.decodeHistory, color: v > 0 ? Strim.C.accent : Strim.C.tertiary).frame(minWidth: 160, idealWidth: 240, maxWidth: 360).frame(height: 56) }
            }
            VStack(alignment: .leading, spacing: Strim.S.md) {
                numbers
                if spark { Sparkline(samples: model.decodeHistory, color: v > 0 ? Strim.C.accent : Strim.C.tertiary).frame(maxWidth: .infinity).frame(height: 48) }
            }
        }
        .padding(.vertical, Strim.S.sm)
    }

    private func liveNumbers(_ s: HostStatus, orb: OrbState, shown: Double) -> some View {
        let generating = orb == .busy
        let v = s.decodeTPS
        return VStack(alignment: .leading, spacing: 6) {
                Text(generating ? "Generating · \(model.modelLabel)" : "Running · \(model.modelLabel)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Strim.C.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if shown > 0 {
                        Text(String(format: "%.1f", shown))
                            .font(.system(size: heroNumberSize, weight: .semibold).monospacedDigit())
                            .foregroundStyle(generating ? Strim.C.accent : Strim.C.text)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shown)
                        Text(v > 0 ? "tok/s decode" : "tok/s last request").font(.system(size: 15)).foregroundStyle(Strim.C.muted)
                    } else {
                        Text("Ready").font(.system(size: 28, weight: .semibold)).foregroundStyle(Strim.C.muted)
                    }
                }
                Text("prefill \(Int(s.prefillTPS.rounded())) tok/s\(v > 0 ? "" : " (last)") · \(s.activeJobs) active · \(s.queuedJobs) queued" + (model.jobsPaused ? " · jobs paused" : ""))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Strim.C.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Decode speed, \(Int(v.rounded())) tokens per second")
    }

    private func stoppedHero(_ orb: OrbState) -> some View {
        let offline = orb == .offline
        return VStack(alignment: .leading, spacing: Strim.S.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(offline ? "Offline" : "Stopped").font(.system(size: 28, weight: .semibold)).foregroundStyle(Strim.C.tertiary)
                }
            }
            if offline, let r = model.offlineBanner {
                Text(OfflineReason.oneLine(r, hostURL: model.settings.hostURL)).font(.system(size: 12)).foregroundStyle(Strim.C.muted)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                ServerToggleButton(model: model, large: true)
                if offline { Button("Retry now") { model.reconnectNow() }.buttonStyle(StrimButtonStyle(.secondary, large: true)) }
            }
            Text("Loads \(model.modelShortName), about \(model.modelWeightsText) of memory.")
                .font(.system(size: 12)).foregroundStyle(Strim.C.muted)
        }
        .padding(.vertical, Strim.S.sm)
    }

    private func loadingHero(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loading · \(model.modelShortName)").font(.system(size: 12, weight: .medium)).foregroundStyle(Strim.C.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(StatsFormat.percent(p)).font(.system(size: heroNumberSize, weight: .semibold).monospacedDigit()).foregroundStyle(Strim.C.text)
                Text("of \(model.modelWeightsText) read into memory").font(.system(size: 15)).foregroundStyle(Strim.C.muted)
            }
            StrimProgressBar(value: p).frame(maxWidth: 440).padding(.top, 6)
                .accessibilityValue(StatsFormat.percent(p))
        }
        .padding(.vertical, Strim.S.sm)
    }

    private var errorHero: some View {
        let msg = model.status?.lastCrash ?? model.lastError ?? "The server reported an error."
        return VStack(alignment: .leading, spacing: Strim.S.md) {
            Label {
                Text("Server error").foregroundStyle(Strim.C.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Strim.C.danger)
            }.font(.system(size: 15, weight: .semibold))
            Text(msg).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Retry") { Task { await model.startServer() } }.buttonStyle(StrimButtonStyle(.primary))
                Button("Copy error") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg, forType: .string) }
                    .buttonStyle(StrimButtonStyle(.secondary))
            }
        }
        .padding(.vertical, Strim.S.sm)
    }

    // MARK: cards

    private func memory(_ s: HostStatus) -> some View {
        let m = s.memory
        let total = m.weightsGB + m.prefixTrieGB + m.mlxCacheGB + m.headroomGB
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Memory").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(String(format: "%.1f", total - m.headroomGB)) of \(StatsFormat.gb(total))")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Strim.C.muted)
            }
            MemoryBar(memory: m)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func engine(_ s: HostStatus) -> some View {
        var rows: [(String, String)] = [
            ("MTP acceptance", "\(StatsFormat.percent(s.mtpAcceptance)) (depth \(String(format: "%.2f", s.mtpDepth)))"),
            ("Prefix-cache hits", StatsFormat.percent(s.prefixHitRate)),
            ("Prefill saved", StatsFormat.seconds(s.savedPrefillSeconds)),
            ("Tokens today", StatsFormat.tokens(s.tokensToday)),
            ("Uptime", StatsFormat.duration(s.uptimeSeconds)),
        ]
        if let p = s.parentTokensSavedEstimate { rows.insert(("Parent tokens saved (estimate)", StatsFormat.tokens(p)), at: 4) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Engine").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 32)], alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in KeyValueRow(label: r.0, value: r.1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // MARK: details

    private func details(_ s: HostStatus) -> some View {
        StrimDisclosure(isOpen: $detailsOpen, spacing: 10) {
            Text("Details").font(.system(size: 12, weight: .medium)).foregroundStyle(Strim.C.muted)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                group("Fingerprint")
                KeyValueRow(label: "Model", value: s.model ?? "none")
                KeyValueRow(label: "Quant", value: Self.quant(s.model))
                KeyValueRow(label: "MTP head", value: s.mtp ?? "none")
                KeyValueRow(label: "Weights hash", value: Self.shortHash(s.quantFingerprint, 0))
                KeyValueRow(label: "MTP hash", value: Self.shortHash(s.quantFingerprint, 1))
                KeyValueRow(label: "Pack", value: model.packInfo?.activeFingerprint.map { String($0.prefix(8)) } ?? "built-in")
                KeyValueRow(label: "Last crash", value: s.lastCrash ?? "none")
                group("Diagnostics").padding(.top, 8)
                KeyValueRow(label: "State", value: model.rawState)
                KeyValueRow(label: "Last event", value: StatsFormat.relative(model.lastEventTime, now: strimNow ?? Date()))
                KeyValueRow(label: "Error", value: model.lastError ?? "none")
            }
            .padding(.leading, 16)
        }
        .padding(.horizontal, 2)
    }
    private func group(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(Strim.C.tertiary).frame(height: 24, alignment: .bottomLeading)
    }

    static func quant(_ model: String?) -> String {
        guard let model, let r = model.range(of: #"(\d+)\s?-?bit"#, options: [.regularExpression, .caseInsensitive]) else { return "n/a" }
        return "\(model[r].filter(\.isNumber))-bit"
    }
    static func shortHash(_ fp: String?, _ i: Int) -> String {
        guard let fp else { return "n/a" }
        let parts = fp.split(separator: "/").map(String.init)
        return i < parts.count ? String(parts[i].prefix(8)) : "n/a"
    }
}

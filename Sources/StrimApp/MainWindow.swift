import SwiftUI
import StrimAPI
import StrimAppCore

enum MainTab: String, CaseIterable, Identifiable {
    case status, jobs, chat, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .jobs: "list.bullet.rectangle"
        case .chat: "bubble.left.and.bubble.right"
        case .settings: "gearshape"
        }
    }
}

/// Window content: custom header (mark, nav pill, state pill) over the flat window background. The real window hides its
/// title bar, so the traffic lights sit in the header's leading inset (`MainWindow.lightsInset`).
struct MainWindow: View {
    @ObservedObject var model: AppModel
    @State private var tab: MainTab
    var expandChat = false
    static let lightsInset: CGFloat = 24

    init(model: AppModel, tab: MainTab = .status, expandChat: Bool = false) { self.model = model; _tab = State(initialValue: tab); self.expandChat = expandChat }

    var body: some View {
        VStack(spacing: 0) {
            header
            DiagnosticsStrip(model: model)
            Group {
                switch tab {
                case .status: StatusTab(model: model)
                case .jobs: JobsTab(model: model)
                case .chat: ChatTab(model: model, expandAll: expandChat)
                case .settings: SettingsTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(StrimBackground())
        .foregroundStyle(Strim.C.text)
        .onAppear { model.checkModelAvailability() }
    }

    private var header: some View {
        let orb = OrbState(model.connection)
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                StrimMarkView(size: 26)
                Text("strim").font(.title3.weight(.semibold)).tracking(-0.3)
            }
            .padding(.leading, Self.lightsInset)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(MainTab.allCases) { t in
                    Button { tab = t } label: {
                        Label(t.title, systemImage: t.icon).labelStyle(.titleAndIcon)
                            .font(.callout.weight(tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Strim.C.text : Strim.C.muted)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(tab == t ? Strim.C.glassStrong : .clear, in: Stadium())
                            .overlay(Stadium().strokeBorder(tab == t ? Strim.C.hairline : .clear, lineWidth: 1))
                            .contentShape(Stadium())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(3)
            .capsuleSurface(Strim.C.glass, stroke: Strim.C.hairline)
            Spacer(minLength: 8)
            StatePill(state: orb)
        }
        .padding(.trailing, 20)
        .frame(height: 52)
    }
}

struct StatePill: View {
    let state: OrbState
    var body: some View {
        let tone: PillTone = switch state {
        case .running, .busy, .loading: .accent
        case .stopped: .neutral
        case .error, .offline: .error
        }
        StrimPill(state.word, icon: state.icon, tone: tone)
    }
}

// MARK: - Status

struct StatusTab: View {
    @ObservedObject var model: AppModel
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 68

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Strim.S.lg) {
                ModelDownloadCard(model: model)
                OfflineBannerView(model: model)
                TokenWarningView(model: model)
                NoticeView(model: model)
                if let s = model.status {
                    HStack(alignment: .top, spacing: Strim.S.lg) {
                        hero(s)
                        fingerprint(s).frame(width: 268)
                    }
                    memory(s)
                    if s.state != .stopped { tiles(s) }
                    queue(s)
                } else {
                    hero(nil)
                }
            }
            .padding(Strim.S.xl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func hero(_ s: HostStatus?) -> some View {
        let orb = OrbState(model.connection)
        let running = orb.isLive
        return VStack(alignment: .leading, spacing: Strim.S.lg) {
            HStack(spacing: Strim.S.xl) {
                StrimOrb(orb, size: 104).padding(10)
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Engine · \(orb.word)")
                    if running, let s {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(format: "%.1f", s.decodeTPS))
                                .font(.system(size: numeralSize, weight: .bold, design: .rounded).monospacedDigit())
                                .tracking(-2).foregroundStyle(Strim.C.accent).lineLimit(1).minimumScaleFactor(0.5)
                            Text("tok/s").font(Strim.F.mono(.title3, weight: .medium)).foregroundStyle(Strim.C.muted)
                        }
                        Text("decode  ·  prefill \(StatsFormat.tps(s.prefillTPS))")
                            .font(Strim.F.mono(.callout)).foregroundStyle(Strim.C.muted)
                    } else {
                        Text(heroTitle(orb, s)).font(.system(.title, design: .default, weight: .bold)).tracking(-0.5)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(heroDetail(orb, s)).font(.callout).foregroundStyle(Strim.C.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .loading(let p) = orb {
                            ProgressView(value: p).tint(Strim.C.accent).padding(.top, 4)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if model.connection.isConnected { ControlButtons(model: model) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: Strim.S.xl, strong: true)
    }

    private func heroTitle(_ o: OrbState, _ s: HostStatus?) -> String {
        switch o {
        case .stopped: "Engine stopped"
        case .loading: "Loading the model"
        case .error: "Engine error"
        case .offline: "No connection"
        default: "Ready"
        }
    }
    private func heroDetail(_ o: OrbState, _ s: HostStatus?) -> String {
        switch o {
        case .stopped:
            if let m = model.settings.modelPath { return "Press Start to load \((m as NSString).lastPathComponent). Chat and jobs resume when it is up." }
            return "Choose a model in Settings, then press Start."
        case .loading: return s?.model.map { "Reading \($0) into unified memory." } ?? "Reading weights into unified memory."
        case .error: return s?.lastCrash ?? "The host reported an error. See diagnostics below."
        case .offline: return "The host at \(model.settings.hostURL) is not reachable."
        default: return ""
        }
    }

    private func fingerprint(_ s: HostStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Fingerprint")
            fpRow("model", s.model ?? "none")
            fpRow("quant", Self.quant(s.model))
            fpRow("mtp head", s.mtp ?? "none")
            fpRow("weights", Self.shortHash(s.quantFingerprint, 0))
            fpRow("mtp hash", Self.shortHash(s.quantFingerprint, 1))
            fpRow("pack", model.packInfo?.activeFingerprint.map { String($0.prefix(8)) } ?? "built-in")
            fpRow("last crash", s.lastCrash ?? "none")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(padding: Strim.S.lg)
    }
    private func fpRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
            Spacer(minLength: 6)
            Text(v).font(Strim.F.mono(.caption, weight: .medium)).foregroundStyle(Strim.C.text).lineLimit(1).truncationMode(.middle)
        }
    }
    static func quant(_ model: String?) -> String {
        guard let model, let r = model.range(of: #"(\d+)\s?-?bit"#, options: [.regularExpression, .caseInsensitive]) else { return "n/a" }
        let digits = model[r].filter(\.isNumber)
        return "\(digits)-bit"
    }
    static func shortHash(_ fp: String?, _ i: Int) -> String {
        guard let fp else { return "n/a" }
        let parts = fp.split(separator: "/").map(String.init)
        return i < parts.count ? String(parts[i].prefix(8)) : "n/a"
    }

    private func memory(_ s: HostStatus) -> some View {
        let total = s.memory.weightsGB + s.memory.prefixTrieGB + s.memory.mlxCacheGB + s.memory.headroomGB
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Memory")
                Spacer()
                Text("\(StatsFormat.gb(total - s.memory.headroomGB)) of \(StatsFormat.gb(total))")
                    .font(Strim.F.mono(.caption, weight: .medium)).foregroundStyle(Strim.C.muted)
            }
            MemoryBar(memory: s.memory)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func tiles(_ s: HostStatus) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Strim.S.md), GridItem(.flexible(), spacing: Strim.S.md), GridItem(.flexible(), spacing: Strim.S.md)], spacing: Strim.S.md) {
            MetricTile(label: "MTP acceptance", value: StatsFormat.percent(s.mtpAcceptance), unit: "depth \(StatsFormat.depth(s.mtpDepth))", ring: s.mtpAcceptance)
            MetricTile(label: "Prefix-cache hits", value: StatsFormat.percent(s.prefixHitRate), ring: s.prefixHitRate)
            MetricTile(label: "Prefill saved", value: StatsFormat.seconds(s.savedPrefillSeconds))
            MetricTile(label: "Tokens today", value: StatsFormat.tokens(s.tokensToday), unit: "tok")
            MetricTile(label: "Parent tokens saved", value: s.parentTokensSavedEstimate.map(StatsFormat.tokens) ?? "n/a", note: "estimate")
            MetricTile(label: "Uptime", value: StatsFormat.duration(s.uptimeSeconds))
        }
    }

    private func queue(_ s: HostStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Queue & admission")
                Spacer()
                if model.jobsPaused { StrimPill("admission paused", icon: "pause.fill", tone: .warn) }
                else { StrimPill("admitting", icon: "arrow.right.circle", tone: .accent) }
            }
            HStack(alignment: .firstTextBaseline, spacing: Strim.S.xl) {
                counter("active", s.activeJobs)
                counter("queued", s.queuedJobs)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(model.sourceCounts.filter { $0.active + $0.queued > 0 }) { c in
                        Text("\(c.source.rawValue)  \(c.active) active · \(c.queued) queued")
                            .font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                    }
                    if model.sourceCounts.allSatisfy({ $0.active + $0.queued == 0 }) {
                        Text("no background jobs").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
    private func counter(_ label: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(.system(.largeTitle, design: .monospaced, weight: .semibold))
            Text(label).font(Strim.F.mono(.callout)).foregroundStyle(Strim.C.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Jobs

struct JobsTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Strim.S.lg) {
            ledger
            HStack(alignment: .top, spacing: Strim.S.lg) {
                list.frame(width: 320)
                JobDetailView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(Strim.S.xl)
        .onChange(of: selection) { _, new in Task { await model.selectJob(new) } }
        .task { await model.refreshJobs() }
        .onAppear { selection = model.selectedJob?.id }
    }

    /// Token ledger strip: what ran locally and what that saved upstream.
    private var ledger: some View {
        HStack(spacing: Strim.S.md) {
            let s = model.status
            LedgerCell(label: "Tokens today", value: s.map { StatsFormat.tokens($0.tokensToday) } ?? "n/a")
            LedgerCell(label: "Generated locally", value: s.map { StatsFormat.tokens($0.localTokensGenerated) } ?? "n/a")
            LedgerCell(label: "Parent saved", value: s?.parentTokensSavedEstimate.map(StatsFormat.tokens) ?? "n/a", note: "estimate")
            Spacer(minLength: 0)
            if model.connection.isConnected {
                Button { Task { await model.togglePause() } } label: {
                    Label(model.pauseButtonTitle, systemImage: model.jobsPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(StrimButtonStyle(model.jobsPaused ? .primary : .secondary))
                .disabled(!model.pauseAvailability.enabled)
                .help("Pause stops new background jobs from starting; running ones finish. Chat is not affected.")
            }
        }
    }

    private var list: some View {
        let view = model.jobListView
        return VStack(spacing: Strim.S.sm) {
            jobsFilterBar(view)
            ScrollView {
            LazyVStack(spacing: Strim.S.sm) {
                if view.shown.isEmpty {
                    Text(!model.connection.isConnected ? "Engine offline: no job list." : view.total == 0 ? "No jobs yet." : "No active or recent jobs.")
                        .font(.callout).foregroundStyle(Strim.C.muted).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                }
                ForEach(view.shown) { j in
                    JobCard(job: j, selected: selection == j.id, cancel: model.cancelJobAvailability(for: j),
                            onCancel: { Task { await model.cancelJob(j.id) } })
                        .onTapGesture { selection = j.id }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(1)
        }
        }
    }

    /// "Active + last 24 h" by default; counts and a toggle for the full history.
    @ViewBuilder private func jobsFilterBar(_ view: JobListFilter.Result) -> some View {
        if view.total > 0 {
            HStack(spacing: 8) {
                Text(model.showAllJobs ? "\(view.total) jobs" : "\(view.shown.count) of \(view.total) jobs")
                    .font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                if view.active > 0 { StrimPill("\(view.active) active", tone: .accent) }
                Spacer(minLength: 0)
                if model.showAllJobs || view.hidden > 0 {
                    Button(model.showAllJobs ? "Recent only" : "Show all (+\(view.hidden))") { model.showAllJobs.toggle() }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Strim.C.accentText)
                        .help("Default view: active jobs and the last 24 hours.")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct LedgerCell: View {
    let label: String, value: String
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            HStack(spacing: 6) {
                Text(value).font(.system(.title3, design: .monospaced, weight: .semibold))
                if let note { StrimPill(note, tone: .warn) }
            }
        }
        .padding(.horizontal, Strim.S.md).padding(.vertical, 10)
        .background(Strim.C.glass, in: RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension JobStatusDTO {
    var icon: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .awaitingApproval: "hand.raised.fill"
        case .pausedInteractive: "pause.fill"
        case .done: "checkmark"
        case .failed: "xmark"
        case .cancelled: "slash.circle"
        case .limit: "gauge.with.needle"
        }
    }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ") }
    var tone: PillTone {
        switch self {
        case .running, .done: .accent
        case .queued, .cancelled, .pausedInteractive: .neutral
        case .awaitingApproval, .limit: .warn
        case .failed: .error
        }
    }
}

struct JobCard: View {
    let job: JobSummary
    let selected: Bool
    let cancel: Availability
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.status.icon).font(.system(size: 12, weight: .bold))
                .foregroundStyle(job.status.isFinished ? Strim.C.muted : Strim.C.accentText)
                .frame(width: 28, height: 28)
                .background(Strim.C.track, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title ?? job.id).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StrimPill(job.status.label, tone: job.status.tone)
                    VerifyBadge(verify: job.verify)
                }
                Text("\(job.source.rawValue) · \(job.id) · \(StatsFormat.relative(Date(timeIntervalSince1970: job.started), now: Date()))")
                    .font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if cancel.enabled {
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(Strim.C.muted).help("Cancel job").accessibilityLabel("Cancel job")
            }
        }
        .padding(Strim.S.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Strim.C.glassStrong : Strim.C.glass, in: RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Strim.C.accent) : AnyShapeStyle(Strim.C.hairline), lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Strim.R.card, style: .continuous))
    }
}

struct JobDetailView: View {
    @ObservedObject var model: AppModel
    @State private var verifyOpen = false
    var body: some View {
        Group {
            if let d = model.selectedJob { detail(d) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 26)).foregroundStyle(Strim.C.muted)
                    Text("Select a job").font(.callout).foregroundStyle(Strim.C.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).glassCard()
            }
        }
    }

    private func detail(_ d: JobDetail) -> some View {
        let av = model.applyAvailability(for: d)
        let rejectAv = model.approveAvailability(for: d)
        let analysis = model.selectedAnalysis
        let cancel = model.cancelJobAvailability(for: d.summary)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.summary.title ?? d.id).font(.title3.weight(.semibold)).tracking(-0.2)
                    Spacer()
                    StrimPill(d.summary.status.label, icon: d.summary.status.icon, tone: d.summary.status.tone)
                    VerifyBadge(verify: d.summary.verify)
                }
                HStack(spacing: 16) {
                    ledgerStat("turns", "\(d.turns)")
                    ledgerStat("local tokens", StatsFormat.tokens(d.localTokens))
                    if let c = d.summary.cwd { ledgerStat("cwd", (c as NSString).abbreviatingWithTildeInPath) }
                }
                HStack {
                    Button("Cancel job", role: .destructive) { Task { await model.cancelJob(d.id) } }
                        .buttonStyle(StrimButtonStyle(.danger)).disabled(!cancel.enabled).help(cancel.reason ?? "Stop this job")
                    if let r = cancel.reason, !cancel.enabled { Text(r).font(.caption).foregroundStyle(Strim.C.muted) }
                }
                if let r = d.resultSummary { Text(r).font(.callout).textSelection(.enabled) }
                if let v = d.verifyOutput, !v.isEmpty {
                    StrimDisclosure(isOpen: $verifyOpen) {
                        SectionLabel("Verify output")
                    } content: {
                        ScrollView { Text(v).font(Strim.F.mono(.caption)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 120).padding(8)
                            .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
                    }
                }
                if let p = d.patch, !p.isEmpty, let analysis {
                    DiffView(analysis: analysis)
                    if analysis.blocked {
                        Label("This patch could not be fully understood. Apply is disabled; you can Reject or inspect the file.", systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(Strim.C.coral).font(.callout)
                    } else if model.patchChangedSinceReview {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("The patch changed after you opened it. Review the version shown above, then acknowledge.", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Strim.C.amber).font(.callout)
                            Button("I have reviewed the updated patch") { model.acknowledgeUpdatedPatch() }.buttonStyle(StrimButtonStyle(.secondary))
                        }
                    } else if let t = analysis.confirmationText {
                        Toggle(isOn: Binding(get: { model.patchConfirmed }, set: { model.setPatchConfirmed($0) })) {
                            Text("\(t). I have reviewed it and want to apply it.").font(.callout)
                        }.toggleStyle(StrimToggleStyle())
                    }
                    HStack {
                        Button("Apply") { Task { await model.approve(.apply) } }.buttonStyle(StrimButtonStyle(.primary)).disabled(!av.enabled)
                        Button("Reject") { Task { await model.approve(.reject) } }.buttonStyle(StrimButtonStyle(.secondary)).disabled(!rejectAv.enabled)
                        Button("Copy patch path") { model.copyPatchPath() }.buttonStyle(StrimButtonStyle(.secondary))
                        if let r = av.reason { Text(r).font(.caption).foregroundStyle(Strim.C.muted).lineLimit(2) }
                    }
                } else {
                    Text("No patch.").font(.callout).foregroundStyle(Strim.C.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassCard(padding: Strim.S.lg)
    }

    private func ledgerStat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
            Text(v).font(Strim.F.mono(.caption, weight: .semibold)).lineLimit(1).truncationMode(.head)
        }
    }
}

// MARK: - Diff (logic unchanged; restyled without green: additions use the accent, removals coral, with +/- signs)

struct DiffView: View {
    let analysis: PatchAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(analysis.summary).font(.caption.bold())
            ForEach(Array(analysis.issues.enumerated()), id: \.offset) { _, i in
                Label(i.reason, systemImage: i.blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(i.blocking ? Strim.C.coral : Strim.C.amber)
            }
            ForEach(analysis.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(Strim.C.muted)
            }
            ForEach(analysis.preamble, id: \.self) { l in
                Text("before first header: " + DiffText.visible(l)).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.coral)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(analysis.files) { f in
                    HStack(spacing: 6) {
                        ForEach(f.kinds, id: \.rawValue) { k in Badge(text: k.rawValue, tone: kindTone(k)) }
                        Text(f.renameTo.map { DiffText.visible(f.renameFrom ?? "") + " -> " + DiffText.visible($0) } ?? f.displayPath)
                            .font(Strim.F.mono(.caption))
                        Spacer()
                        Text("+\(f.added) -\(f.removed)").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                    }
                }
            }
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(analysis.files) { f in
                        Text(f.displayPath + "  +\(f.added) -\(f.removed)")
                            .font(Strim.F.mono(.caption, weight: .bold)).padding(.vertical, 4)
                        ForEach(f.headerRows) { r in
                            HStack(spacing: 6) {
                                Badge(text: r.tag, tone: r.tag == "unknown" ? .error : .neutral).fixedSize()
                                Text(r.displayText).lineLimit(1)
                            }.font(Strim.F.mono(.caption))
                        }
                        if let t = f.symlinkTarget { Text("symlink target: \(DiffText.visible(t))").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.amber) }
                        if f.isBinary { Text("binary content (\(f.binaryLineCount) payload lines not shown)").font(.caption).foregroundStyle(Strim.C.amber) }
                        ForEach(f.hunks) { h in
                            Text(h.displayHeader + (h.countsMatch ? "" : "   (LINE COUNTS DO NOT MATCH)"))
                                .font(Strim.F.mono(.caption)).foregroundStyle(h.countsMatch ? Strim.C.accentText : Strim.C.coral)
                            ForEach(h.lines) { l in
                                HStack(spacing: 6) {
                                    Text(l.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                    Text(l.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                    Text(prefix(l.kind) + l.displayText)
                                }
                                .font(Strim.F.mono(.caption))
                                .foregroundStyle(l.kind == .meta ? Strim.C.muted : Strim.C.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(color(l.kind))
                            }
                        }
                        ForEach(Array(f.strayLines.enumerated()), id: \.offset) { _, l in
                            Text("UNEXPECTED: " + DiffText.visible(l)).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.coral)
                        }
                    }
                }.fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(8)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        }
    }
    private func prefix(_ k: DiffLine.Kind) -> String { k == .added ? "+" : k == .removed ? "-" : " " }
    private func color(_ k: DiffLine.Kind) -> Color { k == .added ? Strim.C.accentFill : k == .removed ? Strim.C.coralFill : .clear }
    private func kindTone(_ k: ChangeKind) -> PillTone {
        switch k { case .modified: .neutral; case .added: .accent; case .deleted: .error; default: .warn }
    }
}

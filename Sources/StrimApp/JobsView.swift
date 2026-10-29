import SwiftUI
import StrimAPI
import StrimAppCore

extension JobStatusDTO {
    var icon: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .awaitingApproval: "hand.raised"
        case .pausedInteractive: "pause.circle"
        case .done: "checkmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "slash.circle"
        case .limit: "gauge.with.needle"
        }
    }
    var label: String {
        switch self {
        case .awaitingApproval: "needs review"
        case .pausedInteractive: "paused"
        default: rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Reference time for relative labels ("1m ago"). Nil (the app) reads the wall clock at render; snapshot tests inject a fixed instant.
private struct StrimNowKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var strimNow: Date? {
        get { self[StrimNowKey.self] }
        set { self[StrimNowKey.self] = newValue }
    }
}

/// Jobs: native list (300 pt) beside the detail.
struct JobsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @Environment(\.layoutClass) private var layout

    var body: some View {
        Group {
            if layout == .compact {
                // One column: the list, and a selected job pushes the detail in place (toolbar "Jobs" goes back).
                if selection == nil { list } else { JobDetailView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                HSplitView {
                    list.frame(minWidth: PaneWidths.jobListMin, idealWidth: PaneWidths.jobListIdeal, maxWidth: PaneWidths.jobListMax)
                    JobDetailView(model: model).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            if layout == .compact, selection != nil {
                ToolbarItem(placement: .navigation) {
                    Button { selection = nil } label: { Label("Jobs", systemImage: "chevron.left") }
                        .help("Back to the job list")
                }
            }
        }
        .onChange(of: selection) { _, new in Task { await model.selectJob(new) } }
        .task { await model.refreshJobs() }
        .onAppear { selection = model.selectedJob?.id }
    }

    private var list: some View {
        let view = model.jobListView
        return VStack(spacing: 0) {
            if view.shown.isEmpty {
                Text(!model.connection.isConnected ? "Server offline: no job list." : view.total == 0 ? "No jobs yet." : "No active or recent jobs.")
                    .font(.system(size: 12)).foregroundStyle(Strim.C.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(view.shown) { j in
                        JobRow(job: j).tag(j.id)
                            .contextMenu {
                                Button("Cancel job", role: .destructive) { Task { await model.cancelJob(j.id) } }
                                    .disabled(!model.cancelJobAvailability(for: j).enabled)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if let footer = model.jobListFooter {
                HStack {
                    Text(footer.countText)
                        .font(.system(size: 11)).foregroundStyle(Strim.C.tertiary)
                    Spacer()
                    if let title = footer.toggleTitle {
                        Button(title) { model.toggleShowAllJobs() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Strim.C.accent)
                            .help("Default view: active jobs and the last 24 hours.")
                    }
                }
                .padding(.horizontal, 14).frame(height: 28)
                .overlay(alignment: .top) { Rectangle().fill(Strim.C.hairline).frame(height: 1) }
            }
        }
        .background(Strim.C.bg)
    }
}

struct JobRow: View {
    let job: JobSummary
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.strimNow) private var strimNow
    private var selected: Bool { prominence == .increased }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.firstSentence(job.title ?? job.id)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(job.source.rawValue) · \(StatsFormat.relative(Date(timeIntervalSince1970: job.started), now: strimNow ?? Date()))")
                    .font(.system(size: 11)).foregroundStyle(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Strim.C.muted)).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Label(job.status.label, systemImage: job.status.icon).font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(job.status == .running ? Strim.C.accent : job.status == .failed ? Strim.C.danger : Strim.C.muted))
                if case .verified? = job.verify { Label("Verified", systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Strim.C.muted)) }
            }
            .labelStyle(.titleAndIcon)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { return String(t[..<r.lowerBound]) }
        return t
    }
}

struct JobDetailView: View {
    @ObservedObject var model: AppModel
    @State private var verifyOpen = false
    @State private var height: CGFloat = 600
    var body: some View {
        Group {
            if let d = model.selectedJob { detail(d) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 24)).foregroundStyle(Strim.C.tertiary)
                    Text("Select a job").font(.system(size: 13)).foregroundStyle(Strim.C.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Strim.C.bg)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    private func detail(_ d: JobDetail) -> some View {
        let av = model.applyAvailability(for: d)
        let rejectAv = model.approveAvailability(for: d)
        let analysis = model.selectedAnalysis
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(d.summary.title ?? d.id).font(.system(size: 15, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    meta("Status") { Label(d.summary.status.label, systemImage: d.summary.status.icon) }
                    if d.summary.verify != nil { meta("Verify") { VerifyBadge(verify: d.summary.verify) } }
                    meta("Source") { Text(d.summary.source.rawValue) }
                    meta("Turns") { Text("\(d.turns)").monospacedDigit() }
                    meta("Local tokens") { Text(StatsFormat.tokens(d.localTokens)).monospacedDigit() }
                    if let c = d.summary.cwd { meta("Folder") { Text((c as NSString).abbreviatingWithTildeInPath).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head) } }
                }
                .font(.system(size: 12))
                if model.showsCancelButton(for: d) {
                    Button("Cancel job", role: .destructive) { Task { await model.cancelJob(d.id) } }.buttonStyle(StrimButtonStyle(.danger))
                }
                if let r = d.resultSummary { Text(r).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if let v = d.verifyOutput, !v.isEmpty {
                    StrimDisclosure(isOpen: $verifyOpen) {
                        Text("Verify output").font(.system(size: 12, weight: .medium)).foregroundStyle(Strim.C.muted)
                    } content: {
                        ScrollView { Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 120).padding(8)
                            .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
                    }
                }
                if let p = d.patch, !p.isEmpty, let analysis {
                    DiffView(analysis: analysis, maxHeight: max(240, height - 320))
                    if analysis.blocked {
                        Label("This patch could not be fully understood. Apply is disabled; you can Reject or inspect the file.", systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(Strim.C.danger).font(.system(size: 12))
                    } else if model.patchChangedSinceReview {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("The patch changed after you opened it. Review the version shown above, then acknowledge.", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Strim.C.text).font(.system(size: 12))
                            Button("I have reviewed the updated patch") { model.acknowledgeUpdatedPatch() }.buttonStyle(StrimButtonStyle(.secondary))
                        }
                    } else if let t = analysis.confirmationText {
                        Toggle(isOn: Binding(get: { model.patchConfirmed }, set: { model.setPatchConfirmed($0) })) {
                            Text("\(t). I have reviewed it and want to apply it.").font(.system(size: 12))
                        }
                    }
                    HStack {
                        Button("Apply") { Task { await model.approve(.apply) } }.buttonStyle(StrimButtonStyle(.primary)).disabled(!av.enabled)
                        Button("Reject") { Task { await model.approve(.reject) } }.buttonStyle(StrimButtonStyle(.secondary)).disabled(!rejectAv.enabled)
                        Button("Copy patch path") { model.copyPatchPath() }.buttonStyle(StrimButtonStyle(.secondary))
                        if let r = av.reason { Text(r).font(.system(size: 11)).foregroundStyle(Strim.C.muted).lineLimit(2) }
                    }
                } else {
                    Text("No patch.").font(.system(size: 12)).foregroundStyle(Strim.C.muted)
                }
            }
            .padding(Strim.S.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func meta<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        GridRow {
            Text(k).foregroundStyle(Strim.C.muted).gridColumnAlignment(.leading)
            v().foregroundStyle(Strim.C.text)
        }
    }
}

// MARK: - Diff (logic unchanged; restyled without green: additions use the accent, removals coral, with +/- signs)

struct DiffView: View {
    let analysis: PatchAnalysis
    /// Grows with the window; never below the old 240 pt cap.
    var maxHeight: CGFloat = 240
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(analysis.summary).font(.caption.bold())
            ForEach(Array(analysis.issues.enumerated()), id: \.offset) { _, i in
                Label(i.reason, systemImage: i.blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(i.blocking ? Strim.C.danger : Strim.C.muted)
            }
            ForEach(analysis.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(Strim.C.muted)
            }
            ForEach(analysis.preamble, id: \.self) { l in
                Text("before first header: " + DiffText.visible(l)).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.danger)
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
                        // Patch approval must show every header row (mode, rename, copy, binary, ---/+++): only plainly
                        // harmless index/similarity rows are collapsed. The per-file path heading is always shown.
                        Text(f.displayPath + "  +\(f.added) -\(f.removed)")
                            .font(Strim.F.mono(.caption, weight: .bold)).padding(.vertical, 4)
                        ForEach(f.headerRows.filter { $0.tag != "index" && $0.tag != "similarity" }) { r in
                            HStack(spacing: 6) {
                                if r.tag != "old file" && r.tag != "new file path" {
                                    Badge(text: r.tag, tone: r.tag == "unknown" ? .error : .neutral).fixedSize()
                                }
                                Text(r.displayText).lineLimit(1)
                            }
                            .font(Strim.F.mono(.caption))
                            .foregroundStyle(r.tag == "old file" || r.tag == "new file path" ? Strim.C.muted : Strim.C.text)
                        }
                        if let t = f.symlinkTarget { Text("symlink target: \(DiffText.visible(t))").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted) }
                        if f.isBinary { Text("binary content (\(f.binaryLineCount) payload lines not shown)").font(.caption).foregroundStyle(Strim.C.muted) }
                        ForEach(f.hunks) { h in
                            Text(h.displayHeader + (h.countsMatch ? "" : "   (LINE COUNTS DO NOT MATCH)"))
                                .font(Strim.F.mono(.caption)).foregroundStyle(h.countsMatch ? Strim.C.muted : Strim.C.danger)
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
                            Text("UNEXPECTED: " + DiffText.visible(l)).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.danger)
                        }
                    }
                }.fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(8)
            }
            .frame(minHeight: 120, maxHeight: maxHeight)
            .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        }
    }
    private func prefix(_ k: DiffLine.Kind) -> String { k == .added ? "+" : k == .removed ? "-" : " " }
    private func color(_ k: DiffLine.Kind) -> Color { k == .added ? Strim.C.accent.opacity(0.14) : k == .removed ? Strim.C.danger.opacity(0.14) : .clear }
    private func kindTone(_ k: ChangeKind) -> PillTone {
        switch k { case .modified: .neutral; case .added: .accent; case .deleted: .error; default: .warn }
    }
}

import SwiftUI
import StrimAPI
import StrimAppCore

struct MainWindow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            TestBanner(model: model)
            TabView {
                StatusTab(model: model).tabItem { Label("Status", systemImage: "gauge") }
                JobsTab(model: model).tabItem { Label("Jobs", systemImage: "list.bullet.rectangle") }
                ChatTab(model: model).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                SettingsTab(model: model).tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}

struct StatusTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.menuTitle, systemImage: model.menuSymbol).font(.title2.bold())
                OfflineBannerView(model: model)
                TokenWarningView(model: model)
                NoticeView(model: model)
                StatsView(model: model)
                if model.connection.isConnected { ControlButtons(model: model) }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct JobsTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                if model.jobs.isEmpty {
                    Text(model.connection.isConnected ? "No jobs yet." : "Host offline: no job list.")
                        .foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    List(model.jobs, selection: $selection) { j in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(j.title ?? j.id).lineLimit(1)
                                Spacer()
                                VerifyBadge(verify: j.verify)
                            }
                            Text("\(j.source.rawValue) | \(j.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }.tag(j.id)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260)
            JobDetailView(model: model).frame(minWidth: 380)
        }
        .onChange(of: selection) { _, new in Task { await model.selectJob(new) } }
        .task { await model.refreshJobs() }
    }
}

struct VerifyBadge: View {
    let verify: VerifyResult?
    var body: some View {
        let (text, color): (String, Color) = switch verify {
        case .verified: ("verified", .green)
        case .failed: ("failed", .red)
        case .unverified: ("unverified", .orange)
        case nil: ("-", .gray)
        }
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}

struct JobDetailView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let d = model.selectedJob {
            let av = model.applyAvailability(for: d)
            let rejectAv = model.approveAvailability(for: d)
            let analysis = model.selectedAnalysis
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(d.summary.title ?? d.id).font(.headline)
                    VerifyBadge(verify: d.summary.verify)
                    Spacer()
                    Text(d.summary.status.rawValue).foregroundStyle(.secondary)
                }
                HStack {
                    let cancel = model.cancelJobAvailability(for: d.summary)
                    Button("Cancel job", role: .destructive) { Task { await model.cancelJob(d.id) } }
                        .disabled(!cancel.enabled).help(cancel.reason ?? "Stop this job")
                    if let r = cancel.reason, !cancel.enabled { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(d.turns) turns | \(StatsFormat.tokens(d.localTokens)) local tokens" + (d.summary.cwd.map { " | \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let r = d.resultSummary { Text(r).font(.callout).textSelection(.enabled) }
                if let v = d.verifyOutput, !v.isEmpty {
                    DisclosureGroup("Verify output") {
                        ScrollView { Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 120)
                    }
                }
                if let p = d.patch, !p.isEmpty, let analysis {
                    DiffView(analysis: analysis)
                    if analysis.blocked {
                        Label("This patch could not be fully understood. Apply is disabled; you can Reject or inspect the file.", systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red).font(.callout)
                    } else if model.patchChangedSinceReview {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("The patch changed after you opened it. Review the version shown above, then acknowledge.", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange).font(.callout)
                            Button("I have reviewed the updated patch") { model.acknowledgeUpdatedPatch() }
                        }
                    } else if let t = analysis.confirmationText {
                        Toggle(isOn: Binding(get: { model.patchConfirmed }, set: { model.setPatchConfirmed($0) })) {
                            Text("\(t). I have reviewed it and want to apply it.").font(.callout)
                        }
                    }
                    HStack {
                        Button("Apply") { Task { await model.approve(.apply) } }.disabled(!av.enabled).buttonStyle(.borderedProminent)
                        Button("Reject") { Task { await model.approve(.reject) } }.disabled(!rejectAv.enabled)
                        Button("Copy patch path") { model.copyPatchPath() }
                        if let r = av.reason { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                } else {
                    Text("No patch.").foregroundStyle(.secondary)
                    Spacer()
                }
            }.padding()
        } else {
            Text("Select a job.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DiffView: View {
    let analysis: PatchAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(analysis.summary).font(.caption.bold())
            ForEach(Array(analysis.issues.enumerated()), id: \.offset) { _, i in
                Label(i.reason, systemImage: i.blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(i.blocking ? .red : .orange)
            }
            ForEach(analysis.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(analysis.preamble, id: \.self) { l in
                Text("before first header: " + DiffText.visible(l)).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
            }
            // file list with change kinds, above the hunks
            VStack(alignment: .leading, spacing: 2) {
                ForEach(analysis.files) { f in
                    HStack(spacing: 6) {
                        ForEach(f.kinds, id: \.rawValue) { k in Badge(text: k.rawValue, color: kindColor(k)) }
                        Text(f.renameTo.map { DiffText.visible(f.renameFrom ?? "") + " -> " + DiffText.visible($0) } ?? f.displayPath)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("+\(f.added) -\(f.removed)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(analysis.files) { f in
                        Text(f.displayPath + "  +\(f.added) -\(f.removed)")
                            .font(.system(.caption, design: .monospaced).bold()).padding(.vertical, 4)
                        ForEach(f.headerRows) { r in
                            HStack(spacing: 6) {
                                Badge(text: r.tag, color: r.tag == "unknown" ? .red : .gray)
                                Text(r.displayText)
                            }.font(.system(.caption, design: .monospaced))
                        }
                        if let t = f.symlinkTarget { Text("symlink target: \(DiffText.visible(t))").font(.system(.caption, design: .monospaced)).foregroundStyle(.orange) }
                        if f.isBinary { Text("binary content (\(f.binaryLineCount) payload lines not shown)").font(.caption).foregroundStyle(.orange) }
                        ForEach(f.hunks) { h in
                            Text(h.displayHeader + (h.countsMatch ? "" : "   (LINE COUNTS DO NOT MATCH)"))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(h.countsMatch ? .blue : .red)
                            ForEach(h.lines) { l in
                                HStack(spacing: 6) {
                                    Text(l.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                    Text(l.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                    Text(prefix(l.kind) + l.displayText)
                                }
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(l.kind == .meta ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(color(l.kind))
                            }
                        }
                        ForEach(Array(f.strayLines.enumerated()), id: \.offset) { _, l in
                            Text("UNEXPECTED: " + DiffText.visible(l)).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                        }
                    }
                }.textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(.separator)
        }
    }
    private func prefix(_ k: DiffLine.Kind) -> String { k == .added ? "+" : k == .removed ? "-" : " " }
    private func color(_ k: DiffLine.Kind) -> Color { k == .added ? .green.opacity(0.18) : k == .removed ? .red.opacity(0.18) : .clear }
    private func kindColor(_ k: ChangeKind) -> Color {
        switch k { case .modified: .gray; case .added: .green; case .deleted: .red; default: .orange }
    }
}

struct Badge: View {
    let text: String, color: Color
    var body: some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}

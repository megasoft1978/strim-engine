import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// 6 pt linear bar; nil value = indeterminate. Same place, same style for every first-run step.
struct StrimProgressBar: View {
    var value: Double?
    var tint: Color = Strim.C.accent
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Strim.C.hairline)
                if let v = value {
                    Capsule().fill(tint).frame(width: max(6, geo.size.width * v))
                } else {
                    Capsule().fill(Strim.C.accent).frame(width: geo.size.width * 0.3)
                        .offset(x: reduceMotion ? geo.size.width * 0.35 : (phase ? geo.size.width * 0.7 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: phase)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .onAppear { phase = true }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "in progress")
    }
}

enum FirstRunStep: Int, CaseIterable {
    case download, verify, start
    var title: String { ["Download", "Verify", "Start"][rawValue] }
}
enum StepMark { case pending, active, paused, done, failed }

struct FirstRunView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    column
                        .frame(width: max(240, min(440, geo.size.width - 32)))
                        // 30% of the height, but short windows (min 460) give the column the room first.
                        .padding(.top, max(24, min(geo.size.height * 0.3 - 40, geo.size.height - 400)))
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var state: ModelDownloadState { model.modelDownloadState }
    private var sizeText: String { ModelDisk.gb(ModelDownloader.modelBytes) }

    private var title: String {
        switch state {
        case .downloading: "Downloading the model"
        case .verifying: "Verifying the model"
        case .startingServer: "Starting the server"
        case .failed: "Download stopped"
        case .needsDownload(_, _, let resumable): resumable ? "Download paused" : "Set up Strim"
        default: "Set up Strim"
        }
    }
    private var subtitle: String {
        "Qwen3.8-27B 4-bit + MTP head · \(sizeText)"
    }

    private func marks() -> [StepMark] {
        switch state {
        case .downloading: [.active, .pending, .pending]
        case .verifying: [.done, .active, .pending]
        case .startingServer: [.done, .done, .active]
        case .failed: [.failed, .pending, .pending]
        case .needsDownload(_, _, true): [.paused, .pending, .pending]
        default: [.pending, .pending, .pending]
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 64 * 0.2237, style: .continuous))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 22, weight: .semibold)).padding(.top, 16)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Strim.C.muted).padding(.top, 6).lineLimit(1)
            steps.padding(.top, 20)
            Group {
                switch state {
                case .needsDownload(let size, let free, let resumable): needs(size: size, free: free, resumable: resumable)
                case .confirming: needs(size: ModelDownloader.modelBytes, free: model.modelDownloader.availableFreeBytes, resumable: false)
                case .downloading(let p): downloading(p)
                case .verifying(let f): verifying(f)
                case .startingServer: starting
                case .failed(let m, let r): failed(m, resumable: r)
                default: EmptyView()
                }
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Download \(sizeText) from Hugging Face?", isPresented: Binding(
            get: { if case .confirming = state { true } else { false } },
            set: { if !$0 { model.dismissModelDownloadConfirmation() } }), titleVisibility: .visible) {
            Button("Download") { model.beginModelDownload() }
            Button("Cancel", role: .cancel) { model.dismissModelDownloadConfirmation() }
        }
    }

    private var steps: some View {
        let m = marks()
        return VStack(spacing: 0) {
            ForEach(FirstRunStep.allCases, id: \.rawValue) { s in
                HStack(spacing: 10) {
                    glyph(m[s.rawValue]).frame(width: 16, height: 16)
                    Text(s.title).font(.system(size: 13, weight: m[s.rawValue] == .active ? .semibold : .regular))
                        .foregroundStyle(m[s.rawValue] == .pending ? Strim.C.muted : Strim.C.text)
                    Spacer()
                }
                .frame(height: 28)
                .accessibilityElement(children: .combine)
                .accessibilityValue(["pending", "in progress", "paused", "done", "failed"][[StepMark.pending, .active, .paused, .done, .failed].firstIndex(of: m[s.rawValue])!])
            }
        }
    }
    @ViewBuilder private func glyph(_ m: StepMark) -> some View {
        switch m {
        case .pending: Circle().strokeBorder(Strim.C.tertiary, lineWidth: 1.5).frame(width: 12, height: 12)
        case .active: Circle().fill(Strim.C.accent).frame(width: 10, height: 10)
        case .paused: Image(systemName: "pause.circle").font(.system(size: 14)).foregroundStyle(Strim.C.muted)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Strim.C.muted)
        case .failed: Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Strim.C.danger)
        }
    }

    // MARK: states

    private func needs(size: Int64, free: Int64, resumable: Bool) -> some View {
        let need = size + ModelDownloader.reserveBytes
        let missing = need - free
        let low = missing > 0
        return VStack(alignment: .leading, spacing: 12) {
            if resumable, let f = model.modelDownloader.pausedFraction {
                StrimProgressBar(value: f, tint: Strim.C.tertiary)
                Text("Paused at \(Int(f * 100))%. Downloaded parts are kept.").font(.system(size: 12)).foregroundStyle(Strim.C.muted)
            } else {
                Text("Downloads once and never leaves your machine · \(ModelDisk.gb(free)) free")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Strim.C.muted)
            }
            if low {
                Text("Needs \(ModelDisk.gb(need)) free; \(ModelDisk.gb(missing)) more required.")
                    .font(.system(size: 12)).foregroundStyle(Strim.C.text)
            }
            HStack(spacing: 10) {
                Button { model.confirmModelDownload() } label: {
                    Text(resumable ? "Resume" : "Download \(ModelDisk.gb(size))")
                }
                .buttonStyle(StrimButtonStyle(.primary, large: true)).disabled(low)
                if low {
                    Button("Open Storage Settings…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(u) }
                    }.buttonStyle(StrimButtonStyle(.secondary, large: true))
                }
            }
        }
    }

    static func fileIndex(_ f: String) -> (Int, Int)? {
        guard let r = f.range(of: #"(\d+)-of-(\d+)"#, options: .regularExpression) else { return nil }
        let p = f[r].components(separatedBy: "-of-")
        guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
        return (a, b)
    }

    private func downloading(_ p: ModelDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Int(p.fraction * 100))%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer()
                Text("\(String(format: "%.1f", Double(p.doneBytes) / 1e9)) of \(ModelDisk.gb(p.totalBytes))")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Strim.C.muted)
            }
            StrimProgressBar(value: p.fraction)
            Text(downloadDetail(p)).font(.system(size: 11)).foregroundStyle(Strim.C.muted)
            Button("Pause") { model.cancelModelDownload() }.buttonStyle(StrimButtonStyle(.secondary)).padding(.top, 8)
            Text("You can close this window. The download continues and Strim stays in the menu bar.")
                .font(.system(size: 11)).foregroundStyle(Strim.C.tertiary).padding(.top, 4)
        }
    }
    private func downloadDetail(_ p: ModelDownloadProgress) -> String {
        var parts = [String(format: "%.1f MB/s", p.bytesPerSec / 1e6)]
        parts.append(p.etaSec.map { "about \(Self.eta($0)) left" } ?? "estimating time")
        if let (i, n) = Self.fileIndex(p.file) { parts.append("file \(i) of \(n)") }
        return parts.joined(separator: " · ")
    }
    static func eta(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int((s / 60).rounded())) min" : String(format: "%.1f h", s / 3600)
    }

    private func verifying(_ f: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let (i, n) = Self.fileIndex(f) {
                Text("Verifying file \(i) of \(n)").font(.system(size: 13, weight: .semibold))
                StrimProgressBar(value: Double(i) / Double(max(n, 1)))
            } else {
                Text("Verifying files").font(.system(size: 13, weight: .semibold))
                StrimProgressBar(value: nil)
            }
        }
    }

    private var starting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loading \(model.modelWeightsText) of weights into memory").font(.system(size: 13, weight: .semibold))
            StrimProgressBar(value: nil)
        }
    }

    private func failed(_ message: String, resumable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Retry") { model.retryModelDownload() }.buttonStyle(StrimButtonStyle(.primary, large: true))
                Button("Copy error") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message, forType: .string) }
                    .buttonStyle(StrimButtonStyle(.secondary, large: true))
            }
        }
    }
}

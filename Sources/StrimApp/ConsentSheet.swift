import SwiftUI
import StrimAPI
import StrimAppCore

/// The consent step for working in a folder outside the host's allowed folders. Shown only after an explicit user
/// action (Open Folder, drop, Recent, Locate, Grant access); Allow is a click, never a default key.
struct ConsentSheet: View {
    let consent: FolderConsent
    let allow: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Strim.S.lg) {
            HStack(alignment: .top, spacing: Strim.S.md) {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 22)).foregroundStyle(Strim.C.muted).frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(consent.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(FolderConsent.detail).font(.system(size: 12)).foregroundStyle(Strim.C.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(PathDisplay.tilde(consent.path, maxLength: 64)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Strim.C.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .padding(.horizontal, Strim.S.md).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(Strim.C.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if let e = consent.error {
                Label(e, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Strim.C.danger)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel).buttonStyle(StrimButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button(consent.working ? "Allowing…" : "Allow", action: allow).buttonStyle(StrimButtonStyle(.primary))
                    .disabled(consent.working)
                    .accessibilityHint("Lets Strim read, change files and run commands in this folder, in an isolated copy")
            }
        }
        .padding(Strim.S.xl)
        .frame(width: 440)
        .background(Strim.C.bg)
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI
import StrimAppCore

/// Collapsible block with a chevron header (reasoning, tool cards, verify output). The header is one button, so it is
/// keyboard and VoiceOver reachable; the chevron plus the expanded content show the state, not colour.
struct StrimDisclosure<Label: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(Strim.C.muted).frame(width: 10)
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen { content() }
        }
    }
}

/// Diagnostics strip (only shown when the host is not ready or in test mode): one line, expandable.
struct DiagnosticsStrip: View {
    @ObservedObject var model: AppModel
    @State private var open = false
    var body: some View {
        if model.showTestBanner {
            VStack(alignment: .leading, spacing: 4) {
                StrimDisclosure(isOpen: $open) {
                    Text("diagnostics").font(Strim.F.label()).tracking(1).foregroundStyle(Strim.C.muted)
                    Text("state \(model.rawState)  ·  last event \(StatsFormat.relative(model.lastEventTime, now: Date()))  ·  error \(model.lastError ?? "none")")
                        .font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted).lineLimit(1)
                } content: {
                    Text(model.eventLogTail.isEmpty ? "(no events yet)" : model.eventLogTail.joined(separator: "\n"))
                        .font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted).textSelection(.enabled)
                        .padding(.leading, 16)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Strim.C.field)
        }
    }
}

import SwiftUI
import StrimAppCore

/// Collapsible block with a chevron header (reasoning, tool rows, verify output). The header is one button, so it is
/// keyboard and VoiceOver reachable; the chevron plus the expanded content show the state, not colour.
struct StrimDisclosure<Label: View, Content: View>: View {
    @Binding var isOpen: Bool
    var spacing: CGFloat = 8
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(Strim.C.tertiary).frame(width: 10)
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

import SwiftUI

/// Collapsed-by-default disclosure row for a `<think>...</think>` segment. Custom (not native
/// `DisclosureGroup`) so it matches Vasa's own chrome styling.
struct ThinkingBlockView: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
                AppSounds.playTap()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Thinking")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.secondaryInk(scheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk(scheme).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)
            }
        }
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

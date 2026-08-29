import SwiftUI

/// Mirrors the composer's text into an invisible `Text` to measure its natural height, so the
/// `TextEditor` can grow with the content instead of staying pinned at one cramped line count.
private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChatComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Binding var text: String
    let isStreaming: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private let minHeight: CGFloat = 56
    private let maxHeight: CGFloat = 220
    @State private var measuredHeight: CGFloat = 56

    private var editorHeight: CGFloat {
        min(max(measuredHeight, minHeight), maxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: editorHeight)
                    .padding(6)
                    .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(isStreaming)
                    .background(heightMeasurer)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Ask a question…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                Button {
                    if isStreaming {
                        onStop()
                    } else {
                        onSend()
                    }
                } label: {
                    Group {
                        if isStreaming {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .semibold))
                        } else {
                            Text("Ask")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        (isStreaming || canSend) ? Theme.ink : Theme.ink.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isStreaming && !canSend)
                .help(isStreaming ? "Stop" : "Send")
            }
        }
        .padding(12)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline(scheme)).frame(height: 1)
        }
    }

    private var heightMeasurer: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 13))
            .padding(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260) // approximate composer width minus the send button/padding
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ComposerHeightKey.self, value: proxy.size.height)
                }
            )
            .hidden()
            .onPreferenceChange(ComposerHeightKey.self) { measuredHeight = $0 }
    }
}

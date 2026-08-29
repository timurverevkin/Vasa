import SwiftUI

/// Vasa-styled chat bubble: assistant messages float in a translucent `.chromePill`, user
/// messages sit in a solid `Theme.ink` fill with white text — never the default SwiftUI
/// chat-bubble look.
struct ChatBubbleView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                    elementView(element)
                }
                if message.isStreaming, elements.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let errorText = message.errorText {
                    Text(errorText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.19))
                } else if !message.isStreaming, elements.isEmpty, message.errorText == nil {
                    // Defensive fallback — a bubble must never render as literally nothing.
                    Text("No response.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk(scheme))
                }
                if !isUser, !message.isStreaming, !plainText.isEmpty {
                    Button {
                        _ = app.placeAINote(body: VasaAIPrompt.sanitizeNoteHTML(plainText))
                        AppSounds.playTap()
                    } label: {
                        HStack(spacing: 4) {
                            AppIconView(icon: .turnIntoNote, size: 11)
                            Text("Place on board")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryInk(scheme))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(
                isUser ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .modifier(AssistantChrome(isUser: isUser))
            .frame(maxWidth: 280, alignment: .leading)
            if !isUser { Spacer(minLength: 24) }
        }
    }

    /// Text with `<think>` blocks stripped — the placed note shouldn't include reasoning.
    private var plainText: String {
        elements.compactMap { element -> String? in
            switch element {
            case .text(let t): return t
            case .code(_, let body): return body
            case .list(let items, let ordered):
                return items.enumerated()
                    .map { i, item in ordered ? "\(i + 1). \(item)" : "- \(item)" }
                    .joined(separator: "\n")
            case .thinking: return nil
            }
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var elements: [MessageElement] {
        IncrementalMessageParser.parse(message.text)
    }

    @ViewBuilder
    private func elementView(_ element: MessageElement) -> some View {
        switch element {
        case .text(let t):
            Text(Self.inlineMarkdown(t))
                .font(.system(size: 13))
                .foregroundStyle(isUser ? Color.white : Theme.primaryInk(scheme))
                .tint(isUser ? Color.white : Theme.primaryInk(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(.system(size: 13, weight: ordered ? .regular : .bold))
                            .foregroundStyle(isUser ? Color.white : Theme.secondaryInk(scheme))
                            .frame(minWidth: ordered ? 16 : 10, alignment: .leading)
                        Text(Self.inlineMarkdown(item))
                            .font(.system(size: 13))
                            .foregroundStyle(isUser ? Color.white : Theme.primaryInk(scheme))
                            .tint(isUser ? Color.white : Theme.primaryInk(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if !lang.isEmpty {
                        Text(lang)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondaryInk(scheme))
                    }
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(body, forType: .string)
                        AppSounds.playTap()
                    } label: {
                        AppIconView(icon: .copy, size: 11)
                            .foregroundStyle(Theme.secondaryInk(scheme))
                    }
                    .buttonStyle(.plain)
                }
                Text(body)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(isUser ? Color.white : Theme.primaryInk(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .thinking(let text):
            ThinkingBlockView(text: text)
        }
    }

    /// Renders `**bold**`, `*italic*`/`_italic_`, `` `code` ``, and `[label](url)` links via
    /// SwiftUI's native Markdown parser. Falls back to plain text if the string doesn't parse
    /// (malformed AI output should never crash or blank out a bubble).
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Assistant bubbles get the floating `.chromePill`; user bubbles just keep their solid ink fill.
private struct AssistantChrome: ViewModifier {
    let isUser: Bool
    func body(content: Content) -> some View {
        if isUser {
            content
        } else {
            content.chromePill(14)
        }
    }
}

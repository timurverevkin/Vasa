import SwiftUI

/// Replaces the old single-shot `AskAIPanel`. Same overlay shell (dimmer + trailing-anchored
/// panel, 340x480, chrome styling) but hosts a scrollable multi-turn `ChatMessage` list with a
/// pinned `ChatComposer`, backed by `AppModel.chatThreads[lessonId]`.
struct ChatPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var streamingMessageID: String?
    @State private var didSeed = false

    private var lessonId: String? { app.activeLesson?.id }

    private var sources: [TextAskSource] {
        app.textAskSources(preferring: app.askAICardID)
    }

    private var thread: ChatThread? {
        guard let lessonId else { return nil }
        return app.chatThreads[lessonId]
    }

    /// Derived from the thread's own `isStreaming` flag, not just this view's local
    /// `streamingMessageID` — a reply keeps streaming in the background after the panel is
    /// closed (see `close()`), so reopening must still reflect the true in-flight state.
    private var isStreaming: Bool {
        thread?.messages.contains { $0.isStreaming } ?? false
    }

    private var panelFill: Color {
        scheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.96)
            : Color.white.opacity(0.96)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.28 : 0.04)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Rectangle().fill(Theme.hairline(scheme)).frame(height: 1)
                        messageList
                        ChatComposer(
                            text: $draft,
                            isStreaming: isStreaming,
                            canSend: canSend,
                            onSend: { Task { await send() } },
                            onStop: stop
                        )
                    }
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(panelFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline(scheme)))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 20, y: 8)
                    .padding(.trailing, 16)
                    .padding(.top, 56)
                    .padding(.bottom, 16)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .allowsHitTesting(true)
        .onAppear(perform: seedIfNeeded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(icon: .askAI, size: 12)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Ask AI")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryInk(scheme))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(16)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let thread, !thread.messages.isEmpty {
                        ForEach(thread.messages) { message in
                            ChatBubbleView(message: message).id(message.id)
                        }
                    } else {
                        emptyState
                    }
                    if !hasToken {
                        tokenHint
                    }
                }
                .padding(16)
            }
            .onChange(of: thread?.messages.last?.text) { _, _ in
                if let last = thread?.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
            if sources.isEmpty {
                Text("Select one or more text or note cards on the canvas, or just start typing below.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(sources) { source in
                    Text(source.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryInk(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var tokenHint: some View {
        HStack(spacing: 8) {
            Text("Add an API key in Settings.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Settings") {
                close()
                app.library.sidebarOpen = true
                app.settingsOpen = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.primaryInk(scheme))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var activeProvider: AIProviderConfig {
        app.settings.aiProviders.first { $0.id == app.settings.activeProviderId }
            ?? ProviderCatalog.defaults[0]
    }

    private var hasToken: Bool { ChatKeychain.hasToken(activeProvider.id) }

    private var canSend: Bool {
        streamingMessageID == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasToken
    }

    private func seedIfNeeded() {
        guard !didSeed, let lessonId else { return }
        didSeed = true
        app.startOrContinueChat(lessonId: lessonId)
        if draft.isEmpty, !sources.isEmpty {
            let quoted = sources.map { "> \($0.snippet)" }.joined(separator: "\n\n")
            draft = quoted + "\n\n"
        }
    }

    /// Closing the panel must NOT cancel an in-flight reply — `streamTask` is a plain `Task`
    /// (not the `.task` view modifier), so it keeps running and updating `app.chatThreads` in
    /// the background even after this view disappears; reopening the panel picks the finished
    /// (or still-streaming) message back up. Only the explicit "Stop" button cancels.
    private func close() {
        app.askAICardID = nil
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        if let lessonId, let id = streamingMessageID {
            app.updateChatThread(lessonId: lessonId) { thread in
                if let idx = thread.messages.firstIndex(where: { $0.id == id }) {
                    thread.messages[idx].isStreaming = false
                }
            }
        }
        streamingMessageID = nil
    }

    @MainActor
    private func send() async {
        guard let lessonId, canSend else {
            AppSounds.play(.disabled)
            return
        }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        AppSounds.play(.notification)

        app.updateChatThread(lessonId: lessonId) { thread in
            thread.messages.append(ChatMessage(role: .user, text: question))
            thread.providerId = activeProvider.id
            thread.model = activeProvider.defaultModel
        }

        let assistantID = VasaID.make("msg")
        app.updateChatThread(lessonId: lessonId) { thread in
            thread.messages.append(
                ChatMessage(id: assistantID, role: .assistant, text: "", providerId: activeProvider.id, model: activeProvider.defaultModel, isStreaming: true)
            )
        }
        streamingMessageID = assistantID

        let history: [RequestMessage] = (app.chatThreads[lessonId]?.messages ?? [])
            .filter { $0.id != assistantID }
            .map { RequestMessage(role: $0.role, content: $0.text) }
        let handler = APIServiceFactory.handler(for: activeProvider)
        let apiKey = ChatKeychain.load(activeProvider.id)
        let settings = GenerationSettings(model: activeProvider.defaultModel)

        streamTask = Task {
            var accumulated = ""
            var caughtError: String?
            do {
                let stream = handler.sendMessageStream(
                    history: history,
                    systemPrompt: VasaChatPrompt.instructions,
                    settings: settings,
                    apiKey: apiKey
                )
                for try await delta in stream {
                    guard !Task.isCancelled else { break }
                    if let text = delta.text {
                        accumulated += text
                        let snapshot = Self.liveDisplayText(accumulated)
                        app.updateChatThread(lessonId: lessonId) { thread in
                            if let idx = thread.messages.firstIndex(where: { $0.id == assistantID }) {
                                thread.messages[idx].text = snapshot
                            }
                        }
                    }
                }
            } catch {
                caughtError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            let directive = caughtError == nil ? AppModel.extractArrangeDirective(from: accumulated) : nil
            let cardsDirective = caughtError == nil ? AppModel.extractCardsDirective(from: accumulated) : nil
            // Both directives are stripped from the same raw `accumulated` text, so checking one
            // never prevents detecting the other; strip whichever fired (a reply should only ever
            // contain one hidden directive, but this keeps the strip correct either way).
            let finalText = cardsDirective?.clean ?? directive?.clean ?? accumulated
            // A provider can end its stream with no error and no text (e.g. the gateway silently
            // drops an oversized/unusual request) — without this, the bubble renders as a
            // literally empty, invisible chrome pill instead of telling the user anything failed.
            if caughtError == nil, finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                caughtError = "Empty response from the provider — try again or shorten the message."
            }
            app.updateChatThread(lessonId: lessonId) { thread in
                if let idx = thread.messages.firstIndex(where: { $0.id == assistantID }) {
                    thread.messages[idx].text = finalText
                    thread.messages[idx].isStreaming = false
                    thread.messages[idx].errorText = caughtError
                }
            }
            if caughtError != nil {
                AppSounds.play(.caution)
            } else {
                AppSounds.play(.celebration)
            }
            streamingMessageID = nil

            if let cardsDirective {
                let created = app.createCardsFromChat(cardsDirective.specs)
                AppSounds.play(created > 0 ? .celebration : .caution)
            }

            if let directive {
                let lesson = app.library.lessons.first { $0.id == lessonId }
                let ids = app.selectedIDs.count >= 2 ? app.selectedIDs : lesson.map { app.allArrangeableCardIDs(in: $0) } ?? []
                if ids.count >= 2 {
                    await app.arrangeWithAI(criterion: directive.criterion, targetOverride: (ids, nil))
                }
            }
        }
    }

    /// While a reply is still streaming, hide anything from the last unclosed (or just-closed)
    /// `<<` marker onward, so a `<<ARRANGE: ...>>`/`<<CARDS: [...]>>` directive never flashes on
    /// screen character-by-character as it streams in — only the final, fully-stripped text
    /// (computed once the stream finishes, in `send()`) is ever the message users read once done.
    private static func liveDisplayText(_ raw: String) -> String {
        guard let range = raw.range(of: "<<", options: .backwards) else { return raw }
        return String(raw[..<range.lowerBound])
    }
}

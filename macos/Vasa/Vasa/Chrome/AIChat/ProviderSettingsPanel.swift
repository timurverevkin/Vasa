import SwiftUI

/// Dedicated floating window for AI provider configuration, opened from the compact
/// "Provider" row in `SettingsView`. Gives each preset (Giga / DeepSeek / OpenAI / Claude)
/// room to breathe instead of squeezing three-plus names into a 252pt-wide segmented control.
struct ProviderSettingsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var apiKeyDraft: String = ""
    @State private var savedPulse = false
    @State private var savedHideTask: Task<Void, Never>?
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var logsExpanded = false
    private let log = AIChatDebugLog.shared

    private enum TestState: Equatable {
        case idle, running, success, failed(String)
    }

    private var providers: [AIProviderConfig] { app.settings.aiProviders }

    private var activeIndex: Int? {
        providers.firstIndex { $0.id == app.settings.activeProviderId }
    }

    private var active: AIProviderConfig {
        activeIndex.map { providers[$0] } ?? ProviderCatalog.defaults[0]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.45 : 0.28)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        presetList
                        Divider().overlay(Theme.hairline(scheme))
                        configFields
                        Divider().overlay(Theme.hairline(scheme))
                        testConnectionRow
                        Divider().overlay(Theme.hairline(scheme))
                        logsSection
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
            .frame(width: 360)
            .frame(maxHeight: 640)
            .background(
                scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.18) : Color.white,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline(scheme)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 24, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { apiKeyDraft = ChatKeychain.load(active.id) }
    }

    private var header: some View {
        HStack {
            Label {
                Text("AI Provider")
            } icon: {
                AppIconView(icon: .askAI, size: 13)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.primaryInk(scheme))
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRESET")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk(scheme))
            VStack(spacing: 4) {
                ForEach(providers) { provider in
                    presetRow(provider)
                }
            }
        }
    }

    private func presetRow(_ provider: AIProviderConfig) -> some View {
        let selected = provider.id == active.id
        return Button {
            guard !selected else { return }
            AppSounds.playTap()
            app.settings.activeProviderId = provider.id
            apiKeyDraft = ChatKeychain.load(provider.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryInk(scheme))
                    Text(provider.baseURL)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(Theme.secondaryInk(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(scheme == .dark ? Color.white : Theme.select)
                } else if ChatKeychain.hasToken(provider.id) {
                    Circle().fill(Theme.lime).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                selected ? Theme.elevHover(scheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.hairline(scheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var configFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(active.displayName.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk(scheme))

            labeledField("Base URL") {
                TextField("Base URL", text: Binding(
                    get: { active.baseURL },
                    set: { newValue in
                        guard let idx = activeIndex else { return }
                        app.settings.aiProviders[idx].baseURL = newValue
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11).monospaced())
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.primaryInk(scheme))
                    Spacer()
                    if savedPulse {
                        Label("Saved", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.lime)
                            .transition(.opacity)
                    }
                }
                SecureField("API key", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11).monospaced())
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onChange(of: apiKeyDraft) { _, value in
                        ChatKeychain.save(active.id, token: value)
                        flashSaved()
                    }
            }

            if active.availableModels.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.primaryInk(scheme))
                    Segmented(
                        options: active.availableModels.map { ($0, $0) },
                        value: active.defaultModel
                    ) { model in
                        guard let idx = activeIndex else { return }
                        app.settings.aiProviders[idx].defaultModel = model
                    }
                }
            }

            Button {
                resetToPreset()
            } label: {
                Text("Reset to preset default")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Text(providerHint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primaryInk(scheme))
            field()
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func resetToPreset() {
        guard let idx = activeIndex,
              let preset = ProviderCatalog.defaults.first(where: { $0.id == active.id })
        else { return }
        app.settings.aiProviders[idx].baseURL = preset.baseURL
        app.settings.aiProviders[idx].defaultModel = preset.defaultModel
        app.settings.aiProviders[idx].availableModels = preset.availableModels
    }

    private var testConnectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    Text(testState == .running ? "Testing…" : "Test connection")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(testState == .running)

                statusDot
                statusMessage
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch testState {
        case .idle: EmptyView()
        case .running:
            Circle().fill(Theme.secondaryInk(scheme)).frame(width: 7, height: 7)
        case .success:
            Circle().fill(Theme.lime).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Theme.extractStroke).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch testState {
        case .idle: EmptyView()
        case .running:
            Text("Sending a ping…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk(scheme))
        case .success:
            Text("Reachable")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryInk(scheme))
        case .failed(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.extractStroke)
                .lineLimit(2)
        }
    }

    private func runTest() {
        testTask?.cancel()
        testState = .running
        let config = active
        let apiKey = ChatKeychain.load(config.id)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testState = .failed(APIError.missingToken.localizedDescription)
            return
        }
        testTask = Task {
            let handler = APIServiceFactory.handler(for: config)
            let settings = GenerationSettings(model: config.defaultModel)
            var gotText = false
            do {
                let stream = handler.sendMessageStream(
                    history: [RequestMessage(role: .user, content: "ping")],
                    systemPrompt: "Reply with just: OK",
                    settings: settings,
                    apiKey: apiKey
                )
                for try await delta in stream {
                    guard !Task.isCancelled else { return }
                    if let text = delta.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        gotText = true
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                AppSounds.play(.caution)
                return
            }
            guard !Task.isCancelled else { return }
            if gotText {
                testState = .success
                AppSounds.play(.celebration)
            } else {
                testState = .failed("Empty response from the provider.")
                AppSounds.play(.caution)
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                AppSounds.playTap()
                logsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: logsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Logs")
                        .font(.system(size: 10, weight: .semibold))
                    if !log.lines.isEmpty {
                        Text("\(log.lines.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondaryInk(scheme))
                    }
                    Spacer()
                    if logsExpanded, !log.lines.isEmpty {
                        Button {
                            log.clear()
                            AppSounds.playTap()
                        } label: {
                            Text("Clear")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.secondaryInk(scheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Theme.secondaryInk(scheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if logsExpanded {
                if log.lines.isEmpty {
                    Text("No requests yet — send a chat message or run a test to populate this.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(log.lines.enumerated().reversed()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 9).monospaced())
                                    .foregroundStyle(Theme.secondaryInk(scheme))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .padding(8)
                    .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func close() {
        testTask?.cancel()
        app.providerSettingsOpen = false
    }

    private func flashSaved() {
        savedHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { savedPulse = true }
        savedHideTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { savedPulse = false }
        }
    }

    private var providerHint: String {
        switch active.kind {
        case .openAICompatible where active.id == "giga":
            return "Our GigaTool gateway · /chat/completions · \(active.defaultModel)"
        case .openAICompatible:
            return "Uses /chat/completions · \(active.defaultModel)"
        case .anthropic:
            return "Uses /v1/messages · \(active.defaultModel)"
        }
    }
}

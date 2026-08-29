import SwiftUI

/// Compact "Ask AI" row inside `SettingsView`'s narrow (252pt) panel: shows the active
/// provider and opens `ProviderSettingsPanel` — a dedicated window with room for presets
/// (Giga / DeepSeek / OpenAI / Claude) and per-provider config — instead of squeezing
/// everything into this sidebar.
struct ChatProviderSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    private var active: AIProviderConfig {
        app.settings.aiProviders.first { $0.id == app.settings.activeProviderId }
            ?? ProviderCatalog.defaults[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Ask AI")
            } icon: {
                AppIconView(icon: .askAI, size: 13)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.primaryInk(scheme))

            Button {
                AppSounds.playTap()
                app.providerSettingsOpen = true
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Provider")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.primaryInk(scheme))
                        Text(active.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryInk(scheme))
                    }
                    Spacer()
                    if !ChatKeychain.hasToken(active.id) {
                        Text("No key")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.extractStroke)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

import Foundation

/// Thin shim kept for `ProviderCatalog` defaults and the legacy-token migration.
/// The one-shot `ask(...)` request has been replaced by `ChatGPTHandler` (streaming, multi-turn)
/// — see `Models/AIChat/`.
enum DeepSeekProvider {
    static let defaultBaseURL = "https://gw.gigatool.app/deepseek"
    static let model = "deepseek-v4-pro"
}

/// Legacy UserDefaults-backed token store. Read once by `ChatKeychain.migrateLegacyDeepSeekTokenIfNeeded()`
/// on launch, then cleared — real storage is now `ChatKeychain` (Security framework Keychain).
enum DeepSeekTokenStore {
    private static let defaultsKey = "vasa.deepseek.apiToken"

    static func loadToken() -> String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    static func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }
}

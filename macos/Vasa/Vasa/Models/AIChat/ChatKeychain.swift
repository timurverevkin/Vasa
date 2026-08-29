import Foundation
import Security

/// Security-framework Keychain wrapper for provider API keys, replacing the old
/// UserDefaults-backed `DeepSeekTokenStore`.
enum ChatKeychain {
    private static let service = "app.vasa.aiProviders"
    private static func account(_ providerId: String) -> String { "apiKey.\(providerId)" }

    /// `giga-vision` bills against the same GigaTool install token as `giga` — never has its
    /// own Keychain entry, always reads/writes through the `giga` account.
    static func effectiveProviderId(_ providerId: String) -> String {
        providerId == "giga-vision" ? "giga" : providerId
    }

    static func load(_ providerId: String) -> String {
        let providerId = effectiveProviderId(providerId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static func save(_ providerId: String, token: String) {
        let providerId = effectiveProviderId(providerId)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerId),
        ]
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    static func hasToken(_ providerId: String) -> Bool {
        !load(providerId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One-time migration of the old UserDefaults-backed token into the Keychain, under the
    /// "giga" provider id (the old single hardcoded provider was the GigaTool gateway).
    static func migrateLegacyDeepSeekTokenIfNeeded() {
        guard load("giga").isEmpty else { return }
        let old = DeepSeekTokenStore.loadToken()
        guard !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save("giga", token: old)
        DeepSeekTokenStore.saveToken("")
    }
}

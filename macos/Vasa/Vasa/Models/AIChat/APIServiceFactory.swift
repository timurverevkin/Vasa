import Foundation

@MainActor
enum APIServiceFactory {
    static func handler(for config: AIProviderConfig) -> APIService {
        switch config.kind {
        case .openAICompatible:
            return ChatGPTHandler(config: config)
        case .anthropic:
            return ClaudeHandler(config: config)
        }
    }
}

extension ProviderCatalog {
    /// GigaTool's GigaChat backend — used ONLY by the arrange/auto-tag feature for image cards,
    /// since the "giga" (DeepSeek) gateway route has no vision support. Same gateway host and
    /// bearer token as "giga" (both bill against one GigaTool install token) — NOT a user-facing
    /// provider choice, so it's kept out of `defaults`/`ProviderSettingsPanel`.
    /// Model id confirmed real: GigaChat 3.5 (`GigaChat-3.5-432B-A28B`) — 131072 context,
    /// text+image+pdf input, `attachment: true` (vision-capable). GigaChat-3-Ultra is
    /// superseded by 3.5 and intentionally not offered here.
    static let gigaVision = AIProviderConfig(
        id: "giga-vision", kind: .openAICompatible, displayName: "GigaChat (vision)",
        baseURL: "https://gw.gigatool.app/gigachat", defaultModel: "GigaChat-3.5-432B-A28B",
        availableModels: ["GigaChat-3.5-432B-A28B"]
    )
}

enum ProviderCatalog {
    /// Presets shown in `ProviderSettingsPanel`. "Giga" is our own GigaTool gateway
    /// (`gw.gigatool.app`, standard Chat Completions shaped, no `/v1`) — distinct from talking to DeepSeek's
    /// official API directly.
    static let defaults: [AIProviderConfig] = [
        AIProviderConfig(
            id: "deepseek", kind: .openAICompatible, displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com", defaultModel: "deepseek-chat",
            availableModels: ["deepseek-chat", "deepseek-reasoner"]
        ),
        AIProviderConfig(
            id: "openai", kind: .openAICompatible, displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini",
            availableModels: ["gpt-4o", "gpt-4o-mini", "o3-mini"]
        ),
        AIProviderConfig(
            id: "claude", kind: .anthropic, displayName: "Claude",
            baseURL: "https://api.anthropic.com", defaultModel: "claude-3-5-sonnet-latest",
            availableModels: ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest"]
        ),
        AIProviderConfig(
            id: "giga", kind: .openAICompatible, displayName: "Giga",
            baseURL: DeepSeekProvider.defaultBaseURL, defaultModel: DeepSeekProvider.model,
            availableModels: [DeepSeekProvider.model]
        ),
    ]
}

import Foundation

enum ProviderKind: String, Codable {
    case openAICompatible
    case anthropic
}

struct AIProviderConfig: Codable, Identifiable, Equatable {
    var id: String
    var kind: ProviderKind
    var displayName: String
    var baseURL: String
    var defaultModel: String
    var availableModels: [String]
}

enum APIError: LocalizedError {
    case missingToken
    case badURL
    case http(Int, String)
    case decode
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add an API key in Settings."
        case .badURL:
            return "Invalid provider base URL."
        case .http(let code, let body):
            let clip = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if clip.isEmpty { return "Provider error (\(code))." }
            return "Provider error (\(code)): \(String(clip.prefix(180)))"
        case .decode:
            return "Could not read provider response."
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Public stream delta — thinking segments are already merged into `text` as
/// `<think>...</think>` by `BaseAPIHandler`, so downstream code never needs provider-specific logic.
struct StreamDelta: Equatable {
    var text: String?
    var toolCalls: [ToolCall]?
    var isFinal: Bool = false
}

@MainActor
protocol APIService: AnyObject {
    var config: AIProviderConfig { get }
    func sendMessageStream(
        history: [RequestMessage],
        systemPrompt: String,
        settings: GenerationSettings,
        apiKey: String
    ) -> AsyncThrowingStream<StreamDelta, Error>
}

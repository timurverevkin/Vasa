import Foundation

/// Anthropic Messages API (`POST {base}/v1/messages`), streaming.
@MainActor
final class ClaudeHandler: BaseAPIHandler {
    override func buildRequest(
        history: [RequestMessage],
        systemPrompt: String,
        settings: GenerationSettings,
        apiKey: String
    ) throws -> URLRequest {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError.missingToken }

        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = config.baseURL }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/messages") else { throw APIError.badURL }

        // Anthropic's system prompt is a top-level field; any system-role entries in history
        // (there shouldn't normally be any beyond the caller's own systemPrompt) get folded in too.
        var systemParts = [systemPrompt]
        let nonSystem = history.filter { msg in
            if msg.role == .system {
                systemParts.append(msg.content)
                return false
            }
            return true
        }
        let messages = nonSystem.map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": settings.maxTokens ?? 4096,
            "system": systemParts.joined(separator: "\n\n"),
            "messages": messages,
            "stream": true,
        ]
        if let effort = settings.reasoningEffort, effort != .off {
            let budget: Int
            switch effort {
            case .low: budget = 2048
            case .medium: budget = 8192
            case .high: budget = 24576
            case .off: budget = 0
            }
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    override func parseSSEEvent(event: String?, data: String) -> RawDelta? {
        guard let jsonData = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }
        let type = obj["type"] as? String ?? event

        switch type {
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any] else { return nil }
            let deltaType = delta["type"] as? String
            if deltaType == "text_delta", let text = delta["text"] as? String {
                return RawDelta(text: text)
            }
            if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                return RawDelta(thinking: thinking)
            }
            return nil
        case "message_stop":
            return RawDelta(isFinal: true)
        case "error":
            return nil
        default:
            return nil
        }
    }
}

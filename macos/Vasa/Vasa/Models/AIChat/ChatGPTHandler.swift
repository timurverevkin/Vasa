import Foundation

/// Every OpenAI-compatible provider — plain OpenAI, DeepSeek's own API, and the GigaTool
/// gateway ("giga"/"giga-vision") — talks the same standard Chat Completions shape:
/// `POST {baseURL}/chat/completions` (note: no `/v1` inserted here — each preset's `baseURL`
/// already includes whatever path prefix it needs, e.g. OpenAI's is
/// `https://api.openai.com/v1` while GigaTool's gateway is `https://gw.gigatool.app/deepseek`
/// with no `/v1` at all), standard `messages` array body, and the standard
/// `choices[0].delta.content` SSE streaming shape. An earlier version of this handler assumed
/// GigaTool's gateway spoke the OpenAI *Responses* API (`/responses`) instead — confirmed wrong
/// against the real gateway, which is plain Chat Completions like everything else here.
@MainActor
final class ChatGPTHandler: BaseAPIHandler {
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
        guard let url = URL(string: base + "/chat/completions") else { throw APIError.badURL }

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        messages += history.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "stream": true,
        ]
        if let temp = settings.temperature { body["temperature"] = temp }
        if let maxTokens = settings.maxTokens { body["max_tokens"] = maxTokens }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// One-shot, non-streaming vision request for `giga-vision` (GigaChat) — used only by the
    /// arrange/auto-tag background classification pass for `.image` cards, which needs a single
    /// text answer, not a chat stream. Kept off the `APIService` protocol entirely since threading
    /// image bytes through the shared streaming interface (`RequestMessage`/`StreamDelta`) would
    /// touch the main chat path for a feature that never appears in chat.
    ///
    /// Same `/chat/completions` endpoint and standard OpenAI vision message shape as the text
    /// path above (`content: [{type:"text",...},{type:"image_url",image_url:{url:dataURL}}]`),
    /// non-streaming (`stream: false`), parsed from the standard `choices[0].message.content`.
    func sendVisionRequest(imageDataURLs: [(cardId: String, dataURL: String)], instructions: String, apiKey: String) async throws -> String {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError.missingToken }

        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = config.baseURL }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw APIError.badURL }

        var content: [[String: Any]] = [["type": "text", "text": instructions]]
        for entry in imageDataURLs {
            content.append([
                "type": "image_url",
                "image_url": ["url": entry.dataURL],
            ])
        }
        let body: [String: Any] = [
            "model": config.defaultModel,
            "messages": [
                ["role": "system", "content": "You are a silent classification service. Output only valid JSON, nothing else."],
                ["role": "user", "content": content] as [String: Any],
            ],
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        AIChatDebugLog.shared.add("→ \(config.id) (vision) \(url.absoluteString) status=\(status)")
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            AIChatDebugLog.shared.add("✗ \(config.id) (vision) HTTP \(status): \(bodyText.prefix(300))")
            throw APIError.http(http.statusCode, bodyText)
        }
        guard let text = Self.extractOutputText(from: data) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            AIChatDebugLog.shared.add("✗ \(config.id) (vision) decode failed: \(raw.prefix(300))")
            throw APIError.decode
        }
        AIChatDebugLog.shared.add("← \(config.id) (vision) ok")
        return text
    }

    /// Extracts the answer from a standard (non-streaming) Chat Completions JSON body:
    /// `choices[0].message.content`.
    private static func extractOutputText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    override func parseSSEEvent(event: String?, data: String) -> RawDelta? {
        guard data != "[DONE]" else { return RawDelta(isFinal: true) }
        guard let jsonData = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]], let first = choices.first
        else { return nil }
        let delta = first["delta"] as? [String: Any]
        let content = delta?["content"] as? String
        let finishReason = first["finish_reason"] as? String
        return RawDelta(text: content, isFinal: finishReason != nil)
    }
}

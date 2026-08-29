import Foundation
import os

private let aiChatLog = Logger(subsystem: "app.vasa.aichat", category: "stream")

/// Raw per-handler delta before the thinking/text merge trick is applied.
struct RawDelta: Equatable {
    var text: String?
    var thinking: String?
    var isFinal: Bool = false
}

/// Abstract SSE-streaming base class. Subclasses build the provider-specific request and parse
/// provider-specific SSE events into `RawDelta`s; this base class opens the connection, drives
/// the byte stream through `SSEStreamParser`, and merges `.thinking` deltas into the public
/// `.text` stream as inline `<think>...</think>` segments so callers stay provider-agnostic.
@MainActor
class BaseAPIHandler: APIService {
    let config: AIProviderConfig
    init(config: AIProviderConfig) { self.config = config }

    /// Override: build the URLRequest for this provider.
    func buildRequest(
        history: [RequestMessage],
        systemPrompt: String,
        settings: GenerationSettings,
        apiKey: String
    ) throws -> URLRequest {
        fatalError("override buildRequest(history:systemPrompt:settings:apiKey:)")
    }

    /// Override: parse one SSE event into a raw delta (nil if the event carries nothing usable).
    func parseSSEEvent(event: String?, data: String) -> RawDelta? {
        fatalError("override parseSSEEvent(event:data:)")
    }

    func sendMessageStream(
        history: [RequestMessage],
        systemPrompt: String,
        settings: GenerationSettings,
        apiKey: String
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    let request = try self.buildRequest(
                        history: history, systemPrompt: systemPrompt, settings: settings, apiKey: apiKey
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    aiChatLog.debug("stream start provider=\(self.config.id, privacy: .public) url=\(request.url?.absoluteString ?? "?", privacy: .public) status=\(code, privacy: .public)")
                    AIChatDebugLog.shared.add("→ \(self.config.id) \(request.url?.absoluteString ?? "?") status=\(code)")
                    if !(200..<300).contains(code) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4000 { break }
                        }
                        aiChatLog.error("stream http-error provider=\(self.config.id, privacy: .public) status=\(code, privacy: .public) body=\(body.prefix(2000), privacy: .public)")
                        AIChatDebugLog.shared.add("✗ \(self.config.id) HTTP \(code): \(body.prefix(300))")
                        throw APIError.http(code, body)
                    }

                    var insideThinking = false
                    var eventCount = 0
                    var yieldedTextCount = 0
                    for try await (event, data) in SSEStreamParser.events(from: bytes.lines) {
                        try Task.checkCancellation()
                        eventCount += 1
                        if data == "[DONE]" {
                            aiChatLog.debug("sse provider=\(self.config.id, privacy: .public) [DONE]")
                            if insideThinking {
                                continuation.yield(StreamDelta(text: "\n</think>\n\n"))
                                insideThinking = false
                            }
                            continuation.yield(StreamDelta(text: nil, isFinal: true))
                            continue
                        }
                        let raw = self.parseSSEEvent(event: event, data: data)
                        aiChatLog.debug("sse provider=\(self.config.id, privacy: .public) event=\(event ?? "nil", privacy: .public) parsed=\(raw != nil, privacy: .public) text=\(raw?.text?.isEmpty == false, privacy: .public) data=\(String(data.prefix(500)), privacy: .public)")
                        if eventCount <= 5 || raw == nil {
                            // Cap what we mirror into the in-app log so a long stream doesn't
                            // flood it — first few events plus every unparsed one are the
                            // interesting ones for diagnosing a shape mismatch.
                            AIChatDebugLog.shared.add("· \(self.config.id) event=\(event ?? "-") parsed=\(raw != nil) \(String(data.prefix(200)))")
                        }
                        guard let raw else { continue }

                        if let thinking = raw.thinking, !thinking.isEmpty {
                            if !insideThinking {
                                continuation.yield(StreamDelta(text: "<think>\n"))
                                insideThinking = true
                            }
                            continuation.yield(StreamDelta(text: thinking))
                        }
                        if let text = raw.text, !text.isEmpty {
                            yieldedTextCount += 1
                            if insideThinking {
                                continuation.yield(StreamDelta(text: "\n</think>\n\n"))
                                insideThinking = false
                            }
                            continuation.yield(StreamDelta(text: text))
                        }
                        if raw.isFinal {
                            if insideThinking {
                                continuation.yield(StreamDelta(text: "\n</think>\n\n"))
                                insideThinking = false
                            }
                            continuation.yield(StreamDelta(text: nil, isFinal: true))
                        }
                    }
                    aiChatLog.debug("stream end provider=\(self.config.id, privacy: .public) events=\(eventCount, privacy: .public) textYields=\(yieldedTextCount, privacy: .public)")
                    AIChatDebugLog.shared.add("← \(self.config.id) done events=\(eventCount) textYields=\(yieldedTextCount)")
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: APIError.cancelled)
                } catch {
                    AIChatDebugLog.shared.add("✗ \(self.config.id) \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

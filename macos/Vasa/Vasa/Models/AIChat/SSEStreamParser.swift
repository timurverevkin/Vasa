import Foundation

/// Byte-level (line-level) SSE reader. Yields one `(event, data)` pair per `data:` line,
/// immediately — it does NOT wait for a blank-line message terminator before flushing.
///
/// Strict SSE framing groups `data:` lines into a "message" terminated by a blank line, and an
/// earlier version of this parser did exactly that (buffering `data:` lines until `""`, joining
/// them with `\n`). That broke against the real GigaTool gateway: it doesn't reliably send blank
/// lines between chunks, so every chunk of a response accumulated into one buffer and got
/// newline-glued into a single invalid JSON blob at stream end (confirmed via the in-app AI chat
/// log: `events=1` for an entire multi-chunk response, `parsed=false`). Every provider actually
/// wired up here (OpenAI/DeepSeek/GigaTool Chat Completions, Anthropic Messages) puts one
/// complete JSON object on a single `data:` line — real newlines inside JSON string values are
/// always escaped as `\n` by the sender's JSON encoder, so multi-line `data:` continuation is not
/// something any of these APIs actually rely on. Flushing per-line is simpler and robust to
/// missing blank-line terminators. `event:` still associates with the next `data:` line the same
/// way (used by Claude's `event: content_block_delta` framing).
enum SSEStreamParser {
    static func events(from lines: AsyncLineSequence<URLSession.AsyncBytes>) -> AsyncThrowingStream<(event: String?, data: String), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var currentEvent: String?
                do {
                    for try await line in lines {
                        if line.isEmpty {
                            currentEvent = nil
                            continue
                        }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                            continuation.yield((currentEvent, payload))
                        }
                        // id:/retry: lines are ignored — not needed by any v1 handler.
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

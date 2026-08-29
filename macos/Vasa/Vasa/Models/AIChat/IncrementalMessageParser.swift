import Foundation

enum MessageElement: Equatable {
    case text(String)
    case code(lang: String, body: String)
    case thinking(String)
    /// A single-level bullet (`- `/`* `) or numbered (`1. `) list. Each item's text is rendered
    /// with the same inline-markdown pass as `.text` (bold/italic/code/links via
    /// `AttributedString(markdown:)`); the bullet glyph or number itself is drawn separately by
    /// `ChatBubbleView`, never left in the item's raw text.
    case list(items: [String], ordered: Bool)
}

/// Re-parses the full accumulated message text on every delta (no true incremental diffing —
/// fine for v1 at chat-message sizes) into an ordered list of text / code / thinking elements.
enum IncrementalMessageParser {
    static func parse(_ text: String) -> [MessageElement] {
        var elements: [MessageElement] = []
        var remaining = Substring(text)

        while !remaining.isEmpty {
            if let thinkRange = remaining.range(of: "<think>") {
                if thinkRange.lowerBound > remaining.startIndex {
                    elements += parsePlain(String(remaining[remaining.startIndex..<thinkRange.lowerBound]))
                }
                let afterOpen = remaining[thinkRange.upperBound...]
                if let closeRange = afterOpen.range(of: "</think>") {
                    let inner = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { elements.append(.thinking(inner)) }
                    remaining = afterOpen[closeRange.upperBound...]
                } else {
                    // Still streaming inside a thinking block.
                    let inner = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty { elements.append(.thinking(inner)) }
                    remaining = Substring("")
                }
            } else {
                elements += parsePlain(String(remaining))
                remaining = Substring("")
            }
        }
        return elements
    }

    /// Splits plain (non-thinking) text on ```lang\n...\n``` fences.
    private static func parsePlain(_ text: String) -> [MessageElement] {
        guard text.contains("```") else {
            return text.isEmpty ? [] : parseLists(text)
        }
        var elements: [MessageElement] = []
        var remaining = Substring(text)
        while let fenceStart = remaining.range(of: "```") {
            let before = String(remaining[remaining.startIndex..<fenceStart.lowerBound])
            if !before.isEmpty { elements += parseLists(before) }
            let afterFence = remaining[fenceStart.upperBound...]
            let firstLineEnd = afterFence.firstIndex(of: "\n") ?? afterFence.endIndex
            let lang = String(afterFence[afterFence.startIndex..<firstLineEnd]).trimmingCharacters(in: .whitespaces)
            let bodyStart = firstLineEnd < afterFence.endIndex ? afterFence.index(after: firstLineEnd) : afterFence.endIndex
            let rest = afterFence[bodyStart...]
            if let closeRange = rest.range(of: "```") {
                let body = String(rest[rest.startIndex..<closeRange.lowerBound])
                elements.append(.code(lang: lang, body: body))
                remaining = rest[closeRange.upperBound...]
            } else {
                // Still streaming inside a code block.
                elements.append(.code(lang: lang, body: String(rest)))
                remaining = Substring("")
                break
            }
        }
        if !remaining.isEmpty { elements += parseLists(String(remaining)) }
        return elements
    }

    /// Line-based pre-pass over a non-fenced text chunk: groups consecutive `- `/`* `-prefixed
    /// lines into a single `.list(ordered: false)` element and consecutive `1. `-style lines into
    /// `.list(ordered: true)`, leaving everything else as `.text`. Inline markdown (bold/italic/
    /// code/links) inside list items and plain text is handled later, at render time, by
    /// `ChatBubbleView` via `AttributedString(markdown:)` — this pass only handles block structure.
    private static func parseLists(_ text: String) -> [MessageElement] {
        guard !text.isEmpty else { return [] }
        var elements: [MessageElement] = []
        var textBuffer: [String] = []
        var listBuffer: [String] = []
        var listOrdered = false

        func flushText() {
            if !textBuffer.isEmpty {
                elements.append(.text(textBuffer.joined(separator: "\n")))
                textBuffer = []
            }
        }
        func flushList() {
            if !listBuffer.isEmpty {
                elements.append(.list(items: listBuffer, ordered: listOrdered))
                listBuffer = []
            }
        }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            if let item = bulletPrefix(of: line) {
                if !listBuffer.isEmpty, listOrdered { flushList() }
                flushText()
                listOrdered = false
                listBuffer.append(item)
            } else if let item = numberPrefix(of: line) {
                if !listBuffer.isEmpty, !listOrdered { flushList() }
                flushText()
                listOrdered = true
                listBuffer.append(item)
            } else {
                flushList()
                textBuffer.append(line)
            }
        }
        flushList()
        flushText()
        return elements
    }

    private static func bulletPrefix(of line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        return nil
    }

    private static func numberPrefix(of line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let digits = line[line.startIndex..<dotIndex]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }
}

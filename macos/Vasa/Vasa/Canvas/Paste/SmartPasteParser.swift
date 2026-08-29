import Foundation
import CoreGraphics

/// One atomic piece of a raw paste: a URL (with the sentence it appeared in, for clustering
/// context) or a run of prose. Nothing here touches `Card` — segmentation is pure text math,
/// mirroring `ArrangeEngine`'s "callers hand in data, get data back" convention.
enum PasteChunk {
    case url(URL, surroundingSentence: String?)
    case text(String)
}

enum SmartPasteParser {

    /// Splits raw pasted text into URL chunks (each carrying its surrounding sentence for
    /// clustering) and text chunks cut on sentence/paragraph boundaries — never mid-phrase.
    static func segment(_ raw: String) -> [PasteChunk] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ns = trimmed as NSString

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return sentenceChunks(ns.substring(from: 0), in: NSRange(location: 0, length: ns.length))
        }
        let matches = detector.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            .filter { $0.url != nil }
        guard !matches.isEmpty else {
            return textChunks(from: ns, range: NSRange(location: 0, length: ns.length))
        }

        var sentenceRanges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { _, range, _, _ in
            sentenceRanges.append(range)
        }

        var chunks: [PasteChunk] = []
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location >= cursor, let url = match.url else { continue }
            if range.location > cursor {
                chunks += textChunks(from: ns, range: NSRange(location: cursor, length: range.location - cursor))
            }
            let sentence = sentenceRanges
                .first { NSIntersectionRange($0, range).length > 0 }
                .map { ns.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            chunks.append(.url(url, surroundingSentence: sentence?.isEmpty == false ? sentence : nil))
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            chunks += textChunks(from: ns, range: NSRange(location: cursor, length: ns.length - cursor))
        }
        return chunks
    }

    /// Cuts a substring into text chunks on sentence boundaries; drops whitespace-only pieces.
    private static func textChunks(from ns: NSString, range: NSRange) -> [PasteChunk] {
        sentenceChunks(ns.substring(with: range), in: NSRange(location: 0, length: range.length))
    }

    private static func sentenceChunks(_ substring: String, in range: NSRange) -> [PasteChunk] {
        let sub = substring as NSString
        var pieces: [String] = []
        sub.enumerateSubstrings(in: NSRange(location: 0, length: sub.length), options: .bySentences) { piece, _, _, _ in
            if let piece {
                let clean = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { pieces.append(clean) }
            }
        }
        if pieces.isEmpty {
            let clean = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? [] : [.text(clean)]
        }
        return pieces.map { .text($0) }
    }
}

extension PasteChunk {
    /// Best-effort text preview used for AI-clustering prompts and heuristic keyword overlap.
    var summaryText: String {
        switch self {
        case .url(let url, let sentence): return sentence ?? url.absoluteString
        case .text(let string): return string
        }
    }

    /// Card factories are always `DemoLibrary.*` in this codebase — never raw `Card(...)`.
    /// Link cards land as chips (gray "just an address" fallback); `AppModel.smartPaste`
    /// fires the same async `OpenGraph.fetch` upgrade `insertURL` uses.
    func materialize(id: String, x: Double, y: Double) -> Card {
        switch self {
        case .url(let url, _):
            let host = url.host() ?? url.absoluteString
            return DemoLibrary.linkChip(id, x, y, host, host, url.absoluteString, "#FF9500")
        case .text(let string):
            let clipped = String(string.prefix(Format.textLimit))
            let wrap = Format.textWrapWidth
            let lines = max(1, Int(ceil(Double(clipped.count) / max(24, wrap / 8))))
            return DemoLibrary.text(id, x, y, wrap, max(28, Double(lines) * 22 + 8), 1, clipped, 16)
        }
    }
}

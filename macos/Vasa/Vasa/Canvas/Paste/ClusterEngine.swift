import Foundation

/// Pure clustering math for smart-paste: groups `PasteChunk`s by topic so `AppModel.smartPaste`
/// can hand each cluster to the existing `performArrangeByGroups` core. Nothing here touches
/// `Card` or the lesson — mirrors `ArrangeEngine`'s "ids in, groups out" convention. AI-driven
/// clustering (v2) lives on `AppModel` instead, since it needs the active provider/API key —
/// see `AppModel.smartPasteAILabels`.
enum ClusterEngine {

    /// Consecutive-chunk merge: a chunk joins the running cluster if it shares a URL host with
    /// the previous URL chunk, or shares a keyword with the previous chunk's summary text.
    /// Otherwise it starts a new cluster. O(n), no false cross-cluster merges from chunks that
    /// aren't adjacent in the paste.
    static func clusterHeuristic(_ chunks: [PasteChunk]) -> [[Int]] {
        guard !chunks.isEmpty else { return [] }
        var clusters: [[Int]] = [[0]]
        var lastHost: String?
        if case .url(let url, _) = chunks[0] { lastHost = url.host() }

        for i in 1..<chunks.count {
            let chunk = chunks[i]
            let currentHost: String? = { if case .url(let url, _) = chunk { return url.host() } else { return nil } }()
            let related = related(chunks[i - 1], chunk, lastHost: lastHost, currentHost: currentHost)
            if related {
                clusters[clusters.count - 1].append(i)
            } else {
                clusters.append([i])
            }
            if let currentHost { lastHost = currentHost }
        }
        return clusters
    }

    private static func related(_ prev: PasteChunk, _ next: PasteChunk, lastHost: String?, currentHost: String?) -> Bool {
        if let lastHost, let currentHost, lastHost == currentHost { return true }
        let prevWords = keywords(prev.summaryText)
        let nextWords = keywords(next.summaryText)
        guard !prevWords.isEmpty, !nextWords.isEmpty else { return false }
        return !prevWords.isDisjoint(with: nextWords)
    }

    /// Lowercased words of 4+ characters — long enough to be topical, not stopwords/particles.
    private static func keywords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
    }
}

import Foundation
import CoreGraphics

/// Compositional role the AI assigns a card within its cluster — cheap enough to fit one per
/// card even in a large paste, and expressive enough to drive a real composition instead of a
/// uniform grid: one thing anchors the cluster, the rest read around it.
enum CardRole: String {
    case hero       // the biggest/most important item — anchors the cluster
    case caption    // short text that names/describes the hero (racked beside it)
    case meta       // secondary small text (numbers, handles) — racked further out than caption
    case accent     // a related but independent item (audio, a second link) — sits beside the hero
}

/// Lays out one cluster the way a moodboard is actually composed, not a grid: **size hierarchy**
/// (one hero anchors, everything else reads as smaller support), placed with **rule-of-thirds**
/// anchor points (support sits at the hero's 1/3 line, not flush against an edge or centered on
/// it) and a **golden-ratio** split deciding which axis the support rack runs along — the two
/// documented moves behind real collage/moodboard layout (size-hierarchy + spacing so nothing
/// clusters flush, golden-ratio asymmetric balance). Pure math — no `Card`/lesson coupling, same
/// convention as `ArrangeEngine`.
enum ComposeEngine {
    /// 1:1.618 — the split ratio between the hero's "major" axis and the support rack's offset
    /// along it, so the support reads as a proportioned counterweight instead of an arbitrary gap.
    private static let goldenRatio: Double = 1.618

    static func compose(items: [(id: String, role: CardRole, size: CGSize)], anchor: CGPoint, gap: Double) -> [String: CGPoint] {
        guard !items.isEmpty else { return [:] }
        let hero = items.first(where: { $0.role == .hero })
            ?? items.max(by: { $0.size.width * $0.size.height < $1.size.width * $1.size.height })
        guard let hero else { return [:] }

        var origins: [String: CGPoint] = [:]
        origins[hero.id] = anchor

        // Intra-cluster spacing stays tight regardless of `gap` (a canvas-wide median that can
        // run up to 48pt) — a cluster should read as one composed unit, not items spread apart.
        let tight = min(gap, 16)

        let captions = items.filter { $0.id != hero.id && ($0.role == .caption || $0.role == .meta) }
        let accents = items.filter { $0.id != hero.id && $0.role == .accent }

        // Golden-ratio axis choice: a wide hero (landscape photo, link-rich card) racks its
        // captions below, at the hero's lower third-line; a tall/square hero racks them to the
        // left, at the hero's upper third-line. Either way the rack starts from a rule-of-thirds
        // point on the hero, not its corner — an off-center anchor is what makes it read as
        // composed instead of a caption flush-stacked under a picture.
        let heroIsWide = hero.size.width >= hero.size.height
        if heroIsWide {
            let startX = anchor.x + hero.size.width / 3
            var stepX = startX
            var stepY = anchor.y + hero.size.height + tight
            for item in captions {
                origins[item.id] = CGPoint(x: stepX, y: stepY)
                stepY += item.size.height + tight * 0.4
                stepX -= tight * 0.35
            }
        } else {
            let captionWidth = captions.map(\.size.width).max() ?? 0
            var stepX = anchor.x - captionWidth - tight
            var stepY = anchor.y + hero.size.height / 3
            for item in captions {
                origins[item.id] = CGPoint(x: stepX, y: stepY)
                stepY += item.size.height + tight * 0.4
                stepX += tight * 0.35
            }
        }

        // Accents rack beside the hero, anchored at its lower third-line (golden-ratio-ish
        // offset down from the top) rather than dead-center — an asymmetric pairing instead of
        // two items mirrored on the same axis.
        var accentX = anchor.x + hero.size.width + tight
        let accentY = anchor.y + hero.size.height - hero.size.height / goldenRatio
        for item in accents {
            origins[item.id] = CGPoint(x: accentX, y: accentY)
            accentX += item.size.width + tight
        }
        return origins
    }
}

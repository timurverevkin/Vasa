import Foundation
import CoreGraphics

/// Pure layout math for `AppModel.arrangeSelection` (organize by type). Cards are clustered by
/// kind by the caller; this engine packs each cluster compactly by aspect ratio (potpack).
/// Nothing here touches `Card` or the lesson — callers hand in ids/sizes and get back origins.
enum ArrangeEngine {

    // MARK: - Auto-gap

    /// Median of the neighbor gaps in a cluster of frames, pooled from both the x- and
    /// y-sorted orders, clamped to [12, 48] with a 24pt default when nothing is usable.
    static func autoGap(frames: [CGRect]) -> Double {
        guard frames.count >= 2 else { return 24 }
        let byX = frames.sorted { $0.minX < $1.minX }
        let byY = frames.sorted { $0.minY < $1.minY }
        var gaps: [Double] = []
        for i in 0..<(byX.count - 1) {
            let gap = Double(byX[i + 1].minX - byX[i].maxX)
            if gap > 0 { gaps.append(gap) }
        }
        for i in 0..<(byY.count - 1) {
            let gap = Double(byY[i + 1].minY - byY[i].maxY)
            if gap > 0 { gaps.append(gap) }
        }
        return median(gaps, fallback: 24)
    }

    private static func median(_ values: [Double], fallback: Double) -> Double {
        guard !values.isEmpty else { return fallback }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let m = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return min(48, max(12, m))
    }

    // MARK: - Stack (single column, reading order)

    /// Stacks items in a single left-aligned column, in the given order — unlike `packLayout`
    /// (which sorts tallest-first for density), this preserves reading/paste order, matching how
    /// a small topical cluster (e.g. a note above the link it refers to) should read top to
    /// bottom rather than being shelf-packed into a grid.
    static func stackLayout(items: [(id: String, size: CGSize)], gap: Double, anchor: CGPoint) -> [String: CGPoint] {
        guard !items.isEmpty else { return [:] }
        var origins: [String: CGPoint] = [:]
        var cursorY = anchor.y
        for item in items {
            origins[item.id] = CGPoint(x: anchor.x, y: cursorY)
            cursorY += Double(item.size.height) + gap
        }
        return origins
    }

    // MARK: - Pack (potpack)

    private struct PBox {
        let id: String
        var w: Double
        var h: Double
        var x: Double = 0
        var y: Double = 0
    }

    /// Shelf-packs items (mapbox potpack algorithm — sorts tallest-first, so reading order is
    /// not preserved). Sizes are inflated by `gap` before packing and the result shifted back
    /// by half a gap, so items end up `gap` apart from each other without leaving a full extra
    /// gap of dead space along the outer bottom/right edge.
    static func packLayout(items: [(id: String, size: CGSize)], gap: Double, anchor: CGPoint) -> [String: CGPoint] {
        guard !items.isEmpty else { return [:] }
        var boxes = items.map { PBox(id: $0.id, w: Double($0.size.width) + gap, h: Double($0.size.height) + gap) }
        potpack(&boxes)

        var origins: [String: CGPoint] = [:]
        for box in boxes {
            origins[box.id] = CGPoint(x: Double(anchor.x) + box.x + gap / 2, y: Double(anchor.y) + box.y + gap / 2)
        }
        return origins
    }

    /// Direct port of the mapbox/potpack shelf-packing algorithm.
    private static func potpack(_ boxes: inout [PBox]) {
        guard !boxes.isEmpty else { return }
        var area = 0.0
        var maxWidth = 0.0
        for box in boxes {
            area += box.w * box.h
            maxWidth = max(maxWidth, box.w)
        }
        boxes.sort { $0.h > $1.h }

        let startWidth = max((area / 0.95).squareRoot().rounded(.up), maxWidth)
        struct Space { var x: Double; var y: Double; var w: Double; var h: Double }
        var spaces: [Space] = [Space(x: 0, y: 0, w: startWidth, h: .infinity)]

        for i in boxes.indices {
            var j = spaces.count - 1
            while j >= 0 {
                let space = spaces[j]
                if boxes[i].w > space.w || boxes[i].h > space.h {
                    j -= 1
                    continue
                }
                boxes[i].x = space.x
                boxes[i].y = space.y

                if boxes[i].w == space.w && boxes[i].h == space.h {
                    let last = spaces.removeLast()
                    if j < spaces.count { spaces[j] = last }
                } else if boxes[i].h == space.h {
                    spaces[j].x += boxes[i].w
                    spaces[j].w -= boxes[i].w
                } else if boxes[i].w == space.w {
                    spaces[j].y += boxes[i].h
                    spaces[j].h -= boxes[i].h
                } else {
                    spaces.append(Space(x: space.x + boxes[i].w, y: space.y, w: space.w - boxes[i].w, h: boxes[i].h))
                    spaces[j].y += boxes[i].h
                    spaces[j].h -= boxes[i].h
                }
                break
            }
        }
    }
}

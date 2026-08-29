import CoreGraphics
import Foundation

// MARK: - State

/// Pure state machine for the canvas text tool.
/// Drive from a single `DragGesture(minimumDistance: 0)` in world space
/// (pass `threshold: TextToolReducer.dragThreshold / zoom` so the tap/drag
/// gate stays ~14 screen points). Replaces the dual insert paths
/// (`onTapGesture` + `DragGesture.onEnded`).
nonisolated enum TextToolState: Equatable, Sendable {
    case idle
    case armed(origin: CGPoint)
    case creating(origin: CGPoint, current: CGPoint)
    case editing(cardID: String)
}

nonisolated enum TextToolAction: Equatable, Sendable {
    case pointerDown(CGPoint)
    case pointerMoved(CGPoint)
    case pointerUp(CGPoint)
    case escape
    /// Editing ended on this card with no typed content.
    case blurEmpty(String)
    case blurNonEmpty(String)
    case toolSwitched
}

nonisolated enum TextToolEffect: Equatable, Sendable {
    case none
    case resizePreview(rect: CGRect)
    /// Tap-to-create: blank card placed at point, default size. Pair with gaussian burst.
    case createBlank(at: CGPoint, id: String)
    /// Drag-to-size: blank card sized to rect.
    case commitSized(id: String, rect: CGRect)
    case discard(id: String)
    case clearPreview
}

// MARK: - Reducer

nonisolated enum TextToolReducer {
    /// Screen-space travel below which pointerUp is a tap. When feeding world
    /// points, pass `dragThreshold / camera.zoom` into `reduce(threshold:)`.
    /// 14pt resists accidental mini-drags from mouse click jitter (8 was too low).
    static let dragThreshold: CGFloat = 14

    /// Empty seed ≈ one 16pt line (~20) + pad so the caret sits clear of the stroke.
    static let defaultSize = CGSize(width: 36, height: 36)

    /// Floor for drag-to-size commits and empty-text seed in `TextCardView`.
    static let minSized = CGSize(width: 36, height: 36)

    static func reduce(
        state: TextToolState,
        action: TextToolAction,
        makeID: () -> String = { VasaID.make("c") },
        threshold: CGFloat = dragThreshold
    ) -> (TextToolState, TextToolEffect) {
        switch (state, action) {

        case (.idle, .pointerDown(let p)):
            return (.armed(origin: p), .clearPreview)

        case (.armed(let origin), .pointerMoved(let p)):
            if distance(origin, p) >= threshold {
                return (.creating(origin: origin, current: p), .resizePreview(rect: rect(origin, p)))
            }
            return (state, .none)

        case (.armed(let origin), .pointerUp):
            let id = makeID()
            return (.editing(cardID: id), .createBlank(at: origin, id: id))

        case (.creating(let origin, _), .pointerMoved(let p)):
            return (.creating(origin: origin, current: p), .resizePreview(rect: rect(origin, p)))

        case (.creating(let origin, _), .pointerUp(let p)):
            let id = makeID()
            return (.editing(cardID: id), .commitSized(id: id, rect: rect(origin, p)))

        case (.armed, .escape), (.creating, .escape):
            return (.idle, .clearPreview)

        case (.editing(let id), .blurEmpty(let blurred)):
            guard id == blurred else { return (state, .none) }
            return (.idle, .discard(id: id))

        case (.editing(let id), .blurNonEmpty(let blurred)):
            guard id == blurred else { return (state, .none) }
            return (.idle, .none)

        case (.editing, .escape):
            // Escape while editing is a blur — AppModel resigns first responder
            // and dispatches blurEmpty / blurNonEmpty from finishTextEditing.
            return (state, .none)

        case (_, .toolSwitched):
            return (.idle, .clearPreview)

        default:
            return (state, .none)
        }
    }

    static func clampedSizedRect(_ raw: CGRect) -> CGRect {
        let w = max(minSized.width, raw.width)
        let h = max(minSized.height, raw.height)
        return CGRect(x: raw.minX, y: raw.minY, width: w, height: h)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(origin: a, size: .zero).union(CGRect(origin: b, size: .zero))
    }
}

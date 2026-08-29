import CoreGraphics
import XCTest
@testable import Vasa

final class TextToolReducerTests: XCTestCase {

    func testTapBelowThresholdCreatesBlankBlock() {
        let origin = CGPoint(x: 100, y: 100)
        let id = "c_tap"
        var (state, effect) = TextToolReducer.reduce(
            state: .idle,
            action: .pointerDown(origin),
            makeID: { id }
        )
        XCTAssertEqual(state, .armed(origin: origin))
        XCTAssertEqual(effect, .clearPreview)

        // Small jitter, stays under the 14pt threshold.
        (state, effect) = TextToolReducer.reduce(
            state: state,
            action: .pointerMoved(CGPoint(x: 108, y: 104)),
            makeID: { id }
        )
        XCTAssertEqual(state, .armed(origin: origin))
        XCTAssertEqual(effect, .none)

        (state, effect) = TextToolReducer.reduce(
            state: state,
            action: .pointerUp(CGPoint(x: 108, y: 104)),
            makeID: { id }
        )
        XCTAssertEqual(state, .editing(cardID: id))
        XCTAssertEqual(effect, .createBlank(at: origin, id: id))
    }

    func testDragPastThresholdCommitsSizedRect() {
        let origin = CGPoint(x: 0, y: 0)
        let id = "c_drag"
        var (state, _) = TextToolReducer.reduce(
            state: .idle,
            action: .pointerDown(origin),
            makeID: { id }
        )

        (state, _) = TextToolReducer.reduce(
            state: state,
            action: .pointerMoved(CGPoint(x: 40, y: 40)),
            makeID: { id }
        )
        guard case .creating = state else {
            return XCTFail("expected .creating after crossing drag threshold")
        }

        let (finalState, effect) = TextToolReducer.reduce(
            state: state,
            action: .pointerUp(CGPoint(x: 60, y: 30)),
            makeID: { id }
        )
        XCTAssertEqual(finalState, .editing(cardID: id))
        XCTAssertEqual(effect, .commitSized(id: id, rect: CGRect(x: 0, y: 0, width: 60, height: 30)))
    }

    func testZoomAwareThresholdUsesCallerValue() {
        let origin = CGPoint.zero
        // World-space points at zoom 0.5: 14 screen pts = 28 world pts.
        let (armed, _) = TextToolReducer.reduce(state: .idle, action: .pointerDown(origin))
        let (stillArmed, effect) = TextToolReducer.reduce(
            state: armed,
            action: .pointerMoved(CGPoint(x: 20, y: 0)),
            threshold: 28
        )
        XCTAssertEqual(stillArmed, .armed(origin: origin))
        XCTAssertEqual(effect, .none)

        let (creating, preview) = TextToolReducer.reduce(
            state: stillArmed,
            action: .pointerMoved(CGPoint(x: 28, y: 0)),
            threshold: 28
        )
        guard case .creating = creating else {
            return XCTFail("expected .creating once world travel hits zoom-adjusted threshold")
        }
        XCTAssertEqual(preview, .resizePreview(rect: CGRect(x: 0, y: 0, width: 28, height: 0)))
    }

    func testEscapeWhileArmedReturnsToIdleWithClearPreview() {
        let (state, _) = TextToolReducer.reduce(state: .idle, action: .pointerDown(.zero))
        let (finalState, effect) = TextToolReducer.reduce(state: state, action: .escape)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(effect, .clearPreview)
    }

    func testBlurEmptyDiscardsMatchingBlock() {
        let id = "c_empty"
        let (finalState, effect) = TextToolReducer.reduce(
            state: .editing(cardID: id),
            action: .blurEmpty(id)
        )
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(effect, .discard(id: id))
    }

    func testBlurEmptyIgnoresMismatchedID() {
        let (finalState, effect) = TextToolReducer.reduce(
            state: .editing(cardID: "c_a"),
            action: .blurEmpty("c_b")
        )
        XCTAssertEqual(finalState, .editing(cardID: "c_a"))
        XCTAssertEqual(effect, .none)
    }

    func testBlurNonEmptyKeepsTheBlock() {
        let id = "c_keep"
        let (finalState, effect) = TextToolReducer.reduce(
            state: .editing(cardID: id),
            action: .blurNonEmpty(id)
        )
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(effect, .none)
    }

    func testToolSwitchFromArmedReturnsToIdle() {
        let (armed, _) = TextToolReducer.reduce(state: .idle, action: .pointerDown(.zero))
        let (finalState, effect) = TextToolReducer.reduce(state: armed, action: .toolSwitched)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(effect, .clearPreview)
    }

    func testClampedSizedRectEnforcesMinimum() {
        let raw = CGRect(x: 10, y: 20, width: 12, height: 8)
        let clamped = TextToolReducer.clampedSizedRect(raw)
        XCTAssertEqual(clamped, CGRect(x: 10, y: 20, width: 36, height: 36))
    }
}

import AppKit

/// Trackpad haptics via `NSHapticFeedbackManager`. Gated by `AppSettings.haptics`.
/// Per Apple's HIG ("Playing Haptics"): use sparingly, only for meaningful,
/// discrete state changes — not for continuous motion or every animation.
@MainActor
enum AppHaptics {
    /// Bound from `AppModel` so plays respect the Haptics toggle.
    static var isEnabled: () -> Bool = { true }

    /// Mirrors `NSHapticFeedbackManager.FeedbackPattern`.
    enum Kind {
        /// Snapping into place — alignment guides, grid snap, magnetic drop.
        case alignment
        /// A discrete value crossed a step — zoom notches, slider steps.
        case levelChange
        /// Generic acknowledgement — toggles, panel open/close.
        case generic
    }

    static func perform(_ kind: Kind) {
        guard isEnabled() else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch kind {
        case .alignment: pattern = .alignment
        case .levelChange: pattern = .levelChange
        case .generic: pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }
}

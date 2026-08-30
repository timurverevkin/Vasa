import AppKit
import CoreText
import SwiftUI

struct CanvasTextEditor: NSViewRepresentable {
    let html: String?
    let plain: String?
    let fontSize: CGFloat
    let ink: NSColor
    let editing: Bool
    /// Card-local point the double-click that opened editing landed on — consumed once to
    /// place the caret there (word-selected) instead of wherever it was left after the
    /// previous editing session. `nil` on every entry except the one right after that click.
    var pendingCaret: CGPoint?
    /// Fires once `pendingCaret` has been applied, so the caller (AppModel) can clear it —
    /// otherwise the same point would be reapplied on every subsequent re-render.
    var onConsumeCaret: (() -> Void)?
    /// When true, size callbacks must not rewrite card.width/height (corner-resize owns them).
    var suppressAutoResize = false
    /// Format bar / color panel has focus — don't persist-on-end (avoids remount wiping color).
    var isFormatChromeActive: () -> Bool = { false }
    var onChange: (String, String, CGSize) -> Void
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onSelectionChange: ((NSRange, CGRect?) -> Void)?
    var onBind: ((GrowingTextView?) -> Void)?
    /// Checkbox square (view coordinates) of a mark the user just toggled.
    var onToggleCheckbox: ((CGRect) -> Void)?
    /// True while the pointer sits on one of this card's checkboxes.
    var onCheckboxHover: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChange: onChange,
            onBeginEditing: onBeginEditing,
            onEndEditing: onEndEditing,
            onSelectionChange: onSelectionChange,
            onBind: onBind,
            isFormatChromeActive: isFormatChromeActive
        )
    }

    func makeNSView(context: Context) -> GrowingTextView {
        let view = GrowingTextView()
        view.onToggleCheckbox = onToggleCheckbox
        view.onCheckboxHover = onCheckboxHover
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isRichText = true
        view.allowsUndo = true
        view.isEditable = editing
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.lineBreakMode = .byWordWrapping
        // Wide enough to measure; card frame hugs content via fittingContentSize.
        view.textContainer?.containerSize = NSSize(
            width: GrowingTextView.preferredWrapWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.defaultParagraphStyle = GrowingTextView.wrappingParagraphStyle
        view.textContainerInset = NSSize(width: GrowingTextView.contentPadX, height: GrowingTextView.contentPadY)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        view.textColor = ink
        view.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.focusRingType = .none
        view.insertionPointColor = NSColor.labelColor
        view.clipsToBounds = true
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.desiredFontSize = fontSize
        context.coordinator.suppressAutoResize = suppressAutoResize
        context.coordinator.onBind = onBind
        context.coordinator.onSelectionChange = onSelectionChange
        if editing { onBind?(view) }
        view.onSizeChange = { [weak coord = context.coordinator] size in
            coord?.reportSize(size)
        }
        view.textStorage?.setAttributedString(Self.attributed(html: html, plain: plain, size: fontSize, ink: ink))
        context.coordinator.lastHTML = html ?? plain ?? ""
        context.coordinator.lastInkHex = ink.vasaHex
        view.refreshEmptyPresentation()
        if editing {
            let caret = pendingCaret
            // Deferred: at this point the view isn't attached to the window yet, so
            // `makeFirstResponder` now is a no-op. Match NoteEditor's pattern — hop
            // to the next runloop tick, after AppKit has finished inserting it.
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                if let caret { Self.applyPendingCaret(caret, to: view) }
            }
            if caret != nil { onConsumeCaret?() }
        }
        return view
    }

    func updateNSView(_ view: GrowingTextView, context: Context) {
        view.onToggleCheckbox = onToggleCheckbox
        view.onCheckboxHover = onCheckboxHover
        context.coordinator.onChange = onChange
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onBind = onBind
        context.coordinator.isFormatChromeActive = isFormatChromeActive
        context.coordinator.view = view
        context.coordinator.suppressAutoResize = suppressAutoResize
        view.frameDrivesContainer = suppressAutoResize
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isEditable = editing
        view.isSelectable = true
        view.window?.invalidateCursorRects(for: view)
        // Leaving corner-resize: clear size throttle and force a content-fit pass.
        if context.coordinator.suppressAutoResize, !suppressAutoResize {
            context.coordinator.invalidateSizeThrottle()
            context.coordinator.reportSize(view.fittingContentSize)
        }
        context.coordinator.suppressAutoResize = suppressAutoResize
        if editing {
            onBind?(view)
            let caret = pendingCaret
            if view.window?.firstResponder !== view {
                // Entering edit always claims first responder — whatever held it before
                // (the canvas view that handled the placing click, a sidebar button, …)
                // must yield, or the freshly placed block silently never becomes typable.
                // Deferred a tick: stealing focus synchronously here can still be
                // overridden afterward by AppKit's own responder resolution within
                // the same update cycle (see NoteEditor's identical async hop).
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.window?.firstResponder !== view else { return }
                    view.window?.makeFirstResponder(view)
                    if let caret { Self.applyPendingCaret(caret, to: view) }
                }
            } else if let caret {
                // Already first responder (e.g. re-entering edit without losing focus) —
                // no responder hop to wait on, apply immediately.
                Self.applyPendingCaret(caret, to: view)
            }
            if caret != nil { onConsumeCaret?() }
        } else if context.coordinator.wasEditing || view.selectedRange().length > 0 {
            // Leaving the block: drop the system selection highlight so it cannot linger.
            view.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.onSelectionChange?(NSRange(location: 0, length: 0), nil)
        }
        context.coordinator.wasEditing = editing
        if abs(context.coordinator.desiredFontSize - fontSize) > 0.5 {
            context.coordinator.desiredFontSize = fontSize
            Self.applyFontSize(fontSize, to: view)
            view.invalidateIntrinsicContentSize()
            // Do not reportSize while corner-resize owns the frame (Ticket G).
            if !suppressAutoResize {
                context.coordinator.reportSize(view.fittingContentSize)
            }
        }
        let incoming = html ?? plain ?? ""
        let current = context.coordinator.lastHTML
        let inkHex = ink.vasaHex
        let inkChanged = inkHex != context.coordinator.lastInkHex
        if incoming != current || (inkChanged && !editing) {
            // While editing, the live NSTextView owns content. Reloading from HTML when the
            // format bar steals first responder was wiping colors / bold mid-edit.
            if editing {
                // Reloading from HTML mid-edit would wipe live formatting, but a bare ink
                // change (system appearance flipped while typing) still needs to reach the
                // on-screen runs — remap only the default-colored text in place, leaving any
                // user-applied swatch untouched.
                if inkChanged, let storage = view.textStorage {
                    // Matched by appearance, not against the previous ink hex: a run that
                    // came back from stored HTML carries a colour-space-shifted variant of
                    // that hex and would never compare equal.
                    let full = NSRange(location: 0, length: storage.length)
                    storage.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                        guard let color = value as? NSColor, Theme.isAdaptiveInk(color) else { return }
                        storage.addAttribute(.foregroundColor, value: ink, range: range)
                    }
                    var typing = view.typingAttributes
                    if let typingColor = typing[.foregroundColor] as? NSColor, Theme.isAdaptiveInk(typingColor) {
                        typing[.foregroundColor] = ink
                        view.typingAttributes = typing
                    }
                    view.insertionPointColor = ink
                }
                context.coordinator.lastHTML = incoming
                context.coordinator.lastInkHex = inkHex
            } else {
                view.textStorage?.setAttributedString(Self.attributed(html: html, plain: plain, size: fontSize, ink: ink))
                context.coordinator.lastHTML = incoming
                context.coordinator.lastInkHex = inkHex
                view.invalidateIntrinsicContentSize()
            }
        }
        // Never assign `textColor` here — it recolors the entire storage and wipes
        // per-run swatches applied from the format bar.
        if !editing {
            var typing = view.typingAttributes
            typing[.foregroundColor] = ink
            view.typingAttributes = typing
            view.insertionPointColor = ink
        }
    }

    /// Places the caret at `point` (card-local, same space the double-click gesture reports),
    /// extended to the enclosing word — matching the double-click-to-select-word convention
    /// every other AppKit text view follows. `characterIndexForInsertion(at:)` is a pure
    /// geometry query (works whether or not the view is editable/first-responder), unlike the
    /// double-click itself, which never reaches this view in the first place.
    private static func applyPendingCaret(_ point: CGPoint, to view: GrowingTextView) {
        guard view.textStorage?.length ?? 0 > 0 else {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        let index = view.characterIndexForInsertion(at: point)
        let proposed = NSRange(location: index, length: 0)
        let wordRange = view.selectionRange(forProposedRange: proposed, granularity: .selectByWord)
        view.setSelectedRange(wordRange)
        view.scrollRangeToVisible(wordRange)
    }

    /// Hug size for attributed canvas text (width follows longest hard line, soft-wrap at cap).
    static func hugSize(for attributed: NSAttributedString) -> CGSize {
        let padX = GrowingTextView.contentPadX
        let padY = GrowingTextView.contentPadY
        let spare: CGFloat = 8
        let wrap = GrowingTextView.preferredWrapWidth
        let wrapContent = max(48, wrap - padX * 2)
        let seed = TextToolReducer.defaultSize

        guard attributed.length > 0 else {
            return seed
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let measure = NSTextContainer(size: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude))
        measure.lineFragmentPadding = 0
        measure.widthTracksTextView = false
        measure.lineBreakMode = .byWordWrapping
        layout.addTextContainer(measure)
        storage.addLayoutManager(layout)

        // Longest hard line (Enter-separated), ignoring soft wrap.
        let plain = storage.string as NSString
        var lineW: CGFloat = 0
        let huge = CGSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        plain.enumerateSubstrings(
            in: NSRange(location: 0, length: plain.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            let slice = storage.attributedSubstring(from: range)
            let rect = slice.boundingRect(
                with: huge,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            lineW = max(lineW, ceil(rect.width))
        }
        if lineW == 0 {
            let rect = storage.boundingRect(
                with: huge,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            lineW = ceil(rect.width)
        }

        let contentColumn: CGFloat
        let width: CGFloat
        if lineW <= wrapContent {
            contentColumn = max(12, lineW)
            width = max(36, ceil(contentColumn + padX * 2 + spare))
        } else {
            contentColumn = wrapContent
            width = wrap
        }

        let container = NSTextContainer(size: NSSize(width: contentColumn, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.lineBreakMode = .byWordWrapping
        // Replace measure container with the real column.
        layout.removeTextContainer(at: 0)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(seed.height, ceil(used.height + padY * 2 + 4))
        return CGSize(width: width, height: height)
    }

    static func applyFontSize(_ size: CGFloat, to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        if full.length > 0 {
            storage.enumerateAttribute(.font, in: full) { value, range, _ in
                let existing = (value as? NSFont) ?? NSFont.systemFont(ofSize: size)
                let traits = existing.fontDescriptor.symbolicTraits
                let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
                var next = NSFont.systemFont(ofSize: size, weight: weight)
                if traits.contains(.italic),
                   let italic = NSFont(descriptor: next.fontDescriptor.withSymbolicTraits(.italic), size: size) {
                    next = italic
                }
                storage.addAttribute(.font, value: next, range: range)
            }
        }
        var typing = view.typingAttributes
        let weight: NSFont.Weight = {
            if let font = typing[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) {
                return .semibold
            }
            return .regular
        }()
        typing[.font] = NSFont.systemFont(ofSize: size, weight: weight)
        view.typingAttributes = typing
        // `view.font` drives the caret height and the empty/single-line centering; leaving it
        // at the old size made a 36pt card draw a 16pt caret once its text was deleted, and
        // `refreshEmptyPresentation` then wrote that stale font back into typingAttributes.
        view.font = NSFont.systemFont(ofSize: size, weight: weight)
        (view as? GrowingTextView)?.refreshEmptyPresentation()
        view.font = typing[.font] as? NSFont
    }

    static func attributed(html: String?, plain: String?, size: CGFloat, ink: NSColor) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: ink,
            .paragraphStyle: GrowingTextView.wrappingParagraphStyle,
        ]
        if let html, html.contains("<"), let data = html.data(using: .utf8),
           let parsed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           ), parsed.length > 0
        {
            let mutable = NSMutableAttributedString(attributedString: parsed)
            let full = NSRange(location: 0, length: mutable.length)
            mutable.removeAttribute(.backgroundColor, range: full)
            mutable.addAttribute(.paragraphStyle, value: GrowingTextView.wrappingParagraphStyle, range: full)
            mutable.enumerateAttribute(.font, in: full) { value, range, _ in
                let existing = (value as? NSFont) ?? NSFont.systemFont(ofSize: size)
                let traits = existing.fontDescriptor.symbolicTraits
                let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
                var next = NSFont.systemFont(ofSize: size, weight: weight)
                if traits.contains(.italic), let italic = NSFont(descriptor: next.fontDescriptor.withSymbolicTraits(.italic), size: size) {
                    next = italic
                }
                mutable.addAttribute(.font, value: next, range: range)
            }
            // Normalize colors to sRGB so preview + editor paint reliably, and let plain
            // body text follow the current appearance in both directions — text typed in
            // light mode must not stay black on the dark canvas, nor the reverse.
            mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                guard let color = value as? NSColor else {
                    mutable.addAttribute(.foregroundColor, value: ink, range: range)
                    return
                }
                if Theme.isAdaptiveInk(color) {
                    mutable.addAttribute(.foregroundColor, value: ink, range: range)
                } else {
                    mutable.addAttribute(.foregroundColor, value: NSColor.vasa(hex: color.vasaHex), range: range)
                }
            }
            // Cocoa HTML import always appends a trailing paragraph break for the last </p>
            // ("Timur\n"). That shows up as an empty second line when re-entering edit.
            Self.stripCocoaTrailingParagraphBreak(mutable)
            TodoMarks.restyleMarks(in: mutable)
            return mutable
        }
        let plainAttr = NSMutableAttributedString(string: normalizedPlain(plain ?? ""), attributes: base)
        TodoMarks.restyleMarks(in: plainAttr)
        return plainAttr
    }

    /// Drop a single trailing line break (Cocoa `<p>` artifact). Keeps `"hello\n\n"`.
    static func normalizedPlain(_ string: String) -> String {
        if string.hasSuffix("\r\n") {
            if string.hasSuffix("\r\n\r\n") { return string }
            return String(string.dropLast(2))
        }
        if string.hasSuffix("\n") {
            if string.hasSuffix("\n\n") { return string }
            return String(string.dropLast())
        }
        return string
    }

    /// Drop the single trailing `\n` Cocoa adds when parsing `<p>…</p>`.
    /// Keeps intentional blank lines (`"hello\n\n"` → `"hello\n"` after one strip).
    private static func stripCocoaTrailingParagraphBreak(_ mutable: NSMutableAttributedString) {
        guard mutable.length > 0 else { return }
        let ns = mutable.string as NSString
        let last = ns.character(at: mutable.length - 1)
        guard last == 0x0a || last == 0x0d else { return }
        // Keep intentional blank line (two trailing breaks).
        if mutable.length >= 2 {
            let prev = ns.character(at: mutable.length - 2)
            if prev == 0x0a || prev == 0x0d { return }
        }
        mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
    }

    static func html(from attributed: NSAttributedString) -> String {
        guard let data = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ) else { return attributed.string }
        let raw = String(data: data, encoding: .utf8) ?? attributed.string
        return htmlFragment(raw)
    }

    /// NSAttributedString HTML export wraps a full document — keep only the body fragment
    /// plus the &lt;style&gt; block so that CSS classes (colors, fonts, weights) survive
    /// round-tripping through the JSON store.
    static func htmlFragment(_ document: String) -> String {
        let ns = document as NSString
        let full = NSRange(location: 0, length: ns.length)
        var style = ""
        if let styleRegex = try? NSRegularExpression(pattern: "(?is)<style[^>]*>(.*?)</style>"),
           let m = styleRegex.firstMatch(in: document, options: [], range: full),
           m.numberOfRanges > 1 {
            style = ns.substring(with: m.range(at: 0))
        }
        if let regex = try? NSRegularExpression(pattern: "(?is)<body[^>]*>(.*?)</body>"),
           let match = regex.firstMatch(in: document, options: [], range: full),
           match.numberOfRanges > 1 {
            let body = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return style + body
        }
        if document.contains("<!DOCTYPE") || document.localizedCaseInsensitiveContains("<html") {
            return document
                .replacingOccurrences(of: #"(?is)<!DOCTYPE[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?is)</?html[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?is)<head>.*?</head>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?is)</?body[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return document
    }

    static func plainText(html: String?, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty,
           !fallback.contains("<!DOCTYPE"),
           !fallback.contains("<html"),
           !(fallback.hasPrefix("<") && fallback.contains(">")) {
            return fallback
        }
        let source = html ?? fallback ?? ""
        if source.isEmpty { return "" }
        if !source.contains("<") { return source }
        return attributed(html: source, plain: fallback, size: 16, ink: .labelColor).string
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String, String, CGSize) -> Void
        var onBeginEditing: (() -> Void)?
        var onEndEditing: (() -> Void)?
        var onSelectionChange: ((NSRange, CGRect?) -> Void)?
        var onBind: ((GrowingTextView?) -> Void)?
        var isFormatChromeActive: () -> Bool
        var view: GrowingTextView?
        var lastHTML = ""
        var lastInkHex = ""
        var desiredFontSize: CGFloat = 16
        var suppressAutoResize = false
        var wasEditing = false
        private var lastSize: CGSize = .zero

        init(
            onChange: @escaping (String, String, CGSize) -> Void,
            onBeginEditing: (() -> Void)?,
            onEndEditing: (() -> Void)?,
            onSelectionChange: ((NSRange, CGRect?) -> Void)?,
            onBind: ((GrowingTextView?) -> Void)?,
            isFormatChromeActive: @escaping () -> Bool
        ) {
            self.onChange = onChange
            self.onBeginEditing = onBeginEditing
            self.onEndEditing = onEndEditing
            self.onSelectionChange = onSelectionChange
            self.onBind = onBind
            self.isFormatChromeActive = isFormatChromeActive
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let view { onBind?(view) }
            onBeginEditing?()
        }

        func textDidEndEditing(_ notification: Notification) {
            // Format bar / color swatches steal first responder. Persisting here races
            // applyColor and can remount the text view (flash + lost color).
            if isFormatChromeActive() { return }
            persist()
        }

        func textDidChange(_ notification: Notification) {
            persist()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else {
                onSelectionChange?(NSRange(location: 0, length: 0), nil)
                return
            }
            let range = view.selectedRange()
            onSelectionChange?(range, Self.selectionRectInWindowTopLeft(view: view, range: range))
        }

        /// Screen rect of the selection in top-left window coordinates (SwiftUI-compatible).
        static func selectionRectInWindowTopLeft(view: NSTextView, range: NSRange) -> CGRect? {
            guard range.length > 0 else { return nil }
            var actual = NSRange()
            let screenRect = view.firstRect(forCharacterRange: range, actualRange: &actual)
            guard screenRect.width > 0 || screenRect.height > 0, let window = view.window else { return nil }
            let inWindow = window.convertFromScreen(screenRect)
            // AppKit window coords are bottom-left; SwiftUI canvas chrome uses top-left.
            let h = window.contentView?.bounds.height ?? window.frame.height
            return CGRect(
                x: inWindow.minX,
                y: h - inWindow.maxY,
                width: max(inWindow.width, 1),
                height: max(inWindow.height, 1)
            )
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard !(textView.isEditable) else { return false }
            let raw: String = {
                if let url = link as? URL { return url.absoluteString }
                return "\(link)"
            }()
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func reportSize(_ size: CGSize) {
            guard !suppressAutoResize else { return }
            guard abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 else { return }
            lastSize = size
            persist(sizeOverride: size)
        }

        func invalidateSizeThrottle() {
            lastSize = .zero
        }

        private func persist(sizeOverride: CGSize? = nil) {
            guard let view, let storage = view.textStorage else { return }
            Self.linkifyPlainURLs(in: storage)
            // Never mutate live storage here — stripping a trailing `\n` undoes Enter.
            // Cocoa's HTML import artifact is healed only in `attributed(html:…)`.
            let html = CanvasTextEditor.html(from: storage)
            lastHTML = html
            let size = sizeOverride ?? view.fittingContentSize
            onChange(html, CanvasTextEditor.normalizedPlain(view.string), size)
        }

        static func linkifyPlainURLs(in storage: NSTextStorage) {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let full = NSRange(location: 0, length: storage.length)
            detector?.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
                guard let match, let url = match.url else { return }
                let range = match.range
                if storage.attribute(.link, at: range.location, effectiveRange: nil) == nil {
                    storage.addAttributes([
                        .link: url,
                        .foregroundColor: NSColor.systemBlue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: range)
                }
            }
        }
    }
}

enum TextTypingStyle {
    static func capture(from view: NSTextView) -> [NSAttributedString.Key: Any] {
        var keep = view.typingAttributes
        let loc = view.selectedRange().location
        if let storage = view.textStorage, storage.length > 0 {
            let probe = min(max(0, loc > 0 ? loc - 1 : 0), storage.length - 1)
            if let color = storage.attribute(.foregroundColor, at: probe, effectiveRange: nil) as? NSColor {
                keep[.foregroundColor] = color
            }
            if let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont {
                keep[.font] = font
            }
        }
        return keep
    }

    static func restore(_ attrs: [NSAttributedString.Key: Any], on view: NSTextView) {
        var next = view.typingAttributes
        if let color = attrs[.foregroundColor] {
            next[.foregroundColor] = color
            if let ns = color as? NSColor {
                view.insertionPointColor = ns
            }
        }
        if let font = attrs[.font] {
            next[.font] = font
        }
        view.typingAttributes = next
    }
}

/// Canvas / note plain-text list marks (`• `, `1. `, `☐ `).
enum TextListMarkup {
    enum Kind { case bullet, numbered, todo }

    private static let bulletPattern = #"^([•·\*\-]|[\u{2022}])\s+"#
    private static let todoPattern = #"^[☐☑]\s+"#
    private static let numberedPattern = #"^\d+\.\s+"#

    static func strip(_ line: String) -> String {
        var current = line
        while true {
            if let range = current.range(of: bulletPattern, options: .regularExpression)
                ?? current.range(of: todoPattern, options: .regularExpression)
                ?? current.range(of: numberedPattern, options: .regularExpression)
            {
                let next = String(current[range.upperBound...])
                if next == current { break }
                current = next
                continue
            }
            break
        }
        return current
    }

    static func hasMark(_ line: String, _ kind: Kind) -> Bool {
        switch kind {
        case .bullet: return line.range(of: bulletPattern, options: .regularExpression) != nil
        case .todo: return line.range(of: todoPattern, options: .regularExpression) != nil
        case .numbered: return line.range(of: numberedPattern, options: .regularExpression) != nil
        }
    }

    static func hasAnyMark(_ line: String) -> Bool {
        hasMark(line, .bullet) || hasMark(line, .todo) || hasMark(line, .numbered)
    }

    /// Toggle off when every line is already `kind`; otherwise strip any mark and apply `kind`
    /// (so bullet → numbered actually switches, and numbered lines become 1. 2. 3.).
    static func apply(_ kind: Kind, to block: String) -> String {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return block }
        let stripped = lines.map(strip)
        let allOn = lines.allSatisfy { hasMark($0, kind) }
        if allOn {
            return stripped.joined(separator: "\n")
        }
        return stripped.enumerated().map { index, line in
            switch kind {
            case .bullet: return "• " + line
            case .todo: return "☐ " + line
            case .numbered: return "\(index + 1). " + line
            }
        }.joined(separator: "\n")
    }

    /// Grow from `location` across contiguous list lines (any mark), so switching
    /// numbered → todo rewrites the whole list without a multi-line selection.
    static func contiguousListParagraphRange(in ns: NSString, location: Int) -> NSRange {
        let len = ns.length
        guard len > 0 else { return NSRange(location: 0, length: 0) }
        let loc = min(max(0, location), len)
        var para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        // Walk upward.
        while para.location > 0 {
            let prevLoc = para.location - 1
            let prev = ns.paragraphRange(for: NSRange(location: prevLoc, length: 0))
            let line = ns.substring(with: prev)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            guard hasAnyMark(line) else { break }
            para = NSRange(location: prev.location, length: NSMaxRange(para) - prev.location)
        }
        // Walk downward.
        while NSMaxRange(para) < len {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(para), length: 0))
            if next.length == 0 || next == para { break }
            let line = ns.substring(with: next)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            guard hasAnyMark(line) else { break }
            para = NSRange(location: para.location, length: NSMaxRange(next) - para.location)
        }
        // If caret wasn't on a list line, still return its paragraph (apply will add marks).
        return para
    }

    /// Prefix to insert on the next line after Enter, or nil if the line isn't a list item.
    static func continuation(after line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if hasMark(trimmed, .bullet) { return "• " }
        if hasMark(trimmed, .todo) { return "☐ " }
        guard let match = trimmed.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) else { return nil }
        let token = String(trimmed[match])
        let digits = token.prefix(while: { $0.isNumber })
        guard let n = Int(digits) else { return "1. " }
        return "\(n + 1). "
    }

    static func isBlankListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard continuation(after: trimmed) != nil else { return false }
        return strip(trimmed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Font/color of the list mark at the start of `paragraph` (keeps ☐/• aligned + weight).
    static func markAttributes(
        in storage: NSTextStorage,
        paragraph: NSRange,
        fallback: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var attrs = fallback
        guard storage.length > 0 else { return attrs }
        let probe = min(max(0, paragraph.location), storage.length - 1)
        // A todo line starts with the mark, whose font `markFont` deliberately inflates.
        // Probing it handed that font to the next line, so Enter produced a line typed at
        // 1.8× — and its own mark was then inflated again on top of that.
        if TodoMarks.isMark((storage.string as NSString).character(at: probe)) {
            attrs[.font] = TodoMarks.bodyFont(in: storage, at: probe)
        } else if let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont {
            attrs[.font] = font
        }
        if let color = storage.attribute(.foregroundColor, at: probe, effectiveRange: nil) as? NSColor {
            attrs[.foregroundColor] = color
        }
        return attrs
    }

    /// Insert the next-line mark with the same glyph metrics as the previous line’s mark.
    static func insertContinuationMark(_ mark: String, in view: NSTextView, attributes: [NSAttributedString.Key: Any]) {
        var attrs = view.typingAttributes
        if let font = attributes[.font] { attrs[.font] = font }
        if let color = attributes[.foregroundColor] {
            attrs[.foregroundColor] = color
            if let ns = color as? NSColor {
                view.insertionPointColor = ns
            }
        }
        let attributed = NSAttributedString(string: mark, attributes: attrs)
        let range = view.selectedRange()
        guard view.shouldChangeText(in: range, replacementString: mark) else { return }
        view.textStorage?.replaceCharacters(in: range, with: attributed)
        if let storage = view.textStorage {
            TodoMarks.restyleMarks(in: storage, range: NSRange(location: range.location, length: (mark as NSString).length))
        }
        view.setSelectedRange(NSRange(location: range.location + (mark as NSString).length, length: 0))
        view.didChangeText()
        // Type at the body size after the mark: `restyleMarks` owns the mark's own font,
        // and letting it leak into typing attributes is what blew the next line up.
        TextTypingStyle.restore(attrs, on: view)
    }
}

/// ☐ / ☑ list marks — clickable in preview and while editing.
extension NSAttributedString.Key {
    /// Display-only marker for text on a ticked todo line — never serialized.
    static let todoDimmed = NSAttributedString.Key("vasaTodoDimmed")
}

enum TodoMarks {
    nonisolated static let unchecked: unichar = 0x2610
    nonisolated static let checked: unichar = 0x2611

    nonisolated static func isMark(_ ch: unichar) -> Bool {
        ch == unchecked || ch == checked
    }

    /// The mark character's glyph is never actually drawn (`TodoAwareLayoutManager`
    /// always paints `drawCheckbox` in its place instead) — so its font only
    /// matters for LAYOUT now: the advance width and line-height it reserves.
    /// Keep it at the body's own size so the checkbox never inflates the
    /// line/text-block; `drawCheckbox` does all the "make it look chunky and
    /// distinct" work purely by painting bigger than that reserved cell.
    /// The mark reserves a cell 1.8 × the body size. Reference rows measure 145 px pitch
    /// on a 49 px cap height with an 86 px box and a 37 px gap before the text: that extra
    /// room comes from the mark's own font, and it is what keeps the painted square clear
    /// of both the neighbouring rows and the following text.
    /// How much bigger than the body the mark's cell is.
    nonisolated static let markScale: CGFloat = 1.8

    /// Family the marks are drawn from — text must never end up in it.
    nonisolated static var markFamily: String {
        markFont(bodyFont: .systemFont(ofSize: 16)).familyName ?? "Apple Symbols"
    }

    /// Body size behind a font that is really a mark cell.
    nonisolated static func bodySize(fromMark font: NSFont) -> CGFloat {
        max(8, (font.pointSize / markScale).rounded())
    }

    static func markFont(bodyFont: NSFont) -> NSFont {
        let size = bodyFont.pointSize * markScale
        let base = NSFont.systemFont(ofSize: size)
        // Resolve whichever face actually supplies ☐ and use it for ☑ as well. Left to
        // the system font, the two marks fall back to different faces with different
        // line metrics (fragment 28.4 pt / baseline 19 for ☐ against 34 / 28 for ☑),
        // so ticking an item dropped that whole row — box and text — by 9 pt.
        let resolved = CTFontCreateForString(
            base as CTFont,
            "\u{2610}" as CFString,
            CFRange(location: 0, length: 1)
        )
        let descriptor = CTFontCopyFontDescriptor(resolved) as NSFontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Re-applies the enlarged/bold checkbox font to every ☐/☑ in `range` of
    /// `text` (or the whole string when `range` is nil). Always derives the
    /// "body" size from the text just after the mark — never from the mark's
    /// own current font — so calling this repeatedly (on every edit) can't
    /// compound the enlargement.
    static func restyleMarks(in text: NSMutableAttributedString, range: NSRange? = nil) {
        if range == nil { healInheritedMarkFont(in: text) }
        let full = range ?? NSRange(location: 0, length: text.length)
        guard full.length > 0, NSMaxRange(full) <= text.length else { return }
        let ns = text.string as NSString
        for idx in full.location..<NSMaxRange(full) {
            let ch = ns.character(at: idx)
            guard isMark(ch) else { continue }
            let body = bodyFont(in: text, at: idx)
            let mark = markFont(bodyFont: body)
            let cell = NSRange(location: idx, length: 1)
            text.addAttribute(.font, value: mark, range: cell)
            // ☐ and ☑ can fall back to system glyphs with different advances, which made
            // the text after the mark (and the box drawn over it) shift sideways the
            // moment an item was ticked. Kern each mark back to the ☐ advance so the
            // cell is the same width in both states.
            let target = advance(of: unchecked, in: mark)
            let actual = advance(of: ch, in: mark)
            text.addAttribute(.kern, value: target - actual, range: cell)
            applyDimming(in: text, markAt: idx)
        }
    }

    /// Repairs text that inherited the mark's own (inflated, symbol-family) font — older
    /// saves made on Enter, before `markAttributes` learned to probe the line's body.
    /// Any non-mark character in that family drops back to the system font at the size the
    /// body would have had.
    static func healInheritedMarkFont(in text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        let family = markFamily
        let ns = text.string as NSString
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, font.familyName == family else { return }
            for idx in range.location..<NSMaxRange(range) where !isMark(ns.character(at: idx)) {
                text.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: bodySize(fromMark: font)),
                    range: NSRange(location: idx, length: 1)
                )
            }
        }
    }

    /// A ticked item reads as done: its own line's text draws dimmed (measured at ~52%
    /// of the live ink in the reference — #7F8593 against #F5F6FB). Display-only, via a
    /// private key `TodoAwareLayoutManager` paints from, so no color is ever written
    /// into the card's HTML.
    static func applyDimming(in text: NSMutableAttributedString, markAt idx: Int) {
        let ns = text.string as NSString
        let line = ns.lineRange(for: NSRange(location: idx, length: 1))
        let tailStart = idx + 1
        let tail = NSRange(location: tailStart, length: max(0, NSMaxRange(line) - tailStart))
        guard tail.length > 0 else { return }
        if ns.character(at: idx) == checked {
            text.addAttribute(.todoDimmed, value: true, range: tail)
        } else {
            text.removeAttribute(.todoDimmed, range: tail)
        }
    }

    /// Character index of a todo mark under `viewPoint` (view coords), or nil.
    ///
    /// Hit-tests against the same box `drawCheckbox` actually paints, not the mark
    /// character's own (narrow) glyph cell — the checkbox is drawn deliberately larger
    /// than its reserved cell (see `drawCheckbox`), so using the raw glyph rect here left
    /// a hit-test gap around the visible box where a click would miss the toggle and fall
    /// through to placing a text cursor / entering edit mode instead.
    static func checkboxUTF16Index(in textView: NSTextView, at viewPoint: NSPoint) -> Int? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let origin = textView.textContainerOrigin
        let point = CGPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
        var fraction: CGFloat = 0
        let raw = lm.characterIndex(for: point, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let ns = textView.string as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(0, raw), ns.length - 1)
        for idx in [clamped, max(0, clamped - 1)] {
            let ch = ns.character(at: idx)
            guard isMark(ch) else { continue }
            let glyphs = lm.glyphRange(
                forCharacterRange: NSRange(location: idx, length: 1),
                actualCharacterRange: nil
            )
            let glyphRect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let font = textView.textStorage.map { bodyFont(in: $0, at: idx) } ?? .systemFont(ofSize: 16)
            let box = checkboxBox(
                for: glyphRect,
                baselineY: baselineY(in: lm, glyphs: glyphs),
                font: font
            ).insetBy(dx: -6, dy: -6)
            if box.contains(point) { return idx }
        }
        return nil
    }

    /// The square `drawCheckbox` paints, in the glyph's own coordinate space — shared with
    /// `checkboxUTF16Index` so the clickable area always matches what's actually drawn.
    ///
    /// Nothing here may depend on which mark is present: size comes from the line's body
    /// font, position from the line fragment and the ☐ cell width. Ticking a box only ever
    /// adds the checkmark — it never moves or resizes the square.
    static func checkboxBox(for glyphRect: NSRect, baselineY: CGFloat? = nil, font: NSFont) -> NSRect {
        // Reference proportion: 86 px box on a 49 px cap height.
        let side = font.capHeight * 1.75
        // Left-aligned in the cell the mark reserves (`markFont`), not centered on the
        // drawn glyph: the reference leaves a clear gap between box and text, so the
        // cell's slack belongs on the text side.
        // Vertically the box tracks the text, not the line box: the mark's inflated font
        // makes the line fragment much taller than the letters, so the fragment's center
        // sits above them. Centering on the cap height keeps box and text level.
        let centerY = baselineY.map { $0 - font.capHeight / 2 } ?? glyphRect.midY
        return NSRect(x: glyphRect.minX, y: centerY - side / 2, width: side, height: side)
    }

    /// Baseline of the line a mark sits on, in the layout manager's coordinates.
    static func baselineY(in lm: NSLayoutManager, glyphs: NSRange) -> CGFloat {
        let line = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return line.minY + lm.location(forGlyphAt: glyphs.location).y
    }

    /// Advance width of one mark character in `font`.
    nonisolated static func advance(of ch: unichar, in font: NSFont) -> CGFloat {
        var value = ch
        let string = NSString(characters: &value, length: 1)
        return string.size(withAttributes: [.font: font]).width
    }

    /// Font of the line's text, not of the mark character — so a toggle (which can
    /// restyle the mark itself) can never change the box's size.
    nonisolated static func bodyFont(in storage: NSAttributedString, at utf16: Int) -> NSFont {
        let ns = storage.string as NSString
        func real(_ idx: Int) -> NSFont? {
            let ch = ns.character(at: idx)
            guard !isMark(ch), ch != 0x20, ch != 0x000A, ch != 0x000D else { return nil }
            return storage.attribute(.font, at: idx, effectiveRange: nil) as? NSFont
        }
        // Text on this line, then anywhere in the block. Never the mark's own font: that
        // one is inflated by `markFont`, so an item with no text yet drew a giant box
        // that snapped smaller the moment the first character was typed.
        var probe = utf16 + 1
        while probe < ns.length {
            let ch = ns.character(at: probe)
            if ch == 0x000A || ch == 0x000D { break }
            if let font = real(probe) { return font }
            probe += 1
        }
        for idx in 0..<ns.length where idx != utf16 {
            if let font = real(idx) { return font }
        }
        return .systemFont(ofSize: 16)
    }

    /// The painted checkbox square in the text view's own coordinates — what the
    /// toggle halftone centers on.
    static func checkboxRect(in textView: NSTextView, at utf16: Int) -> NSRect? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, utf16 >= 0, utf16 < storage.length
        else { return nil }
        let glyphs = lm.glyphRange(
            forCharacterRange: NSRange(location: utf16, length: 1),
            actualCharacterRange: nil
        )
        let glyphRect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let font = bodyFont(in: storage, at: utf16)
        let origin = textView.textContainerOrigin
        return checkboxBox(for: glyphRect, baselineY: baselineY(in: lm, glyphs: glyphs), font: font)
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    @discardableResult
    @MainActor
    static func toggle(in textView: NSTextView, at utf16: Int) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        guard utf16 >= 0, utf16 < ns.length else { return false }
        let ch = ns.character(at: utf16)
        let next: String
        if ch == unchecked { next = "☑" }
        else if ch == checked { next = "☐" }
        else { return false }
        storage.replaceCharacters(in: NSRange(location: utf16, length: 1), with: next)
        restyleMarks(in: storage, range: NSRange(location: utf16, length: 1))
        textView.needsDisplay = true
        AppSounds.playToggle(next == "☑")
        return true
    }

    /// Toggle mark in displayed plain text; mirrors the N-th ☐/☑ in HTML when present.
    static func toggle(plain: String, html: String?, at utf16: Int) -> (plain: String, html: String)? {
        let ns = plain as NSString
        guard utf16 >= 0, utf16 < ns.length else { return nil }
        let ch = ns.character(at: utf16)
        let replacement: String
        if ch == unchecked { replacement = "☑" }
        else if ch == checked { replacement = "☐" }
        else { return nil }

        let newPlain = ns.replacingCharacters(in: NSRange(location: utf16, length: 1), with: replacement)
        var occurrence = 0
        if utf16 > 0 {
            for i in 0..<utf16 where isMark(ns.character(at: i)) {
                occurrence += 1
            }
        }
        let newHtml: String
        if let html, html.contains("<"),
           let replaced = replaceMarkOccurrence(in: html, occurrence: occurrence, with: replacement)
        {
            newHtml = replaced
        } else if let html, !html.isEmpty,
                  let replaced = replaceMarkOccurrence(in: html, occurrence: occurrence, with: replacement)
        {
            newHtml = replaced
        } else {
            newHtml = newPlain
        }
        return (newPlain, newHtml)
    }

    private static func replaceMarkOccurrence(in text: String, occurrence: Int, with mark: String) -> String? {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "[\u{2610}\u{2611}]") else { return nil }
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard occurrence >= 0, occurrence < matches.count else { return nil }
        return ns.replacingCharacters(in: matches[occurrence].range, with: mark)
    }

    /// Rounded, app-styled checkbox drawn in place of the plain ☐/☑ glyph —
    /// used by `TodoAwareLayoutManager`. Purely a paint step: the character
    /// under it is still literally "☐"/"☑", so every match/toggle/persist
    /// path that depends on that literal character keeps working unchanged.
    nonisolated static func drawCheckbox(
        checked: Bool,
        hovered: Bool = false,
        in glyphRect: NSRect,
        baselineY: CGFloat? = nil,
        font: NSFont
    ) {
        let box = checkboxBox(for: glyphRect, baselineY: baselineY, font: font)
        let side = box.width
        guard side > 1 else { return }
        // Reference proportions on an 86 px box: 17 px corner radius, 4 px stroke.
        let radius = side * 0.20
        // Dynamic providers so the checkbox brightens with the effective appearance instead
        // of keeping its light-mode gray/blue when the app (or the system) switches to dark.
        // Resting stroke is dim; pointing at the box lifts it (measured 0.24 → 0.47 white).
        let strokeColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let white: CGFloat = dark
                ? (hovered ? 0.47 : 0.26)
                : (hovered ? 0.55 : 0.72)
            return NSColor(calibratedWhite: white, alpha: 1)
        }
        let checkColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: hovered ? 0.92 : 0.75, alpha: 1)
                : NSColor(calibratedWhite: hovered ? 0.28 : 0.38, alpha: 1)
        }
        // Filled, not hollow: the reference paints the well a touch lighter than the card
        // (#1E1D24 against #17171B); in light mode it is plain white under the same stroke.
        let fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.118, green: 0.114, blue: 0.141, alpha: 1)
                : NSColor(calibratedWhite: 1, alpha: 1)
        }
        let path = NSBezierPath(roundedRect: box.insetBy(dx: side * 0.06, dy: side * 0.06), xRadius: radius, yRadius: radius)
        path.lineWidth = max(1.2, side * 0.055)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.stroke()
        guard checked else { return }
        let check = NSBezierPath()
        let pen = max(1.6, side * 0.12)
        check.lineWidth = pen
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        // Round caps push the painted shape half a pen past every endpoint, so the path
        // is laid out from the *inked* box it should occupy and then inset by that half
        // pen. Painted extent: 0.64 × 0.50 of the square, centered on it exactly.
        let cap = pen / 2
        let inkW = side * 0.64
        let inkH = side * 0.50
        let left = box.midX - inkW / 2 + cap
        let right = box.midX + inkW / 2 - cap
        let top = box.midY - inkH / 2 + cap
        let bottom = box.midY + inkH / 2 - cap
        // The elbow sits where a checkmark's short arm meets the long one: 30% along.
        let elbowX = left + (right - left) * 0.30
        // NSTextView is flipped (y grows downward), so the "dip then rise"
        // shape of a checkmark needs the larger y first (visually lower).
        check.move(to: NSPoint(x: left, y: bottom - (bottom - top) * 0.42))
        check.line(to: NSPoint(x: elbowX, y: bottom))
        check.line(to: NSPoint(x: right, y: top))
        checkColor.setStroke()
        check.stroke()
    }
}

/// A text view that tracks which ☐/☑ the pointer is over, so the layout manager can
/// paint that one in its hover state.
protocol TodoHoverHosting: AnyObject {
    var hoveredMarkIndex: Int? { get }
}

/// Paints `TodoMarks.drawCheckbox` in place of the plain ☐/☑ glyph during
/// layout — display-only, never touches the text storage, so it's safe to
/// swap in on any NSTextView that already uses `TodoMarks` for hit-testing.
nonisolated final class TodoAwareLayoutManager: NSLayoutManager {
    /// Text on a ticked line draws in this instead of its own ink.
    nonisolated override func showCGGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        positions: UnsafePointer<CGPoint>,
        count glyphCount: Int,
        font: NSFont,
        textMatrix: CGAffineTransform,
        attributes: [NSAttributedString.Key: Any],
        in context: CGContext
    ) {
        if attributes[.todoDimmed] != nil {
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let dim = dark
                ? NSColor(calibratedRed: 0.50, green: 0.52, blue: 0.58, alpha: 1)
                : NSColor(calibratedRed: 0.55, green: 0.57, blue: 0.62, alpha: 1)
            context.setFillColor(dim.cgColor)
        }
        super.showCGGlyphs(
            glyphs,
            positions: positions,
            count: glyphCount,
            font: font,
            textMatrix: textMatrix,
            attributes: attributes,
            in: context
        )
    }

    nonisolated override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let ns = storage.string as NSString
        var runStart = charRange.location
        let end = NSMaxRange(charRange)

        func flush(upTo charEnd: Int) {
            guard charEnd > runStart else { return }
            let run = glyphRange(forCharacterRange: NSRange(location: runStart, length: charEnd - runStart), actualCharacterRange: nil)
            if run.length > 0 { super.drawGlyphs(forGlyphRange: run, at: origin) }
        }

        var idx = runStart
        while idx < end {
            let ch = ns.character(at: idx)
            if TodoMarks.isMark(ch) {
                flush(upTo: idx)
                let markGlyphs = glyphRange(forCharacterRange: NSRange(location: idx, length: 1), actualCharacterRange: nil)
                if markGlyphs.length > 0, let container = textContainer(forGlyphAt: markGlyphs.location, effectiveRange: nil) {
                    var rect = boundingRect(forGlyphRange: markGlyphs, in: container)
                    rect.origin.x += origin.x
                    rect.origin.y += origin.y
                    let font = TodoMarks.bodyFont(in: storage, at: idx)
                    let base = TodoMarks.baselineY(in: self, glyphs: markGlyphs) + origin.y
                    let hovered = (container.textView as? TodoHoverHosting)?.hoveredMarkIndex == idx
                    TodoMarks.drawCheckbox(
                        checked: ch == TodoMarks.checked,
                        hovered: hovered,
                        in: rect,
                        baselineY: base,
                        font: font
                    )
                }
                idx += 1
                runStart = idx
                continue
            }
            idx += 1
        }
        flush(upTo: end)
    }
}

final class GrowingTextView: NSTextView, TodoHoverHosting {
    /// Fired after a ☐/☑ click flips the mark, with the checkbox square in view
    /// coordinates so the canvas can bloom its halftone from exactly that spot.
    var onToggleCheckbox: ((CGRect) -> Void)?
    var onCheckboxHover: ((Bool) -> Void)?
    /// Mark the pointer currently sits on — drawn brighter, and takes a pointing hand.
    private(set) var hoveredMarkIndex: Int? {
        didSet {
            guard hoveredMarkIndex != oldValue else { return }
            needsDisplay = true
            onCheckboxHover?(hoveredMarkIndex != nil)
        }
    }
    private var todoTracking: NSTrackingArea?
    /// Hard ceiling for auto-grown text cards.
    static let maxContentWidth: CGFloat = 640
    /// Default wrap column — paste / long runs grow height, not an endless line.
    static let preferredWrapWidth: CGFloat = CGFloat(Format.textWrapWidth)

    static var wrappingParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .left
        return style
    }

    var onSizeChange: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        focusRingType = .none
        drawsBackground = false
        backgroundColor = .clear
        self.textContainer?.replaceLayoutManager(TodoAwareLayoutManager())
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        drawsBackground = false
        backgroundColor = .clear
        self.textContainer?.replaceLayoutManager(TodoAwareLayoutManager())
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
        drawsBackground = false
        backgroundColor = .clear
        self.textContainer?.replaceLayoutManager(TodoAwareLayoutManager())
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !isEditable {
            discardCursorRects()
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isEditable {
            return super.hitTest(point)
        }
        // Preview mode: only capture todo checkbox clicks so card select/drag still work.
        guard let _ = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        return TodoMarks.checkboxUTF16Index(in: self, at: local) != nil ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tracking a checkbox hover needs mouse-moved events on this window.
        window?.acceptsMouseMovedEvents = true
        if window == nil { hoveredMarkIndex = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let todoTracking { removeTrackingArea(todoTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        todoTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateTodoHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredMarkIndex = nil
    }

    private func updateTodoHover(at point: NSPoint) {
        let idx = TodoMarks.checkboxUTF16Index(in: self, at: point)
        hoveredMarkIndex = idx
        if idx != nil { NSCursor.pointingHand.set() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Also refresh on the click itself: a press without a preceding move (after a
        // scroll or a re-layout) must still be seen as a checkbox hit, not a card press.
        updateTodoHover(at: point)
        if let idx = TodoMarks.checkboxUTF16Index(in: self, at: point) {
            let box = TodoMarks.checkboxRect(in: self, at: idx)
            let willCheck = (string as NSString).character(at: idx) == TodoMarks.unchecked
            if TodoMarks.toggle(in: self, at: idx) {
                didChangeText()
                // Ticking celebrates; clearing a tick is silent — no bloom on the way back.
                if willCheck, let box { onToggleCheckbox?(box) }
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Keep foreground/font across Enter so list/todo lines don't flash default ink until ESC.
    /// Continues `• ` / `N. ` / `☐ ` on the new line; blank list item exits the list.
    /// AppKit rebuilds typing attributes from the character before the caret, so putting
    /// the caret after a mark handed the next keystroke the mark's inflated cell font —
    /// the line grew again on the first letter typed. Fold any such font back to its body
    /// size here, where every path (typing, paste, selection change) goes through.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attrs = newValue
            if let font = attrs[.font] as? NSFont, font.familyName == TodoMarks.markFamily {
                attrs[.font] = NSFont.systemFont(ofSize: TodoMarks.bodySize(fromMark: font))
            }
            super.typingAttributes = attrs
        }
    }

    override func insertNewline(_ sender: Any?) {
        var keep = TextTypingStyle.capture(from: self)
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        // Caret sitting straight after a mark carries the mark's inflated font — never
        // let that become the next line's body size.
        if loc > 0, TodoMarks.isMark(ns.character(at: loc - 1)), let storage = textStorage {
            keep[.font] = TodoMarks.bodyFont(in: storage, at: loc - 1)
        }
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: para)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
        let markStyle: [NSAttributedString.Key: Any] = {
            guard let storage = textStorage else { return keep }
            return TextListMarkup.markAttributes(in: storage, paragraph: para, fallback: keep)
        }()

        if TextListMarkup.isBlankListItem(line) {
            // Exit list: replace the bare mark with an empty line.
            let plain = TextListMarkup.strip(line)
            textStorage?.replaceCharacters(in: para, with: plain)
            setSelectedRange(NSRange(location: para.location + (plain as NSString).length, length: 0))
            TextTypingStyle.restore(keep, on: self)
            didChangeText()
            AppSounds.playType()
            return
        }

        let nextMark = TextListMarkup.continuation(after: line)
        super.insertNewline(sender)
        // Restore before inserting the mark — otherwise ☐ inherits a thinner default font
        // and shifts left relative to the previous line.
        TextTypingStyle.restore(markStyle, on: self)
        if let nextMark {
            TextListMarkup.insertContinuationMark(nextMark, in: self, attributes: markStyle)
        }
        AppSounds.playType()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Belt to the typingAttributes brace: AppKit may seed the run from the character
        // before the caret without going through the property, so a letter typed right
        // after a mark would still land in the mark's inflated cell font.
        demoteMarkFontAtCaret(replacementRange: replacementRange)
        // Replace "--" with "—" (em-dash) as the user types.
        let text: String = {
            if let s = insertString as? String { return s }
            if let a = insertString as? NSAttributedString { return a.string }
            return ""
        }()
        if text == "-" || text == "\u{2014}" {
            super.insertText(insertString, replacementRange: replacementRange)
            maybeReplaceDoubleDash()
            if !text.isEmpty { AppSounds.playType() }
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        if !text.isEmpty { AppSounds.playType() }
    }

    /// Fold the mark's cell font out of the typing attributes when the caret sits right
    /// after a ☐/☑, so what gets typed is body-sized.
    private func demoteMarkFontAtCaret(replacementRange: NSRange) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let caret = replacementRange.location == NSNotFound
            ? selectedRange().location
            : replacementRange.location
        guard caret > 0, caret <= ns.length, TodoMarks.isMark(ns.character(at: caret - 1)) else { return }
        var attrs = typingAttributes
        attrs[.font] = TodoMarks.bodyFont(in: storage, at: caret - 1)
        typingAttributes = attrs
    }

    /// Replace the two characters before the caret with "—" when they are "--".
    private func maybeReplaceDoubleDash() {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        // Need at least two characters before the insertion point.
        guard sel.location >= 2 else { return }
        let ns = storage.string as NSString
        let prevTwo = ns.substring(with: NSRange(location: sel.location - 2, length: 2))
        guard prevTwo == "--" else { return }
        storage.replaceCharacters(in: NSRange(location: sel.location - 2, length: 2), with: "\u{2014}")
        setSelectedRange(NSRange(location: sel.location - 1, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        if cmd {
            switch event.keyCode {
            case 11: // Cmd+B
                toggleBold()
                return
            case 34: // Cmd+I
                toggleItalic()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    func toggleBold() {
        toggleTrait(.bold)
    }

    func toggleItalic() {
        toggleTrait(.italic)
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let storage = textStorage else { return }
        let size = (typingAttributes[.font] as? NSFont)?.pointSize ?? 16
        let live = selectedRange()
        let fullLen = storage.length
        let target: NSRange = {
            if live.length > 0 { return live }
            return NSRange(location: 0, length: fullLen)
        }()

        if target.length == 0 {
            var typing = typingAttributes
            let current = (typing[.font] as? NSFont) ?? NSFont.systemFont(ofSize: size)
            let descriptors = current.fontDescriptor.withSymbolicTraits(
                current.fontDescriptor.symbolicTraits.contains(trait)
                    ? current.fontDescriptor.symbolicTraits.subtracting(trait)
                    : current.fontDescriptor.symbolicTraits.union(trait)
            )
            typing[.font] = NSFont(descriptor: descriptors, size: current.pointSize) ?? current
            typingAttributes = typing
        } else {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: target) { value, subrange, _ in
                let current = (value as? NSFont) ?? NSFont.systemFont(ofSize: size)
                let descriptors = current.fontDescriptor.withSymbolicTraits(
                    current.fontDescriptor.symbolicTraits.contains(trait)
                        ? current.fontDescriptor.symbolicTraits.subtracting(trait)
                        : current.fontDescriptor.symbolicTraits.union(trait)
                )
                storage.addAttribute(.font, value: NSFont(descriptor: descriptors, size: current.pointSize) ?? current, range: subrange)
            }
            storage.endEditing()
            setSelectedRange(target)
        }
        didChangeText()
    }

    /// Horizontal inset inside the text field (spare so glyphs/caret never kiss the stroke).
    static let contentPadX: CGFloat = 10
    /// Vertical inset — keep caret clear of the selection stroke (top and bottom).
    static let contentPadY: CGFloat = 8
    /// Extra air between editor content and the editing chrome stroke.
    static let chromeGap: CGFloat = 2

    /// Content-column width from the last fit (glyphs only, no pads).
    /// Prevents SwiftUI's laggy seed frame from forcing a 3-character wrap column.
    private var idealContentColumn: CGFloat = 40
    /// When true (corner-resize), container follows the view frame exactly.
    var frameDrivesContainer = false

    /// Longest hard line in points (Enter-separated). Soft wrap is ignored.
    private func longestHardLineWidth(storage: NSTextStorage) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        let huge = CGSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        let plain = storage.string as NSString
        var widest: CGFloat = 0
        plain.enumerateSubstrings(
            in: NSRange(location: 0, length: plain.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            let slice = storage.attributedSubstring(from: range)
            let rect = slice.boundingRect(
                with: huge,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            widest = max(widest, ceil(rect.width))
        }
        if widest == 0 {
            let rect = storage.boundingRect(
                with: huge,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            widest = ceil(rect.width)
        }
        return widest
    }

    var fittingContentSize: CGSize {
        guard let container = textContainer, let layout = layoutManager, let storage = textStorage else {
            return NSSize(width: 24, height: 22)
        }
        container.widthTracksTextView = false
        container.lineBreakMode = .byWordWrapping

        let padX = Self.contentPadX
        let spare: CGFloat = 8
        let hasText = storage.length > 0
        let padY = Self.contentPadY
        let wrap = Self.preferredWrapWidth
        let wrapContent = max(48, wrap - padX * 2)

        let lineW = longestHardLineWidth(storage: storage)
        let contentColumn: CGFloat
        let width: CGFloat
        let height: CGFloat

        if !hasText {
            contentColumn = 20
            width = TextToolReducer.defaultSize.width
            height = TextToolReducer.defaultSize.height
        } else if lineW <= wrapContent {
            // Hug longest hard line (Enter does not change width rule).
            contentColumn = max(12, lineW)
            width = max(36, ceil(contentColumn + padX * 2 + spare))
            container.containerSize = NSSize(width: max(contentColumn, 12), height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            height = max(TextToolReducer.defaultSize.height, ceil(used.height + padY * 2 + 4))
        } else {
            // Past max — wrap downward like a paragraph block.
            contentColumn = wrapContent
            width = wrap
            container.containerSize = NSSize(width: wrapContent, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            height = max(TextToolReducer.defaultSize.height, ceil(used.height + padY * 2 + 4))
        }

        idealContentColumn = contentColumn
        container.containerSize = NSSize(width: contentColumn, height: CGFloat.greatestFiniteMagnitude)
        return NSSize(width: width, height: height)
    }

    override var intrinsicContentSize: NSSize { fittingContentSize }

    override func drawBackground(in rect: NSRect) {
        // Plain canvas text — never fill.
    }

    override func didChangeText() {
        super.didChangeText()
        // Fit first so container isn't stuck on the seed width when refresh measures height.
        let size = fittingContentSize
        refreshEmptyPresentation()
        invalidateIntrinsicContentSize()
        onSizeChange?(size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.widthTracksTextView = false
        textContainer?.lineBreakMode = .byWordWrapping
        let insetX = max(textContainerInset.width, Self.contentPadX)
        let fromFrame = max(40, newSize.width - insetX * 2)
        // Auto-size: never lay out narrower than the measured longest line (seed-frame trap).
        let column: CGFloat = {
            if frameDrivesContainer { return fromFrame }
            return max(fromFrame, idealContentColumn)
        }()
        textContainer?.containerSize = NSSize(
            width: column,
            height: CGFloat.greatestFiniteMagnitude
        )
        refreshEmptyPresentation()
    }

    /// Match empty-seed look while typing one line: vertically centered in the seed height.
    func refreshEmptyPresentation() {
        let font = self.font ?? NSFont.systemFont(ofSize: 16)
        let lineH = layoutManager?.defaultLineHeight(for: font)
            ?? max(18, ceil(font.ascender - font.descender + font.leading))
        let usedH: CGFloat = {
            guard let container = textContainer, let layout = layoutManager else { return lineH }
            layout.ensureLayout(for: container)
            return max(lineH, ceil(layout.usedRect(for: container).height))
        }()
        let singleLine = usedH <= lineH + 2
        let padX = Self.contentPadX
        // Caret draws slightly taller than the line box — reserve room so it never kisses the stroke.
        let caretH = lineH + 3
        // Center vertically for as long as content stays single-line — typing the first
        // character used to flip this straight to top-flush (the `empty` field only fired
        // it while the storage was truly empty), which snapped the centered caret up to the
        // top edge the instant a character landed: a visible jump on the very first keystroke.
        // Keying off `singleLine` instead keeps the seed→first-char transition stable; it only
        // moves to top padding once content actually wraps to a second line, where centering
        // would otherwise leave a hollow gap under the glyphs.
        if singleLine, bounds.height > caretH + Self.contentPadY * 2 {
            let vPad = max(Self.contentPadY, floor((bounds.height - caretH) / 2))
            textContainerInset = NSSize(width: padX, height: vPad)
        } else {
            textContainerInset = NSSize(width: padX, height: Self.contentPadY)
        }

        var typing = typingAttributes
        typing[.font] = font
        if typing[.foregroundColor] == nil { typing[.foregroundColor] = textColor ?? .labelColor }
        typing[.paragraphStyle] = Self.wrappingParagraphStyle
        typingAttributes = typing
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let html = pb.string(forType: .html), html.contains("<"), let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           )
        {
            insertRich(attributed)
            return
        }
        if let rtf = pb.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil)
        {
            insertRich(attributed)
            return
        }
        super.pasteAsPlainText(sender)
        if let storage = textStorage {
            CanvasTextEditor.Coordinator.linkifyPlainURLs(in: storage)
            didChangeText()
        }
    }

    private func insertRich(_ attributed: NSAttributedString) {
        let selected = selectedRange()
        let storage = NSTextStorage(attributedString: attributed)
        let full = NSRange(location: 0, length: storage.length)
        if full.length > 0 {
            storage.addAttribute(.paragraphStyle, value: Self.wrappingParagraphStyle, range: full)
        }
        CanvasTextEditor.Coordinator.linkifyPlainURLs(in: storage)
        if shouldChangeText(in: selected, replacementString: storage.string) {
            textStorage?.replaceCharacters(in: selected, with: storage)
            didChangeText()
        }
    }
}

/// Creation halftone: one Gaussian crest walks outward from the card's own
/// rounded-rect contour, on a lattice locked to the canvas `DotGrid`.
///
/// Measured off the reference capture (30 fps, 2× display, canvas zoom 2 →
/// `DotGrid` pitch 96 px): wave lattice pitch 32 px = `gridStep / 3` and phase
/// locked to the grid; crest starts on the contour and travels ~1.6 × the field's
/// long side; front stays parallel to the contour (the diagonal / axis reach ratio
/// falls 1.24 → 1.10 as the offset grows, which is exactly a rect offset, not a
/// circle and not a square); peak dot diameter 28 px → 9 px over the run; crest
/// FWHM 88 px → 32 px; total run ~0.78 s.
struct TextGaussianWave: View {
    /// Field geometry snapshot in screen space (at creation).
    let fieldFrame: CGRect
    /// Screen-space corner radius of the card's clip shape (0 for ink).
    var cornerRadius: CGFloat = 8
    let startDate: Date
    var duration: TimeInterval = 0.78
    /// Canvas grid pitch in screen space (`24 * zoom`).
    var gridStep: CGFloat = 24
    /// Screen-space origin of the first DotGrid node (camera remainder phase).
    var gridOrigin: CGPoint = .zero
    /// Widens (or narrows) how far the crest travels past the contour.
    var spread: CGFloat = 1
    var onComplete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var didComplete = false

    /// Lattice pitch: exactly a third of the canvas grid, so every third node
    /// coincides with a resting `DotGrid` dot.
    private var step: CGFloat { max(6, gridStep / 3) }

    /// How far past the contour the crest ends up. Constant, not field-derived: in the
    /// reference the ink burst (field 165 pt) and the checkbox burst (field ~15 pt) both
    /// travel ~7 canvas-grid steps at the same ~29 px/frame, so the bloom is the same
    /// size whatever it grows out of.
    private var travel: CGFloat { gridStep * 7 * spread }

    private var pad: CGFloat { travel + step * 3 }

    var body: some View {
        if reduceMotion {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { finish() }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                let raw = context.date.timeIntervalSince(startDate) / duration
                let t = CGFloat(min(1, max(0, raw)))
                Canvas { ctx, _ in
                    draw(ctx: ctx, t: t)
                }
                .onChange(of: t) { _, value in
                    if value >= 1 { finish() }
                }
            }
            .frame(width: fieldFrame.width + pad * 2, height: fieldFrame.height + pad * 2)
            .position(x: fieldFrame.midX, y: fieldFrame.midY)
            .allowsHitTesting(false)
            .onAppear {
                if Date.now.timeIntervalSince(startDate) >= duration { finish() }
            }
        }
    }

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        onComplete?()
    }

    private func draw(ctx: GraphicsContext, t: CGFloat) {
        let half = CGSize(width: fieldFrame.width * 0.5, height: fieldFrame.height * 0.5)
        let radius = min(cornerRadius, min(half.width, half.height))
        // Crest offset outside the contour; the capture's front advances at a
        // near-constant speed, so this stays linear in t.
        let crest = travel * t
        // The ring tightens as it goes: ~1.05 → ~0.44 lattice steps of sigma.
        let sigma = step * (1.05 + (0.44 - 1.05) * t)
        // Dot diameter decays close to (1 - t)^1.4 in the capture.
        let amp = pow(max(0, 1 - t), 1.4)
        let sizePeak = step * 0.92
        let sizeFloor = max(0.85, step * 0.05)

        let bounds = fieldFrame.insetBy(dx: -pad, dy: -pad)
        var gx = gridOrigin.x
        if gx > bounds.minX { gx -= step * ceil((gx - bounds.minX) / step) }
        while gx <= bounds.maxX {
            var gy = gridOrigin.y
            if gy > bounds.minY { gy -= step * ceil((gy - bounds.minY) / step) }
            while gy <= bounds.maxY {
                let local = CGPoint(x: gx - fieldFrame.midX, y: gy - fieldFrame.midY)
                // Distance to the contour, positive outside — the front is parallel
                // to the card's real shape, not a circle around its center.
                let outside = -ShapeSDF.signedRoundRect(local, half: half, radius: radius)
                let band = exp(-pow(outside - crest, 2) / (2 * sigma * sigma))
                let weight = amp * band
                if weight > 0.03 {
                    let dotSize = sizeFloor + (sizePeak - sizeFloor) * min(1, weight)
                    let alpha = min(1, weight) * 0.9
                    if dotSize > 0.4 {
                        // Canvas is centered on field mid — convert screen → local canvas.
                        let p = CGPoint(
                            x: (fieldFrame.width + pad * 2) * 0.5 + local.x,
                            y: (fieldFrame.height + pad * 2) * 0.5 + local.y
                        )
                        let rect = CGRect(
                            x: p.x - dotSize / 2,
                            y: p.y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        ctx.fill(Path(ellipseIn: rect), with: .color(Theme.selectionNotch(scheme).opacity(alpha)))
                    }
                }
                gy += step
            }
            gx += step
        }
    }
}

/// Delete dissolve driven by the card’s real rounded-rect SDF (not an ellipse-to-center hack).
/// Grid matches canvas `DotGrid` pitch + phase so dots land on the same world lattice.
struct DeleteHalftoneWave: View {
    let fieldFrame: CGRect
    /// Screen-space corner radius of the deleted card’s clip shape.
    let cornerRadius: CGFloat
    let startDate: Date
    /// Same `24 * zoom` as `DotGrid`.
    var gridStep: CGFloat = 24
    /// Screen-space origin of the first DotGrid node (camera remainder phase).
    var gridOrigin: CGPoint = .zero
    var duration: TimeInterval = 0.64
    var onComplete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var didComplete = false

    private var pad: CGFloat {
        max(fieldFrame.width, fieldFrame.height) * 1.4 + gridStep * 4
    }

    var body: some View {
        if reduceMotion {
            Color.clear.frame(width: 1, height: 1).onAppear { finish() }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                let raw = context.date.timeIntervalSince(startDate) / duration
                let t = CGFloat(min(1, max(0, raw)))
                Canvas { ctx, _ in
                    draw(ctx: ctx, t: t)
                }
                .onChange(of: t) { _, value in
                    if value >= 1 { finish() }
                }
            }
            .frame(width: fieldFrame.width + pad * 2, height: fieldFrame.height + pad * 2)
            .position(x: fieldFrame.midX, y: fieldFrame.midY)
            .allowsHitTesting(false)
            .onAppear {
                if Date.now.timeIntervalSince(startDate) >= duration { finish() }
            }
        }
    }

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        onComplete?()
    }

    private func draw(ctx: GraphicsContext, t: CGFloat) {
        let step = max(10, gridStep * 0.58)
        let half = CGSize(width: fieldFrame.width * 0.5, height: fieldFrame.height * 0.5)
        let radius = min(cornerRadius, min(half.width, half.height))
        let maxInside = ShapeSDF.roundRectInradius(half: half, radius: radius)
        let fillEnd: CGFloat = 0.36
        let sizePeak = step * 1.02
        let sizeFloor = max(0.85, step * 0.05)
        let sigma = step * 0.55

        let fillT = min(1, t / fillEnd)
        let waveT = t <= fillEnd ? 0 : (t - fillEnd) / (1 - fillEnd)
        // SDF > 0 inside. Fill: threshold drops from deep interior → contour.
        // Wave: crest runs contour → outside (negative SDF).
        let thresh = maxInside * (1 - pow(fillT, 0.7))
        let crestSDF: CGFloat = t <= fillEnd
            ? thresh
            : (-waveT * (max(half.width, half.height) * 1.35 + step * 3))
        let amp: CGFloat = t <= fillEnd
            ? (0.72 + 0.28 * fillT)
            : ((1 - 0.58 * waveT) * (1 - pow(waveT, 2.15)))

        let bounds = fieldFrame.insetBy(dx: -pad, dy: -pad)
        var gx = gridOrigin.x
        if gx > bounds.minX { gx -= step * ceil((gx - bounds.minX) / step) }
        while gx <= bounds.maxX {
            var gy = gridOrigin.y
            if gy > bounds.minY { gy -= step * ceil((gy - bounds.minY) / step) }
            while gy <= bounds.maxY {
                let screen = CGPoint(x: gx, y: gy)
                let local = CGPoint(x: screen.x - fieldFrame.midX, y: screen.y - fieldFrame.midY)
                let sdf = ShapeSDF.signedRoundRect(local, half: half, radius: radius)
                let weight: CGFloat
                if t <= fillEnd {
                    // Seed → silhouette: show nodes deeper than the falling threshold.
                    let feather = step * 0.85
                    let inside = ShapeSDF.smoothstep(thresh - feather, thresh + feather * 0.35, sdf)
                    weight = amp * inside
                } else {
                    // Ring parallel to the real contour (not a circle around center).
                    let band = exp(-pow(sdf - crestSDF, 2) / (2 * sigma * sigma))
                    weight = amp * band
                }
                if weight > 0.04 {
                    let dotSize = sizeFloor + (sizePeak - sizeFloor) * min(1, weight)
                    let alpha = min(1, weight) * 0.88
                    if dotSize > 0.4 {
                        // Canvas is centered on field mid — convert screen → local canvas.
                        let p = CGPoint(
                            x: (fieldFrame.width + pad * 2) * 0.5 + local.x,
                            y: (fieldFrame.height + pad * 2) * 0.5 + local.y
                        )
                        let rect = CGRect(
                            x: p.x - dotSize / 2,
                            y: p.y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        ctx.fill(Path(ellipseIn: rect), with: .color(Theme.selectionNotch(scheme).opacity(alpha)))
                    }
                }
                gy += step
            }
            gx += step
        }
    }
}

/// Analytic SDFs for card clip shapes (positive = inside).
enum ShapeSDF {
    /// Inigo Quilez round-box, negated so >0 is inside the shape.
    static func signedRoundRect(_ p: CGPoint, half: CGSize, radius: CGFloat) -> CGFloat {
        let r = min(radius, min(half.width, half.height))
        let bx = half.width - r
        let by = half.height - r
        let qx = abs(p.x) - bx
        let qy = abs(p.y) - by
        let outside = hypot(max(qx, 0), max(qy, 0))
        let inside = min(max(qx, qy), 0)
        return -(outside + inside - r)
    }

    static func roundRectInradius(half: CGSize, radius: CGFloat) -> CGFloat {
        let r = min(radius, min(half.width, half.height))
        return min(half.width, half.height) - r * 0.15
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - edge0) / max(edge1 - edge0, 0.0001)))
        return t * t * (3 - 2 * t)
    }
}
import AppKit
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
            view.window?.makeFirstResponder(view)
            if let caret { Self.applyPendingCaret(caret, to: view) }
            if caret != nil { onConsumeCaret?() }
        }
        return view
    }

    func updateNSView(_ view: GrowingTextView, context: Context) {
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
            let fr = view.window?.firstResponder
            let steal = fr == nil || fr === view.window
            let caret = pendingCaret
            if steal, view.window?.firstResponder !== view {
                view.window?.makeFirstResponder(view)
                if let caret { Self.applyPendingCaret(caret, to: view) }
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
                    let prevHex = context.coordinator.lastInkHex.uppercased()
                    let full = NSRange(location: 0, length: storage.length)
                    storage.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                        guard let color = value as? NSColor, color.vasaHex.uppercased() == prevHex else { return }
                        storage.addAttribute(.foregroundColor, value: ink, range: range)
                    }
                    var typing = view.typingAttributes
                    if let typingColor = typing[.foregroundColor] as? NSColor, typingColor.vasaHex.uppercased() == prevHex {
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
            // Normalize colors to sRGB so preview + editor paint reliably.
            // Remap near-black body text to the theme ink (dark mode adaptation).
            mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                guard let color = value as? NSColor else {
                    mutable.addAttribute(.foregroundColor, value: ink, range: range)
                    return
                }
                let hex = color.vasaHex.uppercased()
                if hex == "#111318" || hex == "#000000" || hex == "#1D1D1F" || hex == "#111111" {
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
        if let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont {
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
        TextTypingStyle.restore(attrs, on: view)
    }
}

/// ☐ / ☑ list marks — clickable in preview and while editing.
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
    static func markFont(bodyFont: NSFont) -> NSFont {
        bodyFont
    }

    /// Re-applies the enlarged/bold checkbox font to every ☐/☑ in `range` of
    /// `text` (or the whole string when `range` is nil). Always derives the
    /// "body" size from the text just after the mark — never from the mark's
    /// own current font — so calling this repeatedly (on every edit) can't
    /// compound the enlargement.
    static func restyleMarks(in text: NSMutableAttributedString, range: NSRange? = nil) {
        let full = range ?? NSRange(location: 0, length: text.length)
        guard full.length > 0, NSMaxRange(full) <= text.length else { return }
        let ns = text.string as NSString
        for idx in full.location..<NSMaxRange(full) {
            guard isMark(ns.character(at: idx)) else { continue }
            let bodyProbe = min(idx + 2, text.length - 1)
            let bodyFont = (text.attribute(.font, at: max(0, bodyProbe), effectiveRange: nil) as? NSFont)
                ?? NSFont.systemFont(ofSize: 16)
            text.addAttribute(.font, value: markFont(bodyFont: bodyFont), range: NSRange(location: idx, length: 1))
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
            let font = (textView.textStorage?.attribute(.font, at: idx, effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: 16)
            let box = checkboxBox(for: glyphRect, font: font).insetBy(dx: -6, dy: -6)
            if box.contains(point) { return idx }
        }
        return nil
    }

    /// The square `drawCheckbox` paints, in the glyph's own coordinate space — shared with
    /// `checkboxUTF16Index` so the clickable area always matches what's actually drawn.
    static func checkboxBox(for glyphRect: NSRect, font: NSFont) -> NSRect {
        // Size from the font alone, never from the glyph's own measured rect: ☐ and ☑
        // can fall back to different system glyphs with different natural bounding
        // boxes, which made the box visibly grow the moment a mark was checked. Only
        // the box's *position* (its center) still follows the glyph's laid-out rect.
        let side = font.capHeight * 1.35
        return NSRect(x: glyphRect.midX - side / 2, y: glyphRect.midY - side / 2, width: side, height: side)
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
    nonisolated static func drawCheckbox(checked: Bool, in glyphRect: NSRect, font: NSFont) {
        let box = checkboxBox(for: glyphRect, font: font)
        let side = box.width
        guard side > 1 else { return }
        let radius = side * 0.26
        // Dynamic providers so the checkbox brightens with the effective appearance instead
        // of keeping its light-mode gray/blue when the app (or the system) switches to dark.
        let strokeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.5, alpha: 1)
                : NSColor(calibratedWhite: 0.62, alpha: 1)
        }
        let checkColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.58, green: 0.66, blue: 0.80, alpha: 1)
                : NSColor(calibratedRed: 0.35, green: 0.42, blue: 0.53, alpha: 1)
        }
        let path = NSBezierPath(roundedRect: box.insetBy(dx: side * 0.06, dy: side * 0.06), xRadius: radius, yRadius: radius)
        path.lineWidth = max(1.4, side * 0.1)
        strokeColor.setStroke()
        path.stroke()
        guard checked else { return }
        let check = NSBezierPath()
        check.lineWidth = max(1.6, side * 0.12)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        // NSTextView is flipped (y grows downward), so the "dip then rise"
        // shape of a checkmark needs the larger y first (visually lower).
        check.move(to: NSPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.50))
        check.line(to: NSPoint(x: box.minX + side * 0.42, y: box.minY + side * 0.70))
        check.line(to: NSPoint(x: box.minX + side * 0.78, y: box.minY + side * 0.30))
        checkColor.setStroke()
        check.stroke()
    }
}

/// Paints `TodoMarks.drawCheckbox` in place of the plain ☐/☑ glyph during
/// layout — display-only, never touches the text storage, so it's safe to
/// swap in on any NSTextView that already uses `TodoMarks` for hit-testing.
nonisolated final class TodoAwareLayoutManager: NSLayoutManager {
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
                    let font = (storage.attribute(.font, at: idx, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 16)
                    TodoMarks.drawCheckbox(checked: ch == TodoMarks.checked, in: rect, font: font)
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

final class GrowingTextView: NSTextView {
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let idx = TodoMarks.checkboxUTF16Index(in: self, at: point),
           TodoMarks.toggle(in: self, at: idx)
        {
            didChangeText()
            return
        }
        super.mouseDown(with: event)
    }

    /// Keep foreground/font across Enter so list/todo lines don't flash default ink until ESC.
    /// Continues `• ` / `N. ` / `☐ ` on the new line; blank list item exits the list.
    override func insertNewline(_ sender: Any?) {
        let keep = TextTypingStyle.capture(from: self)
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
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

/// Radial Gaussian wavefront on a fixed halftone grid.
/// Dots never move — only radius/alpha follow `A(t) · exp(-(r - R(t))² / 2σ²)`.
/// Tuned to the 5-frame ref: big crest on the field → ring walks out & shrinks.
struct TextGaussianWave: View {
    /// Field geometry snapshot in screen space (at creation).
    let fieldFrame: CGRect
    let startDate: Date
    var duration: TimeInterval = 0.58
    /// Canvas grid pitch in screen space (`24 * zoom`).
    var gridStep: CGFloat = 24
    var onComplete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var didComplete = false

    private var blockCenter: CGPoint {
        CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
    }

    /// Frame 5 crest sits further out; draw buffer a bit past that.
    private var maxRadius: CGFloat {
        max(fieldFrame.width, fieldFrame.height) * 6.2
    }

    var body: some View {
        if reduceMotion {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { finish() }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                let raw = context.date.timeIntervalSince(startDate) / duration
                let t = CGFloat(min(1, max(0, raw)))
                Canvas { ctx, size in
                    let local = CGPoint(x: size.width / 2, y: size.height / 2)
                    draw(ctx: ctx, center: local, maxRadius: maxRadius, t: t)
                }
                .onChange(of: t) { _, value in
                    if value >= 1 { finish() }
                }
            }
            .frame(width: fieldFrame.width + maxRadius * 2, height: fieldFrame.height + maxRadius * 2)
            .position(blockCenter)
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

    private func draw(ctx: GraphicsContext, center: CGPoint, maxRadius: CGFloat, t: CGFloat) {
        // Denser than the canvas DotGrid — refs pack balls almost touching at the crest.
        let step = max(9, gridStep * 0.58)
        let field = max(fieldFrame.width, fieldFrame.height)
        let fieldR = field * 0.55
        // Frame 1–2: crest sits on the field (balls crawl onto the box).
        // Frame 5: crest ~3.5–4× field out.
        let rStart = fieldR * 0.55
        let rEnd = field * 4.8
        let sigma = step * 1.7
        // Linger near the field, then the ring walks out (matches frames 1→5).
        let ease = pow(t, 1.35)
        let crestR = rStart + (rEnd - rStart) * ease
        // Frame 1 huge & packed; frame 5 clearly smaller + fading.
        let amp = (1 - 0.62 * ease) * (1 - pow(t, 2.4))
        // Peak ≈ step → neighbors almost kiss (original’s tight start).
        let sizePeak: CGFloat = step * 1.02
        let sizeFloor: CGFloat = max(0.85, step * 0.05)

        var x = -maxRadius
        while x <= maxRadius {
            var y = -maxRadius
            while y <= maxRadius {
                let r = hypot(x, y)
                if r <= maxRadius {
                    let gauss = exp(-pow(r - crestR, 2) / (2 * sigma * sigma))
                    let weight = gauss * amp
                    let dotSize = sizeFloor + (sizePeak - sizeFloor) * weight
                    let alpha = weight * 0.88
                    if weight > 0.03, dotSize > 0.4 {
                        let p = CGPoint(x: center.x + x, y: center.y + y)
                        let rect = CGRect(
                            x: p.x - dotSize / 2,
                            y: p.y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        ctx.fill(Path(ellipseIn: rect), with: .color(Theme.selectionNotch(scheme).opacity(alpha)))
                    }
                }
                y += step
            }
            x += step
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
private enum ShapeSDF {
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
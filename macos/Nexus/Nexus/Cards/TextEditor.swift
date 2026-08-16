import AppKit
import SwiftUI

struct CanvasTextEditor: NSViewRepresentable {
    let html: String?
    let plain: String?
    let fontSize: CGFloat
    let ink: NSColor
    let editing: Bool
    var onChange: (String, String, CGSize) -> Void
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onBind: ((GrowingTextView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onBeginEditing: onBeginEditing, onEndEditing: onEndEditing, onBind: onBind)
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
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: GrowingTextView.maxContentWidth, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .zero
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
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.desiredFontSize = fontSize
        context.coordinator.onBind = onBind
        if editing { onBind?(view) }
        view.onSizeChange = { [weak coord = context.coordinator] size in
            coord?.reportSize(size)
        }
        view.textStorage?.setAttributedString(Self.attributed(html: html, plain: plain, size: fontSize, ink: ink))
        context.coordinator.lastHTML = html ?? plain ?? ""
        if editing {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        return view
    }

    func updateNSView(_ view: GrowingTextView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.onBind = onBind
        context.coordinator.view = view
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isEditable = editing
        view.isSelectable = true
        if editing {
            onBind?(view)
            let fr = view.window?.firstResponder
            let steal = fr == nil || fr === view.window
            if steal, view.window?.firstResponder !== view {
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            }
        }
        if abs(context.coordinator.desiredFontSize - fontSize) > 0.5 {
            context.coordinator.desiredFontSize = fontSize
            Self.applyFontSize(fontSize, to: view)
            view.invalidateIntrinsicContentSize()
            context.coordinator.reportSize(view.fittingContentSize)
        }
        let incoming = html ?? plain ?? ""
        let current = context.coordinator.lastHTML
        if incoming != current, view.window?.firstResponder !== view {
            view.textStorage?.setAttributedString(Self.attributed(html: html, plain: plain, size: fontSize, ink: ink))
            context.coordinator.lastHTML = incoming
            view.invalidateIntrinsicContentSize()
        }
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
            .foregroundColor: ink
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
            return mutable
        }
        return NSAttributedString(string: plain ?? "", attributes: base)
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

    /// NSAttributedString HTML export wraps a full document — keep only the body fragment.
    static func htmlFragment(_ document: String) -> String {
        let ns = document as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let regex = try? NSRegularExpression(pattern: "(?is)<body[^>]*>(.*?)</body>"),
           let match = regex.firstMatch(in: document, options: [], range: full),
           match.numberOfRanges > 1 {
            return ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
        var onBind: ((GrowingTextView?) -> Void)?
        var view: GrowingTextView?
        var lastHTML = ""
        var desiredFontSize: CGFloat = 16
        private var lastSize: CGSize = .zero

        init(
            onChange: @escaping (String, String, CGSize) -> Void,
            onBeginEditing: (() -> Void)?,
            onEndEditing: (() -> Void)?,
            onBind: ((GrowingTextView?) -> Void)?
        ) {
            self.onChange = onChange
            self.onBeginEditing = onBeginEditing
            self.onEndEditing = onEndEditing
            self.onBind = onBind
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let view { onBind?(view) }
            onBeginEditing?()
        }

        func textDidEndEditing(_ notification: Notification) {
            persist()
            // Keep the editing session + text view ref so the format bar
            // can be clicked without dismissing (buttons steal first responder).
        }

        func textDidChange(_ notification: Notification) {
            persist()
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
            guard abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 else { return }
            lastSize = size
            persist(sizeOverride: size)
        }

        private func persist(sizeOverride: CGSize? = nil) {
            guard let view, let storage = view.textStorage else { return }
            Self.linkifyPlainURLs(in: storage)
            let html = CanvasTextEditor.html(from: storage)
            lastHTML = html
            let size = sizeOverride ?? view.fittingContentSize
            onChange(html, view.string, size)
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

final class GrowingTextView: NSTextView {
    static let maxContentWidth: CGFloat = 640
    var onSizeChange: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        focusRingType = .none
        drawsBackground = false
        backgroundColor = .clear
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        drawsBackground = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
        drawsBackground = false
        backgroundColor = .clear
    }

    var fittingContentSize: CGSize {
        guard let container = textContainer, let layout = layoutManager else {
            return NSSize(width: 24, height: 22)
        }
        let previous = container.containerSize
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: Self.maxContentWidth, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let hasText = (string as NSString).length > 0
        let width = max(hasText ? 24 : 96, ceil(used.width + 2))
        let height = max(hasText ? 22 : 32, ceil(used.height + textContainerInset.height * 2))
        container.containerSize = NSSize(width: max(previous.width, width), height: previous.height)
        return NSSize(width: width, height: height)
    }

    override var intrinsicContentSize: NSSize { fittingContentSize }

    override func drawBackground(in rect: NSRect) {
        // Plain canvas text — never fill.
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        onSizeChange?(fittingContentSize)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(
            width: max(Self.maxContentWidth, newSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
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
        CanvasTextEditor.Coordinator.linkifyPlainURLs(in: storage)
        if shouldChangeText(in: selected, replacementString: storage.string) {
            textStorage?.replaceCharacters(in: selected, with: storage)
            didChangeText()
        }
    }
}

struct TextGaussianWave: View {
    let token: Int
    @State private var progress: CGFloat = 0
    @State private var opacity: Double = 0

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) * 0.48
            let rings = 7
            let perRing = 18
            for ring in 1...rings {
                let base = CGFloat(ring) / CGFloat(rings)
                let r = maxR * base * (0.55 + 0.45 * progress)
                let falloff = exp(-pow((base - 0.15) / 0.55, 2))
                let dot = max(1.2, 5.5 * falloff * (1.15 - progress * 0.55))
                let alpha = falloff * (1 - progress) * 0.9
                for i in 0..<perRing {
                    let jitter = sin(CGFloat(ring * 17 + i * 13)) * 0.08
                    let angle = (CGFloat(i) / CGFloat(perRing)) * .pi * 2 + jitter + CGFloat(ring) * 0.12
                    let p = CGPoint(
                        x: center.x + cos(angle) * r * (1 + jitter * 0.4),
                        y: center.y + sin(angle) * r * (1 + jitter * 0.4)
                    )
                    let rect = CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(Theme.ink.opacity(alpha)))
                }
            }
        }
        .frame(width: 280, height: 280)
        .opacity(opacity)
        .allowsHitTesting(false)
        .onAppear { run() }
        .onChange(of: token) { _, _ in run() }
    }

    private func run() {
        progress = 0
        opacity = 1
        withAnimation(.easeOut(duration: 0.85)) {
            progress = 1
            opacity = 0
        }
    }
}

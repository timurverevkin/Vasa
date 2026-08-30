import AppKit
import SwiftUI

@MainActor
final class NoteEditorBridge {
    weak var textView: NSTextView?
    var onChange: ((String, String) -> Void)?

    var plain: String { textView?.string ?? "" }
    var words: Int { Format.wordCount(plain) }
    var characters: Int { plain.count }

    func heading(_ size: CGFloat) {
        apply([
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ], paragraph: true)
    }

    func regular() {
        apply([.font: NSFont.systemFont(ofSize: 16, weight: .regular)], paragraph: true)
    }

    func toggleBold() { toggleTrait(.bold) }
    func toggleItalic() { toggleTrait(.italic) }

    func fontSize(_ size: CGFloat) {
        let current = (typingFont() ?? NSFont.systemFont(ofSize: 16))
        apply([.font: NSFont.systemFont(ofSize: size, weight: current.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .regular)])
    }

    func color(_ hex: String) {
        apply([.foregroundColor: NSColor.vasa(hex: hex)])
    }

    /// Reset text color to default without clearing fonts/links.
    func clearForeground() {
        apply([.foregroundColor: NSColor.labelColor])
    }

    func currentForegroundHex() -> String? {
        guard let color = textView?.typingAttributes[.foregroundColor] as? NSColor else { return nil }
        let hex = color.vasaHex
        // Treat near-black / label as "default" so the reset swatch can show selected.
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        if normalized == "1D1D1F" || normalized == "000000" || normalized == "FFFFFF" {
            return nil
        }
        return hex
    }

    func setLink(_ raw: String) {
        var href = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if href.isEmpty { return }
        if !href.contains("://") { href = "https://\(href)" }
        apply([.link: href, .foregroundColor: NSColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue])
    }

    func bullet() { applyList(.bullet) }
    func numbered() { applyList(.numbered) }
    func todo() { applyList(.todo) }

    func clear() {
        guard let view = textView else { return }
        let range = targetRange(in: view, paragraph: false)
        view.textStorage?.removeAttribute(.font, range: range)
        view.textStorage?.removeAttribute(.foregroundColor, range: range)
        view.textStorage?.removeAttribute(.underlineStyle, range: range)
        view.textStorage?.removeAttribute(.link, range: range)
        view.textStorage?.addAttributes([
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ], range: range)
        view.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        persist()
    }

    func currentSize() -> Int {
        Int((typingFont() ?? NSFont.systemFont(ofSize: 16)).pointSize.rounded())
    }

    private func typingFont() -> NSFont? {
        textView?.typingAttributes[.font] as? NSFont
    }

    private func targetRange(in view: NSTextView, paragraph: Bool) -> NSRange {
        let selected = view.selectedRange()
        if selected.length > 0 { return selected }
        let ns = view.string as NSString
        if ns.length == 0 { return NSRange(location: 0, length: 0) }
        let loc = min(selected.location, ns.length)
        if paragraph {
            return ns.paragraphRange(for: NSRange(location: loc, length: 0))
        }
        return NSRange(location: 0, length: ns.length)
    }

    private func apply(_ attrs: [NSAttributedString.Key: Any], paragraph: Bool = false) {
        guard let view = textView else { return }
        let range = targetRange(in: view, paragraph: paragraph)
        if range.length > 0 {
            view.textStorage?.addAttributes(attrs, range: range)
        }
        var next = view.typingAttributes
        attrs.forEach { next[$0.key] = $0.value }
        view.typingAttributes = next
        persist()
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let view = textView else { return }
        let font = (view.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 16)
        var traits = font.fontDescriptor.symbolicTraits
        if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        let next = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        apply([.font: next])
    }

    private func applyList(_ kind: TextListMarkup.Kind) {
        guard let view = textView, let storage = view.textStorage else { return }
        let ns = view.string as NSString
        let selected = view.selectedRange()
        let loc = min(selected.location, ns.length)
        let para: NSRange = {
            if selected.length > 0 {
                return ns.paragraphRange(for: selected)
            }
            return TextListMarkup.contiguousListParagraphRange(in: ns, location: loc)
        }()
        let block = ns.substring(with: para)
        let next = TextListMarkup.apply(kind, to: block)
        storage.beginEditing()
        storage.replaceCharacters(in: para, with: next)
        storage.endEditing()
        let caret = min(para.location + (next as NSString).length, storage.length)
        view.setSelectedRange(NSRange(location: caret, length: 0))
        persist()
    }

    func persist() {
        guard let view = textView, let storage = view.textStorage else { return }
        onChange?(Self.html(from: storage), view.string)
    }

    static func html(from attributed: NSAttributedString) -> String {
        guard let data = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ) else { return attributed.string }
        return String(data: data, encoding: .utf8) ?? attributed.string
    }

    static func attributed(html: String?, plain: String?) -> NSAttributedString {
        if let html, html.contains("<"), let data = html.data(using: .utf8),
           let parsed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           ), parsed.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: parsed)
            // Cocoa's HTML writer resolves `labelColor` to a literal black/white hex at
            // persist time (see `html(from:)` / `persist()`). Reading that literal back
            // verbatim leaves default-colored text invisible whenever the note is reopened
            // in the opposite appearance. Remap it back to the dynamic color so it always
            // tracks the current scheme; a genuinely user-picked tint (any other hex) is
            // left untouched.
            let full = NSRange(location: 0, length: mutable.length)
            mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let hex = color.vasaHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
                if hex == "000000" || hex == "FFFFFF" || hex == "1D1D1F" || hex == "111318" || hex == "111111" {
                    mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }
            TodoMarks.restyleMarks(in: mutable)
            return mutable
        }
        let mutable = NSMutableAttributedString(
            string: plain ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        TodoMarks.restyleMarks(in: mutable)
        return mutable
    }
}

struct NoteRichText: NSViewRepresentable {
    let html: String?
    let plain: String?
    let bridge: NoteEditorBridge
    var onChange: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = NoteChecklistTextView()
        view.textContainer?.replaceLayoutManager(TodoAwareLayoutManager())
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isRichText = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.isEditable = true
        view.isSelectable = true
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.font = NSFont.systemFont(ofSize: 16)
        view.textColor = NSColor.labelColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.view = view
        bridge.textView = view
        bridge.onChange = onChange
        view.textStorage?.setAttributedString(NoteEditorBridge.attributed(html: html, plain: plain))
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.bridge = bridge
        context.coordinator.onChange = onChange
        bridge.textView = context.coordinator.view
        bridge.onChange = onChange
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var bridge: NoteEditorBridge
        var onChange: (String, String) -> Void
        var view: NSTextView?

        init(bridge: NoteEditorBridge, onChange: @escaping (String, String) -> Void) {
            self.bridge = bridge
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            bridge.persist()
        }
    }
}

/// Note editor text view — click ☐/☑ to toggle without selecting the glyph.
private final class NoteChecklistTextView: NSTextView {
    /// Same guard as `GrowingTextView`: never let the mark's inflated cell font become
    /// the font of what the user types next to it.
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
            let newTraits = current.fontDescriptor.symbolicTraits.contains(trait)
                ? current.fontDescriptor.symbolicTraits.subtracting(trait)
                : current.fontDescriptor.symbolicTraits.union(trait)
            let descriptors = current.fontDescriptor.withSymbolicTraits(newTraits)
            typing[.font] = NSFont(descriptor: descriptors, size: current.pointSize) ?? current
            typingAttributes = typing
        } else {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: target) { value, subrange, _ in
                let current = (value as? NSFont) ?? NSFont.systemFont(ofSize: size)
                let newTraits = current.fontDescriptor.symbolicTraits.contains(trait)
                    ? current.fontDescriptor.symbolicTraits.subtracting(trait)
                    : current.fontDescriptor.symbolicTraits.union(trait)
                let descriptors = current.fontDescriptor.withSymbolicTraits(newTraits)
                storage.addAttribute(.font, value: NSFont(descriptor: descriptors, size: current.pointSize) ?? current, range: subrange)
            }
            storage.endEditing()
            setSelectedRange(target)
        }
        didChangeText()
    }
}

enum NoteDrop: Equatable {
    case style, link, color, count
}

enum NoteCountMode: String {
    case words, characters, off
}

struct NoteEditorLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NoteHitThroughHost(model: app, scheme: scheme)
    }
}

private struct NoteEditorBody: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            NotePanel()
                .frame(width: Format.notePanelWidth)
                .padding(.vertical, Format.notePanelVertical)
                .padding(.trailing, Format.notePanelTrailing)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
    }
}

/// Dashed link from the open note’s vertical center to the editor panel’s vertical center.
/// Drawn in canvas screen space (sibling of `WorldLayer`) so it shares the same camera math
/// and sits under the note editor overlay in `RootView`.
struct NoteConnectorOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            if let id = app.noteOpenID, let card = app.card(id), card.kind == .note {
                NoteConnector(card: card, canvasSize: geo.size)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct NoteConnector: View {
    @Environment(AppModel.self) private var app
    let card: Card
    let canvasSize: CGSize

    /// Matches `CardSelection` outset for notes (scaled with the card inside WorldLayer).
    private let selectionOutset: CGFloat = 3
    /// Gap past the selection stroke before the grey dot.
    private let edgeToDot: CGFloat = 8
    /// Gap after the dot before the dashed segment begins.
    private let dotToLine: CGFloat = 6
    private let dotRadius: CGFloat = 3.5
    /// Leave a breath before the panel edge.
    private let panelGap: CGFloat = 2

    var body: some View {
        let cam = app.activeLesson?.camera ?? Camera(x: 0, y: 0, zoom: 1)
        let zoom = max(cam.zoom, 0.01)
        // WorldLayer: scale(topLeading) then offset — screen = world * zoom + camera.
        let noteRight = (card.x + card.previewWidth) * zoom + cam.x + selectionOutset * zoom
        let noteMidY = (card.y + card.previewHeight / 2) * zoom + cam.y
        let start = CGPoint(x: noteRight, y: noteMidY)

        let panelLeft = canvasSize.width - Format.notePanelTrailing - Format.notePanelWidth
        let panelTop = Format.notePanelVertical
        let panelBottom = canvasSize.height - Format.notePanelVertical
        let panelMidY = (panelTop + panelBottom) / 2
        let end = CGPoint(x: panelLeft - panelGap, y: panelMidY)

        let ink = Theme.muted.opacity(0.7)
        let visible =
            start.x < panelLeft - 8
            && start.x > -120
            && start.y > -80
            && start.y < canvasSize.height + 80

        // Read card + camera fields so @Observable invalidates every pan/zoom/move.
        let _ = (cam.x, cam.y, cam.zoom, card.x, card.y, card.width, card.height)

        return Canvas { context, _ in
            guard visible else { return }

            let dx = end.x - start.x
            let dy = end.y - start.y
            let len = hypot(dx, dy)
            guard len > 1 else { return }
            let ux = dx / len
            let uy = dy / len

            let dotCenter = CGPoint(
                x: start.x + ux * edgeToDot,
                y: start.y + uy * edgeToDot
            )
            let lineStart = CGPoint(
                x: dotCenter.x + ux * (dotRadius + dotToLine),
                y: dotCenter.y + uy * (dotRadius + dotToLine)
            )
            // Stop short of the panel so the stroke stays under the chrome, not on it.
            let lineEnd = CGPoint(
                x: end.x - ux * (dotRadius + 2),
                y: end.y - uy * (dotRadius + 2)
            )

            var path = Path()
            path.move(to: lineStart)
            path.addLine(to: lineEnd)
            context.stroke(
                path,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [5, 4])
            )

            let startDot = Path(ellipseIn: CGRect(
                x: dotCenter.x - dotRadius,
                y: dotCenter.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            context.fill(startDot, with: .color(ink))

            let endDot = Path(ellipseIn: CGRect(
                x: end.x - dotRadius,
                y: end.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            context.fill(endDot, with: .color(ink))
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }
}

private struct NoteHitThroughHost: NSViewRepresentable {
    var model: AppModel
    var scheme: ColorScheme

    func makeNSView(context: Context) -> NoteHitThroughView {
        let view = NoteHitThroughView()
        let hosting = NSHostingView(
            rootView: AnyView(
                NoteEditorBody()
                    .environment(model)
                    .environment(\.colorScheme, scheme)
            )
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        context.coordinator.hosting = hosting
        context.coordinator.scheme = scheme
        return view
    }

    func updateNSView(_ view: NoteHitThroughView, context: Context) {
        if context.coordinator.scheme != scheme {
            context.coordinator.scheme = scheme
            context.coordinator.hosting?.rootView = AnyView(
                NoteEditorBody()
                    .environment(model)
                    .environment(\.colorScheme, scheme)
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<AnyView>?
        var scheme: ColorScheme = .light
    }
}

final class NoteHitThroughView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if point.x < bounds.width - Format.notePanelOuterWidth { return nil }
        if point.y < Format.notePanelVertical { return nil }
        if point.y > bounds.height - Format.notePanelVertical { return nil }
        return super.hitTest(point)
    }
}

struct NotePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var drop: NoteDrop?
    @State private var countMode: NoteCountMode = .words
    @State private var link = "https://"
    @State private var bridge = NoteEditorBridge()
    @State private var tick = 0

    var body: some View {
        if let id = app.noteOpenID, let card = app.card(id), card.kind == .note {
            VStack(alignment: .leading, spacing: 0) {
                toolbar(id, card)
                NoteRichText(
                    html: card.html,
                    plain: card.body,
                    bridge: bridge,
                    onChange: { html, plain in
                        app.updateCard(id) {
                            $0.html = html
                            $0.body = plain
                        }
                        tick += 1
                    }
                )
                .id(id)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.cardSurface(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                if drop == .style { styleMenu.padding(.leading, 12).padding(.top, 44) }
                if drop == .link { linkMenu.padding(.leading, 42).padding(.top, 44) }
                if drop == .color {
                    let _ = tick
                    ColorPalette(current: bridge.currentForegroundHex(), onReset: {
                        bridge.clearForeground()
                        drop = nil
                    }) { hex in
                        bridge.color(hex)
                        drop = nil
                    }
                    .padding(8)
                    .frame(width: 220)
                    .chromePill(12)
                    .padding(.leading, 72)
                    .padding(.top, 44)
                }
            }
            .overlay(alignment: .topTrailing) {
                if drop == .count { countMenu.padding(.trailing, 44).padding(.top, 44) }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 28, x: -8, y: 4)
            .zIndex(40)
        }
    }

    @ViewBuilder
    private func toolbar(_ id: String, _ card: Card) -> some View {
        HStack(spacing: 2) {
            dropButton(icon: .textFormat, .style)
            dropButton(icon: .goToLink, .link)
            dropButton(icon: .editColor, .color)
            HoverIconButton(icon: .bulletList, size: 28) { bridge.bullet() }.help("Bullet list")
            HoverIconButton(icon: .numberedList, size: 28) { bridge.numbered() }.help("Numbered list")
            HoverIconButton(icon: .todoList, size: 28) { bridge.todo() }.help("To-do list")
            HoverIconButton(icon: .removeFormatting, size: 28) { bridge.clear() }.help("Clear formatting")
            Button {
                // Persist live editor content before Ask reads the card.
                if let view = bridge.textView, let storage = view.textStorage {
                    app.updateCard(id, persist: false) {
                        $0.html = NoteEditorBridge.html(from: storage)
                        $0.body = view.string
                    }
                }
                app.askAbout(id)
            } label: {
                AppIconView(icon: .askAI, size: 14)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Ask AI")
            Spacer(minLength: 4)
            if countMode != .off {
                dropButton(nil, .count, label: countLabel(card), circular: true)
            } else {
                dropButton(icon: .counter, .count)
            }
            Button { app.closeNoteEditor() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .zIndex(20)
    }

    private func dropButton(
        _ system: String? = nil,
        _ id: NoteDrop,
        icon: AppIcon? = nil,
        label: String? = nil,
        circular: Bool = false
    ) -> some View {
        let open = drop == id
        return Button {
            drop = open ? nil : id
        } label: {
            Group {
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                } else if let icon {
                    AppIconView(icon: icon, size: 14)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundStyle(open ? Color.white : Theme.ink)
            .frame(minWidth: 28)
            .frame(height: 28)
            .padding(.horizontal, label == nil ? 0 : 4)
            .background(open ? Theme.ink : Color.clear, in: RoundedRectangle(cornerRadius: circular ? 14 : 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dropButton(icon: AppIcon, _ id: NoteDrop, circular: Bool = false) -> some View {
        dropButton(nil, id, icon: icon, circular: circular)
    }

    private var styleMenu: some View {
        let size = bridge.currentSize()
        return VStack(alignment: .leading, spacing: 0) {
            StyleMenuRow(leading: "H1", title: "Heading 1", selected: size >= 30) {
                bridge.heading(32); drop = nil
            }
            StyleMenuRow(leading: "H2", title: "Heading 2", selected: size >= 22 && size < 30) {
                bridge.heading(24); drop = nil
            }
            StyleMenuRow(leading: "H3", title: "Heading 3", selected: size >= 18 && size < 22) {
                bridge.heading(18); drop = nil
            }
            StyleMenuRow(leading: "Aa", title: "Regular", selected: size == 16) {
                bridge.regular(); drop = nil
            }
            StyleMenuRow(leading: "B", title: "Bold") { bridge.toggleBold(); drop = nil }
            StyleMenuRow(leading: "I", title: "Italic", italicLeading: true) {
                bridge.toggleItalic(); drop = nil
            }
        }
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .chromePill(12)
    }

    private var linkMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("www.example.com", text: $link)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline(scheme)))
            HStack {
                Button("+ Add link") {
                    bridge.setLink(link)
                    drop = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { drop = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(10)
        .frame(width: 240)
        .chromePill(12)
    }

    private var countMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            StyleMenuRow(title: "Character count", selected: countMode == .characters) { countMode = .characters; drop = nil }
            StyleMenuRow(title: "Word count", selected: countMode == .words) { countMode = .words; drop = nil }
            StyleMenuRow(title: "Turn off", selected: countMode == .off) { countMode = .off; drop = nil }
        }
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .chromePill(12)
    }

    private func countLabel(_ card: Card) -> String {
        let text = card.body ?? ""
        switch countMode {
        case .characters: return "\(text.count)"
        case .words: return "\(Format.wordCount(text))"
        case .off: return ""
        }
    }
}

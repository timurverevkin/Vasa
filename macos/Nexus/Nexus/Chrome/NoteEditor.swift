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
        apply([.foregroundColor: NSColor(Theme.color(hex))])
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

    private enum ListKind { case bullet, numbered, todo }

    private func applyList(_ kind: ListKind) {
        guard let view = textView else { return }
        let ns = view.string as NSString
        let selected = view.selectedRange()
        let loc = min(selected.location, ns.length)
        let para = ns.paragraphRange(for: selected.length > 0 ? selected : NSRange(location: loc, length: 0))
        let block = ns.substring(with: para)
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stripped = lines.map(stripListMark)
        let allOn = !lines.isEmpty && lines.allSatisfy { lineHasMark($0, kind) }
        let next: String
        if allOn {
            next = stripped.joined(separator: "\n")
        } else {
            next = stripped.enumerated().map { index, line in
                switch kind {
                case .bullet: return "• " + line
                case .todo: return "☐ " + line
                case .numbered: return "\(index + 1). " + line
                }
            }.joined(separator: "\n")
        }
        view.textStorage?.replaceCharacters(in: para, with: next)
        persist()
    }

    private func stripListMark(_ line: String) -> String {
        if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("☐ ") || line.hasPrefix("☑ ") { return String(line.dropFirst(2)) }
        if let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return line
    }

    private func lineHasMark(_ line: String, _ kind: ListKind) -> Bool {
        switch kind {
        case .bullet: return line.hasPrefix("• ")
        case .todo: return line.hasPrefix("☐ ") || line.hasPrefix("☑ ")
        case .numbered: return line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
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
            return parsed
        }
        return NSAttributedString(
            string: plain ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
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
        let view = NSTextView()
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

enum NoteDrop: Equatable {
    case style, link, color, size, count
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
            ZStack(alignment: .topLeading) {
                if let id = app.noteOpenID, let card = app.card(id), card.kind == .note {
                    NoteConnector(card: card, canvasSize: geo.size)
                }
                NotePanel()
                    .frame(width: Format.notePanelWidth)
                    .padding(.vertical, Format.notePanelVertical)
                    .padding(.trailing, Format.notePanelTrailing)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
            }
        }
    }
}

private struct NoteConnector: View {
    @Environment(AppModel.self) private var app
    let card: Card
    let canvasSize: CGSize

    var body: some View {
        let cam = app.activeLesson?.camera ?? Camera(x: 0, y: 0, zoom: 1)
        let zoom = max(cam.zoom, 0.01)
        let start = CGPoint(
            x: (card.x + card.previewWidth / 2) * zoom + cam.x,
            y: (card.y + card.previewHeight / 2) * zoom + cam.y
        )
        let panelLeft = canvasSize.width - Format.notePanelTrailing - Format.notePanelWidth
        let panelTop = Format.notePanelVertical
        let panelHeight = max(1, canvasSize.height - Format.notePanelVertical * 2)
        let end = CGPoint(
            x: panelLeft + Format.notePanelWidth / 2,
            y: panelTop + panelHeight / 2
        )
        return Canvas { context, _ in
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(Theme.muted.opacity(0.62)),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
        }
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                if drop == .style { styleMenu.padding(.leading, 12).padding(.top, 44) }
                if drop == .link { linkMenu.padding(.leading, 42).padding(.top, 44) }
                if drop == .color {
                    ColorPalette(current: nil) { hex in
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
                if drop == .size { sizeMenu.padding(.trailing, 84).padding(.top, 44) }
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
            dropButton("textformat", .style)
            dropButton("link", .link)
            dropButton("circle.lefthalf.filled", .color)
            HoverIconButton(system: "list.bullet", size: 28) { bridge.bullet() }.help("Bullet list")
            HoverIconButton(system: "list.number", size: 28) { bridge.numbered() }.help("Numbered list")
            HoverIconButton(system: "checklist", size: 28) { bridge.todo() }.help("To-do list")
            HoverIconButton(system: "eraser", size: 28) { bridge.clear() }.help("Clear formatting")
            Button { app.askAbout(id) } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Ask AI")
            dropButton(nil, .size, label: "\(bridge.currentSize())")
            if countMode != .off {
                dropButton(nil, .count, label: countLabel(card), circular: true)
            } else {
                dropButton("character.cursor.ibeam", .count)
            }
            Spacer(minLength: 4)
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
        _ system: String?,
        _ id: NoteDrop,
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

    private var styleMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            StyleMenuRow(title: "H1  Heading 1") { bridge.heading(28); drop = nil }
            StyleMenuRow(title: "H2  Heading 2") { bridge.heading(22); drop = nil }
            StyleMenuRow(title: "H3  Heading 3") { bridge.heading(18); drop = nil }
            StyleMenuRow(title: "Aa  Regular", selected: true) { bridge.regular(); drop = nil }
            StyleMenuRow(title: "B   Bold") { bridge.toggleBold(); drop = nil }
            StyleMenuRow(title: "I   Italic") { bridge.toggleItalic(); drop = nil }
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
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
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

    private var sizeMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([12, 14, 16, 18, 22, 28, 36], id: \.self) { n in
                StyleMenuRow(title: "\(n)", selected: bridge.currentSize() == n) {
                    bridge.fontSize(CGFloat(n))
                    drop = nil
                }
            }
        }
        .padding(8)
        .frame(width: 88, alignment: .leading)
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

import AppKit
import SwiftUI

struct TextFormatBar: View {
    @Environment(AppModel.self) private var app
    let card: Card
    @State private var panel = Panel.lists
    @State private var sizeDraft = ""

    private enum Panel { case lists, color, size }

    private let sizes: [Int] = [12, 14, 16, 18, 22, 24, 28, 36]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                HoverIconButton(system: "bold", size: 28) { toggleBold() }
                    .help("Bold")
                HoverIconButton(system: "link", size: 28) { addLink() }
                    .help("Link")
                HoverIconButton(system: "text.alignleft", size: 28, active: panel == .lists) {
                    panel = .lists
                }
                .help("Lists")
                HoverIconButton(system: "circle.lefthalf.filled", size: 28, active: panel == .color) {
                    panel = panel == .color ? .lists : .color
                }
                .help("Color")
                sizeControl
                    .help("Font size")
                HoverIconButton(system: "trash", size: 28) {
                    app.selectedIDs = [card.id]
                    app.editingID = nil
                    app.activeCanvasTextView = nil
                    app.deleteSelected()
                }
                .help("Delete")
            }
            if panel == .lists {
                VStack(alignment: .leading, spacing: 0) {
                    MenuRow(system: "list.bullet", title: "Bullet list") { prefix("• ") }
                    MenuRow(system: "list.number", title: "Numbered list") { prefix("1. ") }
                    MenuRow(system: "checkmark.square", title: "To-do list") { prefix("☐ ") }
                }
            }
            if panel == .color {
                ColorPalette(current: currentTextColor) { hex in
                    applyColor(hex)
                }
            }
            if panel == .size {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sizes, id: \.self) { size in
                        let selected = Int(card.fontSize ?? 16) == size
                        Button {
                            applySize(CGFloat(size))
                            panel = .lists
                        } label: {
                            Text("\(size)")
                                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(
                                    selected ? Theme.hover : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 88, alignment: .leading)
            }
        }
        .padding(6)
        .frame(minWidth: 240, alignment: .leading)
        .chromePill(12)
        .contentShape(Rectangle())
        // Keep editing alive while interacting with the bar.
        .onHover { inside in
            if inside { app.editingID = card.id }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if app.editingID != card.id {
                        app.editingID = card.id
                    }
                }
        )
        .onAppear {
            sizeDraft = "\(Int(card.fontSize ?? 16))"
            if let view = textView {
                app.activeCanvasTextView = view
            }
        }
        .onChange(of: card.fontSize) { _, value in
            sizeDraft = "\(Int(value ?? 16))"
        }
    }

    private var sizeControl: some View {
        HStack(spacing: 0) {
            TextField("", text: $sizeDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 28, height: 28)
                .onSubmit { commitSizeDraft() }
            Button {
                panel = panel == .size ? .lists : .size
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .background(
            panel == .size ? Theme.ink.opacity(0.08) : Theme.hover,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(panel == .size ? Theme.ink.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }

    private var currentTextColor: String? {
        guard let view = textView,
              let color = view.typingAttributes[.foregroundColor] as? NSColor
        else { return card.color }
        return color.nexusHex
    }

    private var textView: GrowingTextView? {
        if let live = app.activeCanvasTextView { return live }
        if let focused = NSApp.keyWindow?.firstResponder as? GrowingTextView {
            app.activeCanvasTextView = focused
            return focused
        }
        return findGrowingTextView(in: NSApp.keyWindow?.contentView)
    }

    private func findGrowingTextView(in root: NSView?) -> GrowingTextView? {
        guard let root else { return nil }
        if let match = root as? GrowingTextView { return match }
        for child in root.subviews {
            if let found = findGrowingTextView(in: child) { return found }
        }
        return nil
    }

    private func commitSizeDraft() {
        let cleaned = sizeDraft.filter(\.isNumber)
        guard let value = Int(cleaned), value > 0, value <= 200 else {
            sizeDraft = "\(Int(card.fontSize ?? 16))"
            return
        }
        sizeDraft = "\(value)"
        applySize(CGFloat(value))
    }

    private func toggleBold() {
        guard let view = textView, let storage = view.textStorage else {
            app.updateCard(card.id) { $0.bold = !($0.bold ?? false) }
            return
        }
        app.activeCanvasTextView = view
        let size = CGFloat(card.fontSize ?? 16)
        let range = view.selectedRange()
        let target = range.length > 0 ? range : NSRange(location: 0, length: storage.length)

        if target.length == 0 {
            var typing = view.typingAttributes
            let current = (typing[.font] as? NSFont) ?? NSFont.systemFont(ofSize: size)
            let bold = current.fontDescriptor.symbolicTraits.contains(.bold)
            typing[.font] = NSFont.systemFont(ofSize: current.pointSize, weight: bold ? .regular : .semibold)
            view.typingAttributes = typing
        } else {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: target) { value, subrange, _ in
                let current = (value as? NSFont) ?? NSFont.systemFont(ofSize: size)
                let bold = current.fontDescriptor.symbolicTraits.contains(.bold)
                let next = NSFont.systemFont(ofSize: current.pointSize, weight: bold ? .regular : .semibold)
                storage.addAttribute(.font, value: next, range: subrange)
            }
            storage.endEditing()
            view.didChangeText()
        }
        persist(from: view)
        restoreFocus(view)
    }

    private func addLink() {
        guard let view = textView else { return }
        app.activeCanvasTextView = view
        let selected = view.selectedRange()
        let raw = selected.length > 0 ? (view.string as NSString).substring(with: selected) : "https://"
        let alert = NSAlert()
        alert.messageText = "Add link"
        let field = NSTextField(string: raw.hasPrefix("http") ? raw : "https://")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            restoreFocus(view)
            return
        }
        var href = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if href.isEmpty {
            restoreFocus(view)
            return
        }
        if !href.contains("://") { href = "https://\(href)" }
        let range = selected.length > 0 ? selected : NSRange(location: view.selectedRange().location, length: 0)
        if range.length == 0 {
            let attr = NSAttributedString(string: href, attributes: [
                .link: href,
                .foregroundColor: NSColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: card.fontSize ?? 16)
            ])
            view.insertText(attr, replacementRange: range)
        } else {
            view.textStorage?.addAttributes([
                .link: href,
                .foregroundColor: NSColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }
        persist(from: view)
        restoreFocus(view)
    }

    private func prefix(_ mark: String) {
        guard let view = textView else {
            let body = card.body ?? card.html ?? ""
            let next = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let s = String(line)
                return s.hasPrefix(mark) ? s : mark + s
            }.joined(separator: "\n")
            app.updateCard(card.id) { $0.html = next; $0.body = next }
            return
        }
        app.activeCanvasTextView = view
        let ns = view.string as NSString
        let selected = view.selectedRange()
        let para = ns.paragraphRange(for: selected.length > 0 ? selected : NSRange(location: min(selected.location, ns.length), length: 0))
        let block = ns.substring(with: para)
        let next = block.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            if s.hasPrefix("• ") || s.hasPrefix("☐ ") || s.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return s
            }
            return mark + s
        }.joined(separator: "\n")
        view.textStorage?.replaceCharacters(in: para, with: next)
        persist(from: view)
        restoreFocus(view)
    }

    private func applyColor(_ hex: String) {
        guard let view = textView else { return }
        app.activeCanvasTextView = view
        let range = view.selectedRange()
        let target = range.length > 0 ? range : NSRange(location: 0, length: (view.string as NSString).length)
        let color = NSColor(Theme.color(hex))
        if target.length > 0 {
            view.textStorage?.addAttribute(.foregroundColor, value: color, range: target)
        }
        var typing = view.typingAttributes
        typing[.foregroundColor] = color
        view.typingAttributes = typing
        persist(from: view)
        restoreFocus(view)
    }

    private func applySize(_ size: CGFloat) {
        app.updateCard(card.id) { $0.fontSize = Double(size) }
        sizeDraft = "\(Int(size))"
        guard let view = textView else { return }
        app.activeCanvasTextView = view
        CanvasTextEditor.applyFontSize(size, to: view)
        view.invalidateIntrinsicContentSize()
        persist(from: view)
        restoreFocus(view)
    }

    private func persist(from view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let html = CanvasTextEditor.html(from: storage)
        let size = (view as? GrowingTextView)?.fittingContentSize ?? .zero
        app.updateCard(card.id) {
            $0.html = html
            $0.body = view.string
            if size.width > 0 {
                $0.width = max(32, min(640, Double(ceil(size.width))))
                $0.height = max(22, Double(ceil(size.height)))
            }
        }
    }

    private func restoreFocus(_ view: NSTextView) {
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}

struct AudioDetailView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.audioDetailID, let card = app.card(id), card.kind == .audio {
            ZStack {
                Color.black.opacity(0.72).onTapGesture { app.audioDetailID = nil }
                VStack {
                    HStack {
                        Spacer()
                        Button { app.audioDetailID = nil } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    WaveformView(
                        peaks: card.peaks ?? DemoLibrary.peaks,
                        progress: app.playingID == id ? Playback.shared.progress : 0,
                        onSeek: { app.seekPlay(id, fraction: $0) },
                        dragToSeek: true
                    )
                        .frame(maxHeight: .infinity)
                    HStack(spacing: 10) {
                        PlayControl(playing: app.playingID == id && !app.playbackPaused) { app.togglePlay(id) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title?.isEmpty == false ? card.title! : "Sound")
                                .font(.system(size: 15, weight: .semibold))
                            Text(app.playingID == id ? Format.duration(Playback.shared.currentSeconds) : (card.duration ?? "0:00"))
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(.black.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                    }
                }
                .foregroundStyle(.white)
                .padding(20)
                .frame(width: 280, height: 360)
                .background(Theme.color(card.color ?? "#34C759"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

struct LightboxView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let item: LightboxItem
    @State private var rotation: Double = 0
    @State private var original = false
    @State private var menuOpen = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.canvasColor(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { app.lightbox = nil } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28)
                            .background(scheme == .dark ? Color.white.opacity(0.12) : Color.white, in: Circle())
                            .overlay(Circle().stroke(Theme.chromeBorder))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(meta)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(scheme == .dark ? Color.white.opacity(0.7) : Theme.muted)
                    Spacer()
                    Button { menuOpen.toggle() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28)
                            .background(scheme == .dark ? Color.white.opacity(0.12) : Color.white, in: Circle())
                            .overlay(Circle().stroke(Theme.chromeBorder))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .zIndex(2)
                GeometryReader { geo in
                    let odd = Int(rotation.rounded()) % 180 != 0
                    let fit = odd
                        ? min(geo.size.width, geo.size.height) / max(geo.size.width, geo.size.height, 1)
                        : 1
                    RemoteImage(src: item.src)
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(rotation))
                        .scaleEffect((original ? 1 : 0.92) * fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .clipped()
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if menuOpen {
                lightboxMenu
                    .padding(.top, 52)
                    .padding(.trailing, 16)
                    .compositingGroup()
                    .zIndex(50)
            }
        }
    }

    private var meta: String {
        let name = URL(string: item.src)?.lastPathComponent ?? (item.alt ?? "Image")
        let size = item.bytes ?? Theme.fileBytes(item.src)
        if let size {
            return "\(name)   —   \(Format.bytes(size))"
        }
        return name
    }

    private var lightboxMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(system: "sparkles", title: "Ask AI", shortcut: "A") {
                app.askAbout(nil)
                app.lightbox = nil
            }
            MenuRow(system: "rotate.right", title: "Rotate") {
                rotation += 90
                menuOpen = false
            }
            MenuRow(system: "magnifyingglass", title: "Original Size") {
                original.toggle()
                menuOpen = false
            }
            MenuRow(system: "doc.on.doc", title: "Copy", shortcut: "⌘C") {
                if let url = URL(string: item.src), let image = NSImage(contentsOf: url) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                } else if let image = NSImage(contentsOfFile: item.src) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                menuOpen = false
            }
        }
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .chromePill(12)
    }
}

struct AskAIPanel: View {
    @Environment(AppModel.self) private var app
    @State private var question = ""
    @State private var log: [(String, String)] = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
                .ignoresSafeArea()
                .onTapGesture { app.askAICardID = nil }
            VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Ask AI").font(.system(size: 14, weight: .semibold))
                        Text(heading)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        Spacer()
                        Button { app.askAICardID = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                    .padding(16)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Context: \(app.askAICardID == "board" ? "the whole board" : "this card").")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                            ForEach(Array(log.enumerated()), id: \.offset) { _, row in
                                Text(row.1)
                                    .padding(10)
                                    .background(row.0 == "user" ? Theme.ink : Theme.hover, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(row.0 == "user" ? Color.white : Theme.ink)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    HStack {
                        TextField("Ask about this material…", text: $question)
                            .textFieldStyle(.roundedBorder)
                        Button("Send", action: send)
                    }
                    .padding(12)
                }
                .frame(width: 340, height: 480)
                .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.chromeBorder))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
                .padding(.trailing, 16)
                .padding(.top, 56)
            }
            Spacer()
            }
        }
        .allowsHitTesting(true)
    }

    private var heading: String {
        if app.askAICardID == "board" { return "Board" }
        if let id = app.askAICardID, let card = app.card(id) {
            let words = (card.html ?? card.body ?? card.title ?? "").split(separator: " ").prefix(6).joined(separator: " ")
            return words.isEmpty ? "Card" : words
        }
        return "Board"
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let context: String = {
            if let id = app.askAICardID, id != "board", let card = app.card(id) {
                return card.html ?? card.body ?? card.title ?? ""
            }
            return app.activeLesson?.cards.map { $0.html ?? $0.body ?? $0.title ?? "" }.joined(separator: "\n") ?? ""
        }()
        let clip = String(context.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(420))
        let answer = clip.isEmpty
            ? "Nothing on this card yet. Add text, a note, or a link, then ask again."
            : "From the board: \(clip)\n\n(\(q)) Connect an API key later for a live model — this preview stays on-device."
        log.append(("user", q))
        log.append(("ai", answer))
        question = ""
    }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).onTapGesture { app.paletteOpen = false }
            VStack(spacing: 0) {
                TextField("Search boards…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(.horizontal, 18)
                    .frame(height: 52)
                Divider()
                ForEach(app.library.lessons.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { lesson in
                    Button {
                        app.openLesson(lesson.id)
                        app.paletteOpen = false
                    } label: {
                        Text(lesson.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct ItemMenuOverlay: View {
    @Environment(AppModel.self) private var app
    let anchor: MenuAnchor
    @State private var colorsOpen = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { app.menu = nil }
            menuBody
                .offset(x: min(anchor.x, 900), y: min(anchor.y, 640))
        }
    }

    @ViewBuilder
    private var menuBody: some View {
        if let id = anchor.cardID, let card = app.card(id) {
            cardMenu(card)
        } else {
            canvasMenu
        }
    }

    private var canvasMenu: some View {
        HStack(spacing: 2) {
            HoverIconButton(system: "square.and.arrow.up") { app.pickFiles(); app.menu = nil }
                .help("File")
            HoverIconButton(system: "square.dashed") { app.menu = nil }
                .help("Frame")
            HoverIconButton(system: "link") { app.linkPrompt = true; app.menu = nil }
                .help("Link")
            HoverIconButton(system: "pencil") { app.tool = .draw; app.menu = nil }
                .help("Pen")
            HoverIconButton(system: "cursorarrow") { app.tool = .select; app.menu = nil }
                .help("Select")
        }
        .padding(6)
        .chromePill(18)
    }

    private func cardMenu(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(system: "sparkles", title: "Ask AI", shortcut: "A") {
                app.askAbout(card.id)
                app.menu = nil
            }
            if card.kind == .link, let url = card.url {
                MenuRow(system: "arrow.up.right", title: "Go to link") {
                    app.openExternal(url)
                    app.menu = nil
                }
            }
            if card.kind == .video || card.kind == .youtube {
                MenuRow(system: "eye", title: "Preview", shortcut: "Space") {
                    if card.kind == .video {
                        app.lightbox = LightboxItem(src: card.poster ?? "", alt: card.title)
                    } else if let id = card.videoId {
                        app.lightbox = LightboxItem(src: "https://img.youtube.com/vi/\(id)/hqdefault.jpg", alt: card.title)
                    }
                    app.menu = nil
                }
            }
            if card.kind == .shortcut, let path = card.targetPath {
                MenuRow(system: "folder", title: "Open") {
                    app.openPath(path)
                    app.menu = nil
                }
            }
            if card.kind == .text {
                MenuRow(system: "note.text", title: "Turn into note", shortcut: "N") {
                    app.turnIntoNote(card.id)
                    app.menu = nil
                }
            }
            if card.kind != .video && card.kind != .youtube && card.kind != .text {
                MenuRow(swatch: card.color, title: "Item color") { colorsOpen.toggle() }
                if colorsOpen {
                    ColorPalette(current: card.color) { hex in
                        app.updateCard(card.id) { $0.color = hex }
                        app.menu = nil
                    }
                }
            }
            if card.kind == .link {
                MenuRow(system: "eye.slash", title: "Hide visual") {
                    app.updateCard(card.id) { $0.hideVisual = !($0.hideVisual ?? false) }
                    app.menu = nil
                }
            }
            if card.kind != .text {
                menuDivider
            }
            MenuRow(system: "doc.on.doc", title: "Copy", shortcut: "⌘C") {
                app.copySelected()
                app.menu = nil
            }
            MenuRow(system: "plus.rectangle.on.rectangle", title: "Duplicate", shortcut: "⌘D") {
                app.duplicateSelected()
                app.menu = nil
            }
            MenuRow(system: "square.stack.3d.up", title: "Layer up", shortcut: "⌘]") {
                app.layer(1)
                app.menu = nil
            }
            MenuRow(system: "square.stack.3d.down", title: "Layer back", shortcut: "⌘[") {
                app.layer(-1)
                app.menu = nil
            }
            menuDivider
            MenuRow(system: "xmark", title: "Delete", shortcut: "Del", destructive: true) {
                app.deleteSelected()
                app.menu = nil
            }
        }
        .padding(8)
        .frame(width: 228, alignment: .leading)
        .chromePill(14)
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
    }
}

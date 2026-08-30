import AppKit
import AVFoundation
import SwiftUI

extension AppModel {
    /// Height, from the window's top edge, that floating chrome (context
    /// menus, format bar) may actually use before the Dock covers it.
    /// `NSScreen.visibleFrame` only accounts for a Dock that's *pinned*
    /// on-screen — an auto-hiding Dock reserves no space there at all, and
    /// instead reveals transiently on hover, exactly where a bottom-anchored
    /// click tends to land (the user right-clicks near the bottom edge, which
    /// is itself what triggers the reveal). So on top of whatever a pinned
    /// Dock/menu bar already costs, always reserve a fixed safety margin
    /// (roughly a default Dock's height) regardless of Dock settings.
    static func visibleChromeHeight(fallback: CGFloat) -> CGFloat {
        let dockSafety: CGFloat = 100
        guard let window = NSApp.keyWindow, let screen = window.screen else {
            return max(0, fallback - dockSafety)
        }
        let reservedInset = max(dockSafety, screen.visibleFrame.minY - window.frame.minY)
        return max(0, fallback - reservedInset)
    }
}

struct TextFormatBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let card: Card
    @State private var panel = Panel.none
    @State private var sizeDraft = ""
    @FocusState private var sizeFieldFocused: Bool

    private enum Panel { case none, lists, color, size }

    private var currentSize: Int {
        if let view = textView,
           let font = view.typingAttributes[.font] as? NSFont
        {
            return max(8, Int(font.pointSize.rounded()))
        }
        return max(8, Int((card.fontSize ?? 16).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                HoverIconButton(system: "bold", size: 28) { toggleBold() }
                    .help("Bold")
                HoverIconButton(icon: .goToLink, size: 28) { addLink() }
                    .help("Link")
                HoverIconButton(icon: .bulletList, size: 28, active: panel == .lists) {
                    keepEditingSession()
                    if let view = textView {
                        app.textEditingRange = view.selectedRange()
                        app.activeCanvasTextView = view
                    }
                    panel = panel == .lists ? .none : .lists
                }
                .help("Lists")
                HoverIconButton(icon: .editColor, size: 28, active: panel == .color) {
                    keepEditingSession()
                    if let view = textView {
                        app.textEditingRange = view.selectedRange()
                        app.activeCanvasTextView = view
                    }
                    panel = panel == .color ? .none : .color
                }
                .help("Color")
                sizeControl
                    .help("Font size")
                Button {
                    keepEditingSession()
                    app.askAbout(card.id)
                } label: {
                    AppIconView(icon: .askAI, size: 14)
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Ask AI")
                HoverIconButton(icon: .removeFormatting, size: 28) {
                    clearFormatting()
                }
                .help("Clear formatting")
            }
            .padding(6)

            if panel == .lists {
                VStack(alignment: .leading, spacing: 0) {
                    MenuRow(icon: .bulletList, title: "Bullet list") { applyList(.bullet) }
                    MenuRow(icon: .numberedList, title: "Numbered list") { applyList(.numbered) }
                    MenuRow(icon: .todoList, title: "To-do list") { applyList(.todo) }
                }
                .padding(6)
            }
            if panel == .color {
                ColorPalette(
                    current: currentTextColor,
                    onReset: { applyColor(card.color ?? "#111318") }
                ) { hex in
                    applyColor(hex)
                }
                .padding(6)
            }
            if panel == .size {
                sizeStepper
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .chromePill(12, opaque: true)
        .contentShape(Rectangle())
        // Keep editing alive while interacting with the bar.
        .onHover { inside in
            app.formatBarHovered = inside
            if inside { app.editingID = card.id }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    app.formatBarHovered = true
                    if app.editingID != card.id {
                        app.editingID = card.id
                    }
                }
        )
        .onAppear {
            panel = .none
            sizeDraft = "\(currentSize)"
            if let view = textView {
                app.activeCanvasTextView = view
            }
        }
        .onChange(of: card.id) { _, _ in
            panel = .none
        }
        .onChange(of: app.editingID) { _, id in
            if id != card.id { panel = .none }
        }
        .onChange(of: card.fontSize) { _, value in
            if !sizeFieldFocused {
                sizeDraft = "\(Int(value ?? 16))"
            }
        }
        .onChange(of: panel) { _, next in
            if next == .size {
                sizeDraft = "\(currentSize)"
            }
        }
    }

    /// Plain size label in the toolbar — number only, no pill / chevron.
    private var sizeControl: some View {
        Button {
            keepEditingSession()
            if let view = textView {
                app.textEditingRange = view.selectedRange()
                app.activeCanvasTextView = view
            }
            sizeDraft = "\(currentSize)"
            panel = panel == .size ? .none : .size
            AppSounds.playTap()
        } label: {
            Text("\(currentSize)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryInk(scheme))
                .frame(width: 28, height: 28)
                .background(Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    /// Separate rounded island under the bar: `- [ 24 ] +`
    private var sizeStepper: some View {
        HStack(spacing: 4) {
            stepButton(system: "minus") { bumpSize(-4) }
            Text("[")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.muted)
            TextField("", text: $sizeDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 40, height: 28)
                .focused($sizeFieldFocused)
                .onSubmit { commitSizeDraft() }
                .onChange(of: sizeFieldFocused) { _, focused in
                    if !focused { commitSizeDraft() }
                }
            Text("]")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.muted)
            stepButton(system: "plus") { bumpSize(4) }
        }
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button {
            keepEditingSession()
            action()
            AppSounds.playTap()
        } label: {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.primaryInk(scheme))
                .frame(width: 28, height: 28)
                .background(Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func bumpSize(_ delta: Int) {
        let next = min(200, max(8, currentSize + delta))
        sizeDraft = "\(next)"
        applySize(CGFloat(next))
    }

    private var currentTextColor: String? {
        guard let view = textView,
              let color = view.typingAttributes[.foregroundColor] as? NSColor
        else { return card.color }
        return color.vasaHex
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
        guard let value = Int(cleaned), value > 0 else {
            sizeDraft = "\(currentSize)"
            return
        }
        let clamped = min(200, max(8, value))
        sizeDraft = "\(clamped)"
        applySize(CGFloat(clamped))
    }

    private func toggleBold() {
        keepEditingSession()
        guard let view = textView, let storage = view.textStorage else {
            app.updateCard(card.id) { $0.bold = !($0.bold ?? false) }
            return
        }
        app.activeCanvasTextView = view
        let size = CGFloat(card.fontSize ?? 16)
        let live = view.selectedRange()
        let fullLen = storage.length
        let saved = app.textEditingRange
        let target: NSRange = {
            if live.length > 0 { return live }
            if saved.length > 0, saved.location + saved.length <= fullLen { return saved }
            return NSRange(location: 0, length: fullLen)
        }()

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
            view.setSelectedRange(target)
            app.textEditingRange = target
            app.textSelectionLength = target.length
        }
        persist(from: view, relayout: false)
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

    private func applyList(_ kind: TextListMarkup.Kind) {
        keepEditingSession()
        guard let view = textView, let storage = view.textStorage else {
            // Prefer plain body — HTML tags break mark detection.
            let body = card.body ?? ""
            let next = TextListMarkup.apply(kind, to: body)
            app.updateCard(card.id) {
                $0.body = next
                $0.html = next
            }
            panel = .none
            return
        }
        app.activeCanvasTextView = view
        let ns = view.string as NSString
        let live = view.selectedRange()
        let fullLen = ns.length
        let saved = app.textEditingRange
        let seed: NSRange = {
            if live.length > 0 { return live }
            if saved.length > 0, saved.location + saved.length <= fullLen { return saved }
            if live.location <= fullLen { return NSRange(location: min(live.location, fullLen), length: 0) }
            if saved.location <= fullLen { return NSRange(location: min(saved.location, fullLen), length: 0) }
            return NSRange(location: 0, length: fullLen)
        }()
        let para: NSRange = {
            if seed.length > 0 {
                return ns.paragraphRange(for: seed)
            }
            // Caret / lost selection: rewrite the whole contiguous list around the caret.
            return TextListMarkup.contiguousListParagraphRange(in: ns, location: seed.location)
        }()
        let block = ns.substring(with: para)
        let next = TextListMarkup.apply(kind, to: block)
        let style = view.typingAttributes
        storage.beginEditing()
        storage.replaceCharacters(in: para, with: next)
        let applied = NSRange(location: para.location, length: (next as NSString).length)
        if applied.length > 0 {
            if let font = style[.font] as? NSFont {
                storage.addAttribute(.font, value: font, range: applied)
            }
            if let color = style[.foregroundColor] as? NSColor {
                storage.addAttribute(.foregroundColor, value: color, range: applied)
            }
            TodoMarks.restyleMarks(in: storage, range: applied)
        }
        storage.endEditing()
        let caret = min(para.location + (next as NSString).length, storage.length)
        view.setSelectedRange(NSRange(location: caret, length: 0))
        TextTypingStyle.restore(style, on: view)
        app.textEditingRange = view.selectedRange()
        persist(from: view)
        restoreFocus(view)
        panel = .none
    }

    private func applyColor(_ hex: String) {
        guard let view = textView else { return }
        app.activeCanvasTextView = view
        keepEditingSession()
        let live = view.selectedRange()
        let fullLen = (view.string as NSString).length
        let saved = app.textEditingRange
        // Prefer live selection; fall back to range captured before focus steal.
        let target: NSRange = {
            if live.length > 0 { return live }
            if saved.length > 0, saved.location + saved.length <= fullLen { return saved }
            if fullLen > 0 { return NSRange(location: 0, length: fullLen) }
            return live
        }()
        let color = NSColor.vasa(hex: hex)
        view.textStorage?.beginEditing()
        if target.length > 0 {
            view.textStorage?.addAttribute(.foregroundColor, value: color, range: target)
        }
        view.textStorage?.endEditing()
        var typing = view.typingAttributes
        typing[.foregroundColor] = color
        view.typingAttributes = typing
        view.insertionPointColor = color
        view.setSelectedRange(target)
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        app.textEditingRange = target
        app.textSelectionLength = target.length
        persist(from: view, relayout: false)
        restoreFocus(view)
    }

    private func clearFormatting() {
        guard let view = textView else { return }
        app.activeCanvasTextView = view
        keepEditingSession()
        let live = view.selectedRange()
        let fullLen = (view.string as NSString).length
        let saved = app.textEditingRange
        let target: NSRange = {
            if live.length > 0 { return live }
            if saved.length > 0, saved.location + saved.length <= fullLen { return saved }
            if fullLen > 0 { return NSRange(location: 0, length: fullLen) }
            return live
        }()
        let size = CGFloat(card.fontSize ?? 16)
        // Fall back to the *current appearance's* ink — a hardcoded light-mode hex here
        // baked black text into the storage while on the dark canvas.
        let ink = card.color.map { NSColor.vasa(hex: $0) } ?? Theme.defaultInkNSColor(scheme)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: ink
        ]
        view.textStorage?.beginEditing()
        if target.length > 0 {
            view.textStorage?.removeAttribute(.font, range: target)
            view.textStorage?.removeAttribute(.foregroundColor, range: target)
            view.textStorage?.removeAttribute(.underlineStyle, range: target)
            view.textStorage?.removeAttribute(.link, range: target)
            view.textStorage?.addAttributes(base, range: target)
        }
        view.textStorage?.endEditing()
        view.typingAttributes = base
        view.insertionPointColor = ink
        view.needsDisplay = true
        persist(from: view, relayout: false)
        restoreFocus(view)
    }

    private func applySize(_ size: CGFloat) {
        app.updateCard(card.id) { $0.fontSize = Double(size) }
        sizeDraft = "\(Int(size))"
        guard let view = textView else {
            // Not editing — hug from stored attributed text.
            let attr = CanvasTextEditor.attributed(
                html: card.html,
                plain: card.body ?? card.html,
                size: size,
                ink: card.color.map { NSColor.vasa(hex: $0) } ?? Theme.defaultInkNSColor(scheme)
            )
            let hug = CanvasTextEditor.hugSize(for: attr)
            app.updateCard(card.id, persist: false) {
                $0.width = Double(hug.width)
                $0.height = Double(hug.height)
            }
            return
        }
        app.activeCanvasTextView = view
        CanvasTextEditor.applyFontSize(size, to: view)
        view.invalidateIntrinsicContentSize()
        persist(from: view, relayout: true)
        // Force hug after font bump so a stale tall frame cannot win a race with preview-fit.
        if !app.isResizingCard(card.id) {
            let hug = view.fittingContentSize
            app.updateCard(card.id, persist: false) {
                $0.width = Double(max(36, ceil(hug.width)))
                $0.height = Double(max(TextToolReducer.defaultSize.height, ceil(hug.height)))
            }
        }
        restoreFocus(view)
    }

    private func persist(from view: NSTextView, relayout: Bool = true) {
        guard let storage = view.textStorage else { return }
        let html = CanvasTextEditor.html(from: storage)
        keepEditingSession()
        app.updateCard(card.id, persist: false) {
            $0.html = html
            $0.body = view.string
        }
        // Attribute-only edits (color) must not bounce fittingContentSize — that remounts
        // the text view and flashes / drops the just-applied color.
        guard relayout, let growing = view as? GrowingTextView else { return }
        growing.didChangeText()
    }

    /// Format bar clicks steal first responder — keep the text card in edit mode + bar visible.
    private func keepEditingSession() {
        app.formatBarHovered = true
        app.editingID = card.id
    }

    private func restoreFocus(_ view: NSTextView) {
        keepEditingSession()
        if let growing = view as? GrowingTextView {
            app.activeCanvasTextView = growing
        }
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
    @State private var videoPaused = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.canvasColor(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    lightboxChromeButton(system: "chevron.left", rotated: false) { app.lightbox = nil }
                    Spacer()
                    HStack(spacing: 8) {
                        Text(fileName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primaryInk(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let dimensions { metaBadge(dimensions) }
                        if let weight { metaBadge(weight) }
                    }
                    Spacer()
                    lightboxChromeButton(system: "ellipsis", rotated: true) { menuOpen.toggle() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .zIndex(2)
                GeometryReader { geo in
                    if item.videoSrc != nil, Playback.shared.lastError == nil, let player = Playback.shared.videoPlayer {
                        ZStack {
                            // .resizeAspect (not .resizeAspectFill): the preview must show the
                            // whole, unmodified frame — the canvas card thumbnail is the only
                            // place that's allowed to crop-to-fill.
                            VideoPlayerLayerView(player: player, gravity: .resizeAspect)
                            if videoPaused {
                                // Purely decorative — the single tap target below owns play/pause.
                                // A second, nested tappable control here double-fired the toggle
                                // (button action + the outer tap gesture both landing on one
                                // click), which made resuming from pause immediately re-pause.
                                PlayControl(playing: false, large: true) {}
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if videoPaused { Playback.shared.resume() } else { Playback.shared.pause() }
                            videoPaused.toggle()
                        }
                    } else {
                        // Re-fit within a box with dimensions swapped for a 90/270° rotation,
                        // then rotate — lets scaledToFit compute the correct fit for the actual
                        // image aspect ratio instead of a flat container-ratio guess (which
                        // could shrink a rotated image to roughly half size for no reason).
                        let odd = Int(rotation.rounded()) % 180 != 0
                        let boxSize = odd
                            ? CGSize(width: geo.size.height, height: geo.size.width)
                            : geo.size
                        RemoteImage(src: item.src)
                            .resizable()
                            .scaledToFit()
                            .frame(width: boxSize.width, height: boxSize.height)
                            .scaleEffect(original ? 1 : 0.92)
                            .rotationEffect(.degrees(rotation))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
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
        .onAppear {
            if let videoSrc = item.videoSrc, let url = AppModel.mediaURL(from: videoSrc) {
                Playback.shared.playVideo(url: url)
            }
        }
        .onDisappear {
            if item.videoSrc != nil { Playback.shared.stop() }
        }
    }

    /// Squircle chrome button — the shape the reference preview uses for both corners.
    private func lightboxChromeButton(
        system: String,
        rotated: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryInk(scheme))
                .rotationEffect(.degrees(rotated ? 90 : 0))
                .frame(width: 30, height: 30)
                .background(
                    scheme == .dark ? Color.white.opacity(0.12) : Color.white,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.hairline(scheme)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One fact about the file (pixel size, weight): square hairline outline, no fill.
    /// Drawn as an overlay — a plain `.background(Color)` bleeds past the safe area and
    /// ran up into the titlebar.
    private func metaBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.72) : Theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Rectangle().stroke(Theme.hairline(scheme), lineWidth: 1))
    }

    /// For a video, `item.src` is the poster thumbnail (stand-in until playback starts) —
    /// name, size and dimensions must come from `videoSrc`, the file actually on screen.
    private var metaSource: String { item.videoSrc ?? item.src }

    private var fileName: String {
        URL(string: metaSource)?.lastPathComponent ?? (item.alt ?? "Image")
    }

    private var dimensions: String? {
        guard item.videoSrc == nil, let size = Theme.pixelSize(metaSource) else { return nil }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var weight: String? {
        let bytes = (item.videoSrc == nil ? item.bytes : nil) ?? Theme.fileBytes(metaSource)
        return bytes.map { Format.bytes($0) }
    }

    private var lightboxMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: .askAI, title: "Ask AI", shortcut: "A") {
                app.openLens(item.src)
                menuOpen = false
            }
            if item.videoSrc == nil {
                MenuRow(system: "rotate.right", title: "Rotate") {
                    rotation += 90
                    menuOpen = false
                }
                MenuRow(system: "magnifyingglass", title: "Original Size") {
                    original.toggle()
                    menuOpen = false
                }
            }
            MenuRow(icon: .copy, title: "Copy", shortcut: "⌘C") {
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

// AskAIPanel removed — replaced by Chrome/AIChat/ChatPanel.swift (multi-turn streaming chat).

struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private struct CardMatch: Identifiable {
        let card: Card
        let lessonId: String
        let lessonTitle: String
        var id: String { card.id }
    }

    private var matchingBoards: [Lesson] {
        guard !query.isEmpty else { return app.library.lessons }
        return app.library.lessons.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Cards across every board — every lesson's cards are already resident in
    /// `library.lessons` (loaded eagerly at launch), so this is a plain in-memory scan.
    private var matchingCards: [CardMatch] {
        guard query.count >= 2 else { return [] }
        var results: [CardMatch] = []
        for lesson in app.library.lessons {
            for card in lesson.cards where card.kind != .group {
                guard card.searchText.localizedCaseInsensitiveContains(query) else { continue }
                results.append(CardMatch(card: card, lessonId: lesson.id, lessonTitle: lesson.title))
                if results.count >= 60 { return results }
            }
        }
        return results
    }

    private func snippet(_ text: String, around query: String) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = collapsed.range(of: query, options: .caseInsensitive) else {
            return String(collapsed.prefix(80))
        }
        let start = collapsed.index(range.lowerBound, offsetBy: -24, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let end = collapsed.index(range.upperBound, offsetBy: 56, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        let slice = collapsed[start..<end]
        return (start > collapsed.startIndex ? "…" : "") + slice + (end < collapsed.endIndex ? "…" : "")
    }

    var body: some View {
        ZStack {
            // No dimmer — darkening the whole canvas while the palette is open makes it
            // look broken, not focused (a light click-catcher is enough to close on outside tap).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { app.paletteOpen = false }
            VStack(spacing: 0) {
                TextField("Search boards and cards…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primaryInk(scheme))
                    .padding(.horizontal, 18)
                    .frame(height: 52)
                    .focused($fieldFocused)
                Divider().overlay(Theme.hairline(scheme))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !matchingBoards.isEmpty {
                            sectionLabel("Boards")
                            ForEach(matchingBoards) { lesson in
                                Button {
                                    app.openLesson(lesson.id)
                                    app.paletteOpen = false
                                } label: {
                                    Label(lesson.title, systemImage: "square.grid.2x2")
                                        .foregroundStyle(Theme.primaryInk(scheme))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if !matchingCards.isEmpty {
                            sectionLabel("Cards")
                            ForEach(matchingCards) { match in
                                Button {
                                    let id = match.card.id
                                    if app.library.activeLessonId != match.lessonId {
                                        app.openLesson(match.lessonId)
                                    }
                                    app.paletteOpen = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        app.revealCard(id)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(snippet(match.card.searchText, around: query))
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.primaryInk(scheme))
                                            .lineLimit(1)
                                        Text(match.lessonTitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.secondaryInk(scheme))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if query.count >= 2, matchingBoards.isEmpty, matchingCards.isEmpty {
                            Text("No results")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryInk(scheme))
                                .padding(18)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline(scheme)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 24, y: 10)
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { fieldFocused = true }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondaryInk(scheme))
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

struct ItemMenuOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let anchor: MenuAnchor
    @State private var colorsOpen = false
    @State private var menuSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let margin: CGFloat = 10
            // Clamp to the live overlay bounds — that is what actually clips drawing.
            let visibleHeight = AppModel.visibleChromeHeight(fallback: geo.size.height)
            let bounds = CGSize(width: geo.size.width, height: visibleHeight)
            let size = effectiveMenuSize
            let origin = Self.fittedOrigin(
                anchor: CGPoint(x: anchor.x, y: anchor.y),
                menu: size,
                bounds: bounds,
                margin: margin
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { app.menu = nil }
                menuBody
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { updateMenuSize(proxy.size) }
                                .onChange(of: proxy.size) { _, newSize in
                                    updateMenuSize(newSize)
                                }
                        }
                    }
                    .offset(x: origin.x, y: origin.y)
            }
        }
    }

    /// Measured size when available; otherwise a kind-based estimate so the first
    /// frame already flips away from clipped edges instead of waiting on layout.
    private var effectiveMenuSize: CGSize {
        if menuSize.width > 1, menuSize.height > 1 { return menuSize }
        if anchor.cardID != nil {
            var height: CGFloat = 340
            if colorsOpen { height += 80 }
            return CGSize(width: 228, height: height)
        }
        return CGSize(width: 200, height: 44)
    }

    private func updateMenuSize(_ newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        if abs(newSize.width - menuSize.width) > 0.5
            || abs(newSize.height - menuSize.height) > 0.5 {
            menuSize = newSize
        }
    }

    /// Prefer the click point as the menu's top-left. If that would overflow the
    /// bottom, shift up; if the right, shift left; if the left, shift right; if
    /// the top, shift down — so the full menu stays inside `bounds`.
    private static func fittedOrigin(
        anchor: CGPoint,
        menu: CGSize,
        bounds: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        var x = anchor.x
        var y = anchor.y
        if x + menu.width + margin > bounds.width {
            x = bounds.width - menu.width - margin
        }
        if x < margin {
            x = margin
        }
        if y + menu.height + margin > bounds.height {
            y = bounds.height - menu.height - margin
        }
        if y < margin {
            y = margin
        }
        return CGPoint(x: x, y: y)
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
            HoverIconButton(icon: .add) { app.pickFiles(); app.menu = nil }
                .help("File")
            HoverIconButton(system: "square.dashed") { app.groupSelection(); app.menu = nil }
                .help("Frame")
            HoverIconButton(icon: .goToLink) { app.linkPrompt = true; app.menu = nil }
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
            if card.kind == .link {
                linkCardMenu(card)
            } else {
                genericCardMenu(card)
            }
        }
        .padding(8)
        .frame(width: 228, alignment: .leading)
        .chromePill(14, opaque: true)
    }

    @ViewBuilder
    private func linkCardMenu(_ card: Card) -> some View {
        MenuRow(icon: .askAI, title: "Ask AI", shortcut: "A") {
            if let image = card.image {
                app.openLens(image)
            } else if let url = card.url {
                app.openExternal(url)
            }
            app.menu = nil
        }
        if let url = card.url {
            MenuRow(icon: .goToLink, title: "Go to link") {
                app.openExternal(url)
                app.menu = nil
            }
        }
        MenuRow(swatch: card.color, title: "Item color") { colorsOpen.toggle() }
        if colorsOpen {
            ColorPalette(current: card.color) { hex in
                app.updateCard(card.id) { $0.color = hex }
                app.menu = nil
            }
        }
        if card.image != nil {
            let hidden = card.hideVisual == true
            MenuRow(icon: .hideVisual, title: hidden ? "Show visual" : "Hide visual") {
                app.toggleLinkVisual(card.id)
                app.menu = nil
            }
        } else {
            MenuRow(icon: .hideVisual, title: "Fetch visual") {
                app.fetchLinkVisual(card.id)
                app.menu = nil
            }
        }
        menuDivider
        sharedCardActions(card)
    }

    @ViewBuilder
    private func genericCardMenu(_ card: Card) -> some View {
        if card.kind == .image {
            MenuRow(icon: .askAI, title: "Ask AI", shortcut: "A") {
                app.openLens(card.src)
                app.menu = nil
            }
        }
        if card.kind == .text || card.kind == .note {
            MenuRow(icon: .askAI, title: "Ask AI", shortcut: "A") {
                app.askAbout(card.id)
                app.menu = nil
            }
        }
        if card.kind == .video || card.kind == .youtube {
            MenuRow(system: "eye", title: "Preview", shortcut: "Space") {
                if card.kind == .video {
                    app.openVideoPreview(card)
                } else if let id = card.videoId {
                    app.lightbox = LightboxItem(src: "https://img.youtube.com/vi/\(id)/hqdefault.jpg", alt: card.title)
                }
                app.menu = nil
            }
        }
        if card.kind == .shortcut, let path = card.targetPath {
            MenuRow(icon: .revealInFinder, title: "Open") {
                app.openPath(path)
                app.menu = nil
            }
        }
        if card.kind == .text {
            MenuRow(icon: .turnIntoNote, title: "Turn into note", shortcut: "N") {
                app.turnIntoNote(card.id)
                app.menu = nil
            }
        }
        if card.kind != .video && card.kind != .youtube && card.kind != .text {
            MenuRow(swatch: card.color, title: card.kind == .group ? "Group color" : "Item color") { colorsOpen.toggle() }
            if colorsOpen {
                ColorPalette(
                    current: card.color,
                    onReset: {
                        app.updateCard(card.id) { $0.color = nil }
                        app.menu = nil
                    }
                ) { hex in
                    app.updateCard(card.id) { $0.color = hex }
                    app.menu = nil
                }
            }
        }
        if card.kind != .text {
            menuDivider
        }
        sharedCardActions(card, includeDeleteDivider: true)
    }

    @ViewBuilder
    private func sharedCardActions(_ card: Card, includeDeleteDivider: Bool = false) -> some View {
        MenuRow(icon: .copy, title: "Copy", shortcut: "⌘C") {
            app.copySelected()
            app.menu = nil
        }
        MenuRow(icon: .duplicate, title: "Duplicate", shortcut: "⌘D") {
            app.duplicateSelected()
            app.menu = nil
        }
        if card.kind == .group {
            MenuRow(system: "rectangle.3.group", title: "Ungroup", shortcut: "⇧⌘G") {
                app.ungroupSelection()
                app.menu = nil
            }
        } else if app.selectedIDs.count >= 2 {
            // Grouping a lone object is a no-op nobody asked for — the row only
            // makes sense once there's more than one thing to bundle together.
            MenuRow(system: "square.dashed", title: "Group", shortcut: "⌘G") {
                app.groupSelection()
                app.menu = nil
            }
        }
        if app.selectedIDs.count >= 2 || card.kind == .group {
            MenuRow(system: "square.grid.2x2", title: "Organize by types", shortcut: nil) {
                app.arrangeSelection()
                app.menu = nil
            }
            MenuRow(icon: .askAI, title: "Organize with AI", shortcut: nil) {
                app.openAIArrangePrompt()
                app.menu = nil
            }
        }
        MenuRow(icon: .layerUp, title: "Layer up", shortcut: "⌘]") {
            app.layer(1)
            app.menu = nil
        }
        MenuRow(icon: .layerBack, title: "Layer back", shortcut: "⌘[") {
            app.layer(-1)
            app.menu = nil
        }
        if includeDeleteDivider {
            menuDivider
        }
        MenuRow(icon: .delete, title: "Delete", shortcut: "Del", destructive: true) {
            app.deleteSelected()
            app.menu = nil
        }
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(Theme.hairline(scheme))
            .frame(height: 1)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
    }
}


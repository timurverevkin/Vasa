import AppKit
import AVFoundation
import SwiftUI
import WebKit

struct CardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    let selected: Bool

    var body: some View {
        let clipRadius = contentClipRadius
        content
            .frame(width: card.previewWidth, height: card.previewHeight)
            .modifier(CardClip(radius: clipRadius))
            .modifier(CardComposite(enabled: clipRadius >= 0))
            .overlay {
                if showsChrome {
                    CardSelection(
                        selected: true,
                        showNotch: true,
                        radius: chromeRadius,
                        outset: card.kind == .text ? 0 : 3,
                        size: CGSize(width: card.previewWidth, height: card.previewHeight),
                        zoom: CGFloat(app.activeLesson?.camera.zoom ?? 1),
                        look: liftLook,
                        onResize: { size in app.resizeCard(card.id, to: size) },
                        onEnd: {
                            app.endCardResize()
                            app.snapSelected()
                            app.saveNow()
                        }
                    )
                } else if liftLook != .solid {
                    SelectionFrame(
                        radius: chromeRadius,
                        outset: 3,
                        notched: false,
                        zoom: CGFloat(app.activeLesson?.camera.zoom ?? 1),
                        look: liftLook
                    )
                }
                if card.kind == .group, let frameLook = app.groupFrameLook(for: card.id) {
                    SelectionFrame(
                        radius: Format.groupRadius,
                        outset: 4,
                        notched: false,
                        zoom: CGFloat(app.activeLesson?.camera.zoom ?? 1),
                        look: frameLook
                    )
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .position(x: card.previewWidth / 2 + card.x, y: card.previewHeight / 2 + card.y)
            // Select on press (not delayed tap). Pairing single+double onTapGesture
            // waits for the double-click timeout (~300ms) before selecting.
            // Editing text: no card-drag — pointer selects glyphs. Selected-but-idle text still moves.
            // Draw tool owns the pointer (pen + eraser) — cards must not steal the drag.
            .gesture(blocksCardDrag ? nil : pressAndMoveGesture)
            // SpatialTapGesture (not plain TapGesture) so a double-click on a text card can
            // hand its location to beginTextEditing — the click never reaches the NSTextView
            // itself (not hit-testable until `isEditable` flips on the next render pass), so
            // without this the caret would silently stay wherever the last edit left it.
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in open(at: value.location) })
            .allowsHitTesting(app.tool != .draw)
    }

    /// Only while editing — selecting a text card must not tear down an in-progress drag
    /// (that left snap guides stuck and made the card undraggable).
    private var textBlocksCardDrag: Bool {
        guard card.kind == .text else { return false }
        return isEditingText
    }

    private var blocksCardDrag: Bool {
        textBlocksCardDrag || app.tool == .draw || (card.kind == .group && app.editingGroupID == card.id)
    }

    private var isEditingText: Bool {
        card.kind == .text && app.editingID == card.id
    }

    @ViewBuilder
    private var content: some View {
        switch card.kind {
        case .text: TextCardView(card: card)
        case .note: NoteCardView(card: card)
        case .image: ImageCardView(card: card)
        case .link: LinkCardView(card: card)
        case .audio: AudioCardView(card: card)
        case .video: VideoCardView(card: card)
        case .shortcut, .folder: ShortcutCardView(card: card)
        case .draw: DrawCardView(card: card)
        case .youtube: YouTubeCardView(card: card)
        case .group: GroupCardView(card: card)
        }
    }

    private var liftLook: SelectionLook {
        app.groupDragLook(for: card.id)
    }

    private var showsChrome: Bool {
        guard selected else { return false }
        switch card.kind {
        case .audio: return false
        case .text: return !isEditingText
        default: return true
        }
    }

    private var chromeRadius: CGFloat {
        switch card.kind {
        case .note, .audio, .image, .video, .youtube, .shortcut, .folder: Format.cardRadius
        case .link: card.showsRichLink ? Format.cardBorderedRadius : Format.cardRadius
        case .text: 8
        case .group: Format.groupRadius
        default: 14
        }
    }

    private var contentClipRadius: CGFloat {
        switch card.kind {
        case .image, .video, .youtube, .note, .audio, .shortcut, .folder: Format.cardRadius
        case .link: card.showsRichLink ? Format.cardBorderedRadius : Format.cardRadius
        case .group: Format.groupRadius
        case .text, .draw: -1
        default: 0
        }
    }

    @State private var moveAxis: Axis?
    @State private var moveOrigins: [String: CGPoint] = [:]
    @State private var pointerOrigin: CGPoint = .zero
    @State private var didPushMove = false
    @State private var pressBegan = false
    @State private var pressWasSelected = false
    @State private var pressTargetID = ""
    @State private var pressShiftAtStart = false
    @State private var pressGroupMarquee = false

    /// Shift means two different things depending on *when* it's held, disambiguated by
    /// whether it was already down the instant the press began:
    /// - Shift held before the press (e.g. shift-click on a group member): picks that one
    ///   card instead of the whole group, for building a multi-select within a group.
    /// - Shift pressed after an (unmodified) press already selected/grabbed an object and
    ///   the drag is under way: locks movement to one axis (see the `moveAxis` block below).
    /// A shift-drag that starts on the group's own plaque (not a specific member — e.g. its
    /// padding/title area) rubber-band-selects whatever it covers instead, so shift-drag
    /// inside a group always means "select", never "drag the group".
    ///
    /// Group selection is group-first (Illustrator/Keynote/Figma contract): an unmodified
    /// click on a member selects the *whole group* when the group isn't already the
    /// selection; only the next click drills into that one member. Whatever ends up
    /// highlighted at press-time is exactly what a following drag moves and what Delete
    /// removes — no separate drag-time escalation. A plain click on the plaque itself
    /// (`card.kind == .group`, no `groupId`) always selects/drags the whole group directly.
    private var pressAndMoveGesture: some Gesture {
        // Canvas space sits outside WorldLayer.scaleEffect — translation stays in screen points.
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if !pressBegan {
                    pressBegan = true
                    app.menu = nil
                    pressShiftAtStart = NSEvent.modifierFlags.contains(.shift)
                    if pressShiftAtStart, card.kind == .group {
                        pressGroupMarquee = true
                        pressTargetID = card.id
                        pressWasSelected = app.selectedIDs.contains(card.id)
                    } else if pressShiftAtStart {
                        pressTargetID = card.id
                        pressWasSelected = app.selectedIDs.contains(card.id)
                        if let gid = card.groupId, app.selectedIDs.contains(gid) {
                            // The whole group was selected — break out into a per-member
                            // pick starting with this one, instead of appending to a
                            // selection that still expands back to every sibling.
                            app.select([card.id])
                        } else {
                            app.toggleSelect(card.id)
                        }
                    } else if let gid = card.groupId {
                        // Group-first selection (Illustrator/Keynote/Figma contract): a plain
                        // click on a member selects the whole group. Only once the group is
                        // already the selection does the *next* click drill into this one
                        // member — so what's highlighted always matches what a drag (or
                        // Delete) will act on; no separate escalation needed once dragging.
                        pressWasSelected = app.selectedIDs.contains(card.id)
                        if app.selectedIDs.contains(gid) {
                            pressTargetID = card.id
                            app.select([card.id])
                        } else if app.selectedIDs == [card.id] {
                            // Already drilled into this member — a re-click keeps it narrowed.
                            pressTargetID = card.id
                        } else {
                            pressTargetID = gid
                            app.select([gid])
                        }
                    } else {
                        pressTargetID = card.id
                        pressWasSelected = app.selectedIDs.contains(card.id)
                        if !pressWasSelected {
                            app.select([card.id])
                        }
                    }
                }

                let moved = hypot(value.translation.width, value.translation.height)

                if pressGroupMarquee {
                    guard moved >= 6, let cam = app.activeLesson?.camera else { return }
                    let zoom = max(cam.zoom, 0.01)
                    func toWorld(_ p: CGPoint) -> CGPoint {
                        CGPoint(x: (p.x - cam.x) / zoom, y: (p.y - cam.y) / zoom)
                    }
                    let a = toWorld(value.startLocation)
                    let b = toWorld(value.location)
                    let rect = CGRect(
                        x: min(a.x, b.x), y: min(a.y, b.y),
                        width: abs(a.x - b.x), height: abs(a.y - b.y)
                    )
                    let lesson = app.activeLesson
                    app.select(
                        (lesson?.cards ?? [])
                            .filter { $0.kind != .group && $0.frame.intersects(rect) }
                            .map(\.id),
                        playSound: false
                    )
                    return
                }

                guard moved >= 6 else { return }

                guard let cam = app.activeLesson?.camera else { return }
                let zoom = max(cam.zoom, 0.01)
                let pointer = CGPoint(
                    x: (value.location.x - cam.x) / zoom,
                    y: (value.location.y - cam.y) / zoom
                )

                if !didPushMove {
                    app.pushUndo()
                    didPushMove = true
                    // Selection was already decided on press (group-first, or drilled to this
                    // member) — a drag just moves whatever ended up selected, no escalation.
                    if !app.selectedIDs.contains(pressTargetID) {
                        app.select([pressTargetID])
                    }
                    moveOrigins = Dictionary(uniqueKeysWithValues: app.idsMoving(with: app.selectedIDs).compactMap { id -> (String, CGPoint)? in
                        guard let c = app.card(id) else { return nil }
                        return (id, CGPoint(x: c.x, y: c.y))
                    })
                    // Anchor to the pointer now — card stays under the cursor from this moment.
                    pointerOrigin = pointer
                    moveAxis = nil
                    app.beginGroupDrag(ids: Array(moveOrigins.keys))
                }

                var tx = pointer.x - pointerOrigin.x
                var ty = pointer.y - pointerOrigin.y
                // Only axis-lock on a shift that was pressed mid-drag — a shift held from
                // before the press already did its job (member-select) at press-start.
                if NSEvent.modifierFlags.contains(.shift), !pressShiftAtStart {
                    if moveAxis == nil {
                        moveAxis = abs(tx) >= abs(ty) ? .horizontal : .vertical
                    }
                    if moveAxis == .horizontal { ty = 0 } else { tx = 0 }
                } else {
                    moveAxis = nil
                }
                let snapX = moveAxis != .vertical
                let snapY = moveAxis != .horizontal
                app.moveCardsFromOrigins(moveOrigins, tx: tx, ty: ty, allowSnapX: snapX, allowSnapY: snapY)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                // Always clear guides — gesture can cancel after snap lines were drawn.
                app.clearSnapGuides()
                if pressGroupMarquee {
                    // Shift+group plaque never selects the group itself — plain click (no
                    // drag) does nothing; a real drag already applied its marquee selection live.
                } else if didPushMove {
                    app.endGroupDrag()
                    app.reconcileGroups(afterMoving: Array(moveOrigins.keys))
                    app.snapSelected()
                    app.saveNow()
                } else if moved < 6,
                          pressWasSelected,
                          card.kind == .text,
                          app.editingID != card.id,
                          app.selectedIDs.count > 1
                {
                    // A click with no drag on a text card that was already part of a multi-select:
                    // narrow to just this card. A single click never enters text editing — only a
                    // double-click does (see the TapGesture below) — so any click on a text block,
                    // alone or in a multi-select, behaves like a normal block you can then drag.
                    app.select([card.id])
                    app.menu = nil
                } else if moved < 6, card.kind == .group, let cam = app.activeLesson?.camera {
                    let zoom = max(cam.zoom, 0.01)
                    let world = CGPoint(
                        x: (value.startLocation.x - cam.x) / zoom,
                        y: (value.startLocation.y - cam.y) / zoom
                    )
                    let title = CGRect(x: card.x + 10, y: card.y + 8, width: 168, height: 28)
                    if title.contains(world) {
                        app.beginGroupRename(card.id)
                    }
                }
                moveAxis = nil
                moveOrigins = [:]
                pointerOrigin = .zero
                didPushMove = false
                pressBegan = false
                pressWasSelected = false
                pressTargetID = ""
                pressShiftAtStart = false
                pressGroupMarquee = false
            }
    }

    private func open(at point: CGPoint? = nil) {
        switch card.kind {
        case .note: app.openNoteEditor(card.id)
        case .text: app.beginTextEditing(cardID: card.id, at: point)
        case .audio: app.audioDetailID = card.id
        case .image: app.lightbox = LightboxItem(src: card.src ?? "", alt: card.alt, bytes: Theme.fileBytes(card.src ?? ""))
        case .link: if let url = card.url { app.openExternal(url) }
        case .shortcut: if let path = card.targetPath, card.missing != true { app.openPath(path) }
        default: break
        }
    }
}

private struct CardClip: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        if radius < 0 {
            content
        } else {
            content.clipShape(CardRoundedRect(radius: radius))
        }
    }
}

private struct CardComposite: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.compositingGroup()
        } else {
            content
        }
    }
}

struct TextCardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let card: Card
    private var writing: Bool { app.editingID == card.id }

    var body: some View {
        let ink: NSColor = {
            if let hex = card.color { return NSColor.vasa(hex: hex) }
            return Theme.defaultInkNSColor(scheme)
        }()
        // Keep one NSTextView across select↔edit so text never remount-flashes.
        CanvasTextEditor(
            html: card.html,
            plain: card.body ?? card.html,
            fontSize: card.fontSize ?? 16,
            ink: ink,
            editing: writing,
            pendingCaret: app.pendingTextCaret?.cardID == card.id ? app.pendingTextCaret?.point : nil,
            onConsumeCaret: { app.pendingTextCaret = nil },
            suppressAutoResize: app.isResizingCard(card.id),
            isFormatChromeActive: { app.formatBarHovered || app.showsTextFormatBar },
                    onChange: { html, plain, size in
                        let empty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let resizing = app.isResizingCard(card.id)
                        // ☐ and ☑ can have very slightly different glyph advance widths in the
                        // system font, which nudges the measured content size by a pixel or two
                        // and — since the card auto-fits its frame to that size on every change —
                        // made checking a box visibly resize the whole card. A toggle changes no
                        // actual content, so skip the content-fit recompute for it entirely.
                        let markToggleOnly = Self.isTodoMarkToggleOnly(from: card.body, to: plain)
                        app.updateCard(card.id, persist: false) {
                            $0.html = html
                            $0.body = plain
                            // Ticket G: corner-drag owns width/height — skip content-fit.
                            guard !resizing, !markToggleOnly else { return }
                            let seed = TextToolReducer.defaultSize
                            let wrapCap = Double(GrowingTextView.preferredWrapWidth)
                            let chrome = Double(GrowingTextView.chromeGap * 2)
                            // Border hugs longest line; soft-wrap only at wrapCap (screenshot-2 block).
                            let contentW = min(wrapCap, Double(ceil(size.width)))
                            let contentH = Double(ceil(size.height))
                            if empty {
                                $0.width = seed.width + chrome
                                $0.height = seed.height + chrome
                            } else {
                                $0.width = max(36, contentW + chrome)
                                $0.height = max(seed.height + chrome, contentH + chrome)
                            }
                        }
                    },
            onBeginEditing: {
                app.beginTextEditing(cardID: card.id)
            },
            onEndEditing: {
                app.stopEditingText()
            },
            onSelectionChange: { range, screenRect in
                app.updateTextSelection(range: range, screenRect: screenRect)
            },
            onBind: { app.activeCanvasTextView = $0 }
        )
        .padding(GrowingTextView.chromeGap)
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .background(Color.clear)
        .overlay {
            if writing {
                // Same cut-out notch as other cards (resize hit target lives on CardSelection).
                SelectionFrame(
                    radius: 8,
                    outset: 0,
                    notched: true,
                    zoom: CGFloat(app.activeLesson?.camera.zoom ?? 1)
                )
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            repairNarrowTextIfNeeded()
            healTrailingNewlineIfNeeded()
            hugToContentIfNeeded()
        }
        .onChange(of: writing) { _, isWriting in
            if !isWriting { hugToContentIfNeeded() }
        }
        .onChange(of: app.resizingCardID) { was, now in
            // After corner-scale, re-hug so empty padding from the gesture doesn't stick.
            if was == card.id, now == nil {
                hugToContentIfNeeded(force: true)
            }
        }
        .onChange(of: card.fontSize) { _, _ in
            guard !writing, !app.isResizingCard(card.id) else { return }
            hugToContentIfNeeded()
        }
        .onChange(of: card.body) { _, _ in
            guard !writing else { return }
            hugToContentIfNeeded()
        }
        .onChange(of: card.html) { _, _ in
            guard !writing else { return }
            hugToContentIfNeeded()
        }
    }

    private func toggleTodo(at utf16: Int) {
        let displayed = CanvasTextEditor.attributed(
            html: card.html,
            plain: card.body ?? card.html,
            size: card.fontSize ?? 16,
            ink: card.color.map { NSColor.vasa(hex: $0) } ?? Theme.defaultInkNSColor(scheme)
        ).string
        guard let next = TodoMarks.toggle(plain: displayed, html: card.html, at: utf16) else { return }
        let checked = (next.plain as NSString).character(at: utf16) == TodoMarks.checked
        AppSounds.playToggle(checked)
        app.updateCard(card.id) {
            $0.body = next.plain
            $0.html = next.html
        }
    }

    /// Drop a stale Cocoa trailing `\n` saved into `body` before hug/measure.
    private func healTrailingNewlineIfNeeded() {
        guard let body = card.body, body != CanvasTextEditor.normalizedPlain(body) else { return }
        let cleaned = CanvasTextEditor.normalizedPlain(body)
        app.updateCard(card.id, persist: false) {
            $0.body = cleaned
        }
    }

    /// Refit width + height to the text (fixes leftover empty selection after font bumps).
    private func hugToContentIfNeeded(force: Bool = false) {
        guard force || !app.isResizingCard(card.id) else { return }
        let fontSize = card.fontSize ?? 16
        let attr = CanvasTextEditor.attributed(
            html: card.html,
            plain: card.body ?? card.html,
            size: fontSize,
            ink: card.color.map { NSColor.vasa(hex: $0) } ?? Theme.defaultInkNSColor(scheme)
        )
        let hug = CanvasTextEditor.hugSize(for: attr)
        // chromeGap is outside the editor measure — keep the card big enough for padding.
        let pad = Double(GrowingTextView.chromeGap * 2)
        let nextW = Double(hug.width) + pad
        let nextH = Double(hug.height) + pad
        guard abs(nextW - card.width) > 0.5 || abs(nextH - card.height) > 0.5 else { return }
        app.updateCard(card.id, persist: false) {
            $0.width = nextW
            $0.height = nextH
        }
    }

    /// Old boxed saves left tall skinny frames — open them up to a readable wrap width.
    private func repairNarrowTextIfNeeded() {
        let plain = card.body ?? ""
        guard plain.count > 40, card.width < 280 else { return }
        let wrap = min(GrowingTextView.preferredWrapWidth, 480)
        let lines = max(2, Int(ceil(Double(plain.count) / 56)))
        app.updateCard(card.id, persist: false) {
            $0.width = Double(wrap)
            $0.height = max(card.height, Double(lines) * 22)
            if let html = $0.html {
                $0.html = CanvasTextEditor.htmlFragment(html)
            }
            if let body = $0.body, body.contains("<!DOCTYPE") || body.contains("<html") {
                $0.body = CanvasTextEditor.plainText(html: body, fallback: plain)
            }
        }
    }

    /// True when `to` differs from `from` only in which ☐/☑ characters are present at
    /// the same positions — i.e. a checkbox toggle with no other text change.
    fileprivate static func isTodoMarkToggleOnly(from: String?, to: String) -> Bool {
        guard let from, from.utf16.count == to.utf16.count else { return false }
        let fromChars = Array(from.utf16)
        let toChars = Array(to.utf16)
        var sawDifference = false
        for i in 0..<fromChars.count where fromChars[i] != toChars[i] {
            guard TodoMarks.isMark(fromChars[i]), TodoMarks.isMark(toChars[i]) else { return false }
            sawDifference = true
        }
        return sawDifference
    }
}

private struct TextRichPreview: View {
    let html: String?
    let plain: String?
    let fontSize: CGFloat
    var inkHex: String = "#111318"
    var onToggleTodo: ((Int) -> Void)?

    var body: some View {
        let attributed = CanvasTextEditor.attributed(
            html: html,
            plain: plain,
            size: fontSize,
            ink: NSColor.vasa(hex: inkHex)
        )
        // NSTextView keeps attributed foreground colors (SwiftUI Text often drops them).
        TextRichPreviewRepresentable(attributed: attributed, onToggleTodo: onToggleTodo)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity((plain?.isEmpty == false || html?.isEmpty == false) ? 1 : 0.35)
    }
}

/// Non-editable preview that still accepts clicks on ☐/☑; other hits pass through to the card.
private final class TodoPreviewTextView: NSTextView {
    var onToggleTodo: ((Int) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        TodoMarks.checkboxUTF16Index(in: self, at: point) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let idx = TodoMarks.checkboxUTF16Index(in: self, at: point) {
            onToggleTodo?(idx)
            return
        }
        super.mouseDown(with: event)
    }

    /// Match GrowingTextView: wrap in width, never truncate to a single line with "…".
    override func layout() {
        super.layout()
        syncWrapContainer()
    }

    func syncWrapContainer() {
        guard let container = textContainer else { return }
        container.widthTracksTextView = false
        container.lineBreakMode = .byWordWrapping
        let width = max(bounds.width, 12)
        let tall = CGFloat.greatestFiniteMagnitude
        if abs(container.containerSize.width - width) > 0.5
            || container.containerSize.height < tall / 2
        {
            container.containerSize = NSSize(width: width, height: tall)
        }
    }
}

private struct TextRichPreviewRepresentable: NSViewRepresentable {
    let attributed: NSAttributedString
    var onToggleTodo: ((Int) -> Void)?

    func makeNSView(context: Context) -> TodoPreviewTextView {
        let view = TodoPreviewTextView()
        view.textContainer?.replaceLayoutManager(TodoAwareLayoutManager())
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // Same wrap model as the editor — width-capped, height unlimited (no tail truncation).
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.textContainer?.containerSize = NSSize(
            width: GrowingTextView.preferredWrapWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.defaultParagraphStyle = GrowingTextView.wrappingParagraphStyle
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width, .height]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.clipsToBounds = true
        view.onToggleTodo = onToggleTodo
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: TodoPreviewTextView, context: Context) {
        view.onToggleTodo = onToggleTodo
        if !view.attributedString().isEqual(to: attributed) {
            view.textStorage?.setAttributedString(attributed)
        }
        view.syncWrapContainer()
    }
}

struct NoteCardView: View {
    @Environment(\.colorScheme) private var scheme
    let card: Card
    private var bodyText: String {
        CanvasTextEditor.plainText(html: card.html, fallback: card.body)
    }
    private var words: Int { Format.wordCount(bodyText) }

    var body: some View {
        let fill = card.color.map { Theme.color($0) } ?? Theme.cardSurface(scheme)
        // Contrast against the actual tint's luminance, not a hardcoded white — a light
        // swatch (yellow, mint, sky) needs dark text just like it does everywhere else
        // Theme.onFill is used.
        let ink: Color = card.color == nil ? Theme.primaryInk(scheme) : Theme.onFill(card.color)
        let kicker = ink.opacity(0.7)
        let chipFill = card.color == nil
            ? Theme.elevHover(scheme)
            : ink.opacity(0.18)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kicker)
                Text("Note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(kicker)
            }
            Text(bodyText.isEmpty ? "Empty note" : bodyText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(ink.opacity(bodyText.isEmpty ? 0.45 : 1))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            Text("\(words) \(words == 1 ? "word" : "words")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(chipFill, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
        .overlay {
            if card.color == nil {
                CardRoundedRect(radius: Format.cardRadius)
                    .strokeBorder(Theme.cardBorder(scheme), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.04), radius: 8, y: 2)
    }
}

struct ImageCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(src: card.src ?? "")
                    .scaledToFill()
            }
            .clipShape(CardRoundedRect(radius: Format.cardRadius))
            .compositingGroup()
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .task(id: card.src) {
                await app.fitImageCard(card.id)
            }
    }
}

struct LinkCardView: View {
    let card: Card
    private var radius: CGFloat { card.showsRichLink ? Format.cardBorderedRadius : Format.cardRadius }
    private var fillHex: String { card.color ?? "#FF3B30" }

    var body: some View {
        Group {
            if card.showsRichLink {
                richBody
            } else {
                chipBody
            }
        }
        .clipShape(CardRoundedRect(radius: radius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private var chipBody: some View {
        let ink = Theme.onFill(fillHex)
        return VStack(alignment: .leading, spacing: 4) {
            Text(card.title ?? card.linkSubtitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(card.hostname ?? card.linkSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.color(fillHex))
    }

    private var richBody: some View {
        let fill = Theme.color(fillHex)
        let ink = Theme.onFill(fillHex)
        let hasImage = !(card.image ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .overlay {
                    if hasImage {
                        RemoteImage(src: card.image ?? "")
                            .scaledToFill()
                    } else {
                        // Gray stub while Open Graph / remote preview loads.
                        Rectangle()
                            .fill(Color(white: 0.88))
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(card.linkSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill)
    }
}

struct AudioCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var playing: Bool { app.playingID == card.id && !app.playbackPaused }
    var selected: Bool { app.selectedIDs.contains(card.id) }
    private var playback: Playback { Playback.shared }
    private var active: Bool { app.playingID == card.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformView(
                peaks: card.peaks ?? DemoLibrary.peaks,
                progress: active ? playback.progress : 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            HStack(alignment: .center, spacing: 10) {
                PlayControl(playing: playing, size: 36) { app.togglePlay(card.id) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title?.isEmpty == false ? card.title! : "Sound")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(.black.opacity(0.2), in: Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Theme.color(card.color ?? "#34C759"))
        .overlay {
            if selected {
                CardRoundedRect(radius: Format.cardRadius - 3)
                    .strokeBorder(.white, lineWidth: 2)
                    .padding(3)
                CardRoundedRect(radius: Format.cardRadius)
                    .strokeBorder(.white.opacity(0.95), lineWidth: 2)
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private var timeLabel: String {
        if active {
            return Format.duration(playback.currentSeconds)
        }
        return card.duration?.isEmpty == false ? card.duration! : "0:00"
    }
}

struct WaveformView: View {
    let peaks: [Double]
    var progress: Double = 0
    var onSeek: ((Double) -> Void)?
    var dragToSeek = false

    var body: some View {
        GeometryReader { geo in
            let n = max(peaks.count, 1)
            let gap: CGFloat = 2.4
            let bar = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let playhead = geo.size.width * CGFloat(min(1, max(0, progress)))
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(peaks.enumerated()), id: \.offset) { i, p in
                        let lit = CGFloat(i) / CGFloat(n) * geo.size.width <= playhead
                        Capsule()
                            .fill(.white.opacity(lit && playhead > 1 ? 1 : 0.78))
                            .frame(width: bar, height: max(6, p * min(56, geo.size.height)))
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                if playhead > 1 {
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: min(56, geo.size.height))
                        .offset(x: playhead)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(dragToSeek)
            .contentShape(Rectangle())
            .modifier(WaveformSeekDrag(enabled: dragToSeek) { x in
                seek(x, width: geo.size.width)
            })
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        seek(value.location.x, width: geo.size.width)
                    }
            )
        }
    }

    private func seek(_ x: CGFloat, width: CGFloat) {
        guard width > 0, NSEvent.pressedMouseButtons != 2 else { return }
        onSeek?(min(1, max(0, Double(x / width))))
    }
}

private struct WaveformSeekDrag: ViewModifier {
    var enabled: Bool
    var onSeek: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard NSEvent.pressedMouseButtons == 1 else { return }
                        onSeek(value.location.x)
                    }
            )
        } else {
            content
        }
    }
}

struct VideoCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var playing: Bool { app.playingID == card.id }
    private var selected: Bool { app.selectedIDs.contains(card.id) }

    var body: some View {
        ZStack {
            if playing, Playback.shared.lastError == nil, let player = Playback.shared.videoPlayer {
                // Hand-rolled AVPlayerLayer view instead of AVKit's VideoPlayer: the SwiftUI
                // VideoPlayer wrapper (_AVKit_SwiftUI) crashes on this OS/SDK the instant it's
                // instantiated (Swift runtime metadata fatal error). Native controls were
                // already disabled here anyway — the canvas owns play/pause via PlayControl.
                VideoPlayerLayerView(player: player)
            } else {
                Color.black.opacity(0.08)
                    .overlay {
                        if let poster = card.poster, !poster.isEmpty {
                            RemoteImage(src: poster).scaledToFill()
                        } else {
                            GhostPlaceholder()
                        }
                    }
                if let err = Playback.shared.lastError, playing {
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if !playing || Playback.shared.lastError != nil {
                PlayControl(playing: false, large: false) { app.togglePlay(card.id) }
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else if selected {
                PlayControl(playing: true, large: false) { app.togglePlay(card.id) }
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(CardRoundedRect(radius: Format.cardRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

/// Minimal AVPlayerLayer-backed view. Deliberately avoids AVKit's `VideoPlayer` SwiftUI
/// wrapper, whose private `_AVKit_SwiftUI` backing crashes on this OS/SDK.
struct VideoPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

struct ShortcutCardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let card: Card

    var body: some View {
        let missing = card.missing == true || missingOnDisk
        VStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)
            Text(card.title ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(missing ? Theme.secondaryInk(scheme) : Theme.onFill(card.color ?? "#C6FF3A"))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if missing {
                Text("Not found")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk(scheme))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(missing ? Theme.cardSurface(scheme) : Theme.color(card.color ?? "#C6FF3A"))
        .overlay {
            CardRoundedRect(radius: Format.cardRadius)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.95), lineWidth: 1.5)
        }
        .task { await refreshMissing() }
    }

    private var missingOnDisk: Bool {
        guard let path = card.targetPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private var icon: NSImage {
        if let path = card.targetPath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(forFileType: "public.folder")
    }

    private func refreshMissing() async {
        guard let path = card.targetPath else { return }
        let ok = FileManager.default.fileExists(atPath: path)
        if ok == !(card.missing ?? false) { return }
        app.updateCard(card.id) { $0.missing = !ok }
    }
}

struct GroupCardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let card: Card
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    private var renaming: Bool { app.editingGroupID == card.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Format.groupRadius, style: .continuous)
                .fill(Theme.groupFill(scheme, tint: card.color))
            Group {
                if renaming {
                    TextField("Group", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryInk(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Theme.cardSurface(scheme).opacity(0.92),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .focused($titleFocused)
                        .onSubmit { app.commitGroupRename(card.id, title: draft) }
                        .onExitCommand { app.commitGroupRename(card.id, title: draft) }
                } else {
                    Text(card.title?.isEmpty == false ? card.title! : "Group")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.groupTitle(scheme, tint: card.color))
                }
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            .frame(maxWidth: 220, alignment: .leading)
        }
        .onChange(of: renaming) { _, on in
            if on {
                draft = card.title ?? "Group"
                DispatchQueue.main.async { titleFocused = true }
            } else {
                titleFocused = false
            }
        }
        .onChange(of: titleFocused) { _, focused in
            if renaming, !focused {
                app.commitGroupRename(card.id, title: draft)
            }
        }
    }
}

struct DrawCardView: View {
    let card: Card
    var body: some View {
        Canvas { context, _ in
            for stroke in card.inkStrokes {
                guard let first = stroke.points.first else { continue }
                var path = Path()
                path.move(to: CGPoint(x: first.x, y: first.y))
                for p in stroke.points.dropFirst() {
                    path.addLine(to: CGPoint(x: p.x, y: p.y))
                }
                let width = max(1, stroke.width)
                context.stroke(
                    path,
                    with: .color(Theme.color(stroke.color)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

struct YouTubeCardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var playing: Bool { app.playingID == card.id }

    var body: some View {
        ZStack {
            if playing, let id = card.videoId {
                YouTubeEmbed(videoID: id, autoplay: true)
            } else {
                Color.black
                    .overlay {
                        RemoteImage(src: "https://img.youtube.com/vi/\(card.videoId ?? "")/hqdefault.jpg")
                            .scaledToFill()
                    }
                PlayControl(playing: false, large: true) { app.setPlaying(card.id) }
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(CardRoundedRect(radius: Format.cardRadius))
        .compositingGroup()
    }
}

struct PlayControl: View {
    @Environment(\.colorScheme) private var scheme
    var playing: Bool
    var large = false
    var size: CGFloat?
    var action: () -> Void

    private var side: CGFloat { size ?? (large ? 44 : 36) }

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: side > 36 ? 15 : 12, weight: .semibold))
                .foregroundStyle(scheme == .dark ? Color.white : Theme.ink)
                .offset(x: playing ? 0 : 1)
                .frame(width: side, height: side)
                .background(scheme == .dark ? Color(red: 0.28, green: 0.28, blue: 0.30) : Color.white, in: Circle())
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct RemoteImage: View {
    let src: String
    var contentMode: ContentMode = .fill
    @State private var localImage: NSImage?

    var body: some View {
        Group {
            if src.hasPrefix("http://") || src.hasPrefix("https://"), let url = URL(string: src) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
                    default:
                        GhostPlaceholder()
                    }
                }
            } else if let localImage {
                Image(nsImage: localImage).resizable().aspectRatio(contentMode: contentMode)
            } else {
                GhostPlaceholder()
                    .task(id: src) {
                        // 2x maxSide covers the card's rendered size at typical zoom/Retina
                        // without paying for a full-res decode of the source photo.
                        localImage = await ImageMedia.loadThumbnail(src: src, maxPixelSize: ImageMedia.maxSide * 2)
                    }
            }
        }
    }

    func resizable() -> RemoteImage { self }
    func scaledToFit() -> RemoteImage { RemoteImage(src: src, contentMode: .fit) }
    func scaledToFill() -> RemoteImage { RemoteImage(src: src, contentMode: .fill) }
}

struct GhostPlaceholder: View {
    @State private var pulse = false
    var body: some View {
        CardRoundedRect(radius: 12)
            .fill(Color(white: 0.88))
            .overlay {
                CardRoundedRect(radius: 12)
                    .fill(Color.white.opacity(pulse ? 0.45 : 0.12))
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// YouTube Error 153 (“Video player configuration error”) happens when WKWebView
/// navigates straight to `/embed/…` without a Referer. Load a tiny HTML shell
/// with a real HTTPS baseURL so the iframe request carries a valid origin.
struct YouTubeEmbed: NSViewRepresentable {
    let videoID: String
    var autoplay: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedID != videoID {
            load(into: view, coordinator: context.coordinator)
        }
    }

    final class Coordinator {
        var loadedID: String?
    }

    private func load(into view: WKWebView, coordinator: Coordinator) {
        let html = Self.pageHTML(videoID: videoID, autoplay: autoplay)
        // HTTPS origin is required — file:// / about:blank → Error 153.
        view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com")!)
        coordinator.loadedID = videoID
    }

    static func pageHTML(videoID: String, autoplay: Bool) -> String {
        let safe = videoID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let auto = autoplay ? "1" : "0"
        let src = "https://www.youtube-nocookie.com/embed/\(safe)?playsinline=1&rel=0&modestbranding=1&autoplay=\(auto)"
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta name="referrer" content="strict-origin-when-cross-origin">
          <style>
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
            iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
          </style>
        </head>
        <body>
          <iframe
            src="\(src)"
            title="YouTube"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            referrerpolicy="strict-origin-when-cross-origin"
            allowfullscreen
          ></iframe>
        </body>
        </html>
        """
    }
}

struct WebEmbed: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }
}
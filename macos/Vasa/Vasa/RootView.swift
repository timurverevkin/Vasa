import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var keyMonitor: Any?
    // Measured lazily via BoardMenuSizeKey — stays nil until first render so the
    // menu never clamps against a guessed size and momentarily overflows the window.
    @State private var boardMenuSize: CGSize?

    // Chip retreats fast on open (out of the sidebar's way); sidebar springs in
    // right behind it, native-HIG feel. On close the sidebar snaps back first,
    // then the chip settles in a beat later.
    private static let chipTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity)
            .animation(.spring(response: 0.32, dampingFraction: 0.88).delay(0.08)),
        removal: .move(edge: .leading).combined(with: .opacity)
            .animation(.easeIn(duration: 0.1))
    )
    private static let sidebarTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity)
            .animation(.spring(response: 0.36, dampingFraction: 0.86).delay(0.06)),
        removal: .move(edge: .leading).combined(with: .opacity)
            .animation(.easeIn(duration: 0.16))
    )

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasView()
            if app.library.sidebarOpen {
                if app.settingsOpen {
                    SettingsView()
                        .padding(10)
                        .zIndex(600)
                        .contentShape(Rectangle())
                        .transition(Self.sidebarTransition)
                } else {
                    SidebarView()
                        .padding(10)
                        .zIndex(600)
                        .contentShape(Rectangle())
                        .transition(Self.sidebarTransition)
                }
            } else if app.settings.showChrome {
                ProjectChip()
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .zIndex(600)
                    .transition(Self.chipTransition)
            }
            if let id = app.boardMenuID, let lesson = app.library.lessons.first(where: { $0.id == id }) {
                GeometryReader { geo in
                    let margin: CGFloat = 10
                    let size = boardMenuSize ?? .zero
                    let maxX = max(margin, geo.size.width - size.width - margin)
                    let visibleHeight = AppModel.visibleChromeHeight(fallback: geo.size.height)
                    let maxY = max(margin, visibleHeight - size.height - margin)
                    let x = min(max(270, margin), maxX)
                    let y = min(max(app.boardMenuY, margin), maxY)
                    BoardMenuCard(lesson: lesson)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: BoardMenuSizeKey.self, value: proxy.size)
                            }
                        )
                        .onPreferenceChange(BoardMenuSizeKey.self) { boardMenuSize = $0 }
                        .offset(x: x, y: y)
                        .opacity(boardMenuSize == nil ? 0 : 1)
                        .zIndex(650)
                }
            }
            if app.paletteOpen { CommandPalette().zIndex(700) }
            if let item = app.lightbox { LightboxView(item: item).zIndex(700) }
            if app.audioDetailID != nil { AudioDetailView().zIndex(700) }
            if app.linkPrompt { LinkPrompt().zIndex(700) }
            if app.aiArrangePromptOpen { ArrangeAIPrompt().zIndex(705) }
            if app.providerSettingsOpen { ProviderSettingsPanel().zIndex(720) }
            if let menu = app.menu { ItemMenuOverlay(anchor: menu).zIndex(700) }
            ProjectWave(token: app.boardWave)
                .allowsHitTesting(false)
                .zIndex(50)
            if app.askAICardID != nil {
                ChatPanel()
                    .zIndex(750)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasColor(app.settings.appearance.colorScheme ?? scheme))
        .ignoresSafeArea()
        .background(HiddenTrafficLights())
        .preferredColorScheme(app.settings.appearance.colorScheme)
        // Keep chrome out of the ZStack hit pyramid — full-frame wrappers were eating
        // sidebar clicks (search / settings / toggles felt delayed or dead).
        .overlay(alignment: .topLeading) {
            if app.tool == .draw, app.settings.showChrome, app.noteOpenID == nil {
                DrawInkBar()
                    .padding(.top, 14)
                    .padding(.leading, app.library.sidebarOpen ? 276 : 14)
                    .zIndex(800)
            }
        }
        .overlay(alignment: .topTrailing) {
            if app.settings.showChrome, app.noteOpenID == nil {
                ZoomControls()
                    .padding(.top, app.library.sidebarOpen ? 10 : 14)
                    .padding(.trailing, 14)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if app.settings.showChrome, app.navigatorOpen {
                MinimapView()
                    .padding(.leading, app.library.sidebarOpen ? 276 : 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay(alignment: .top) {
            // Physically start after left chrome so close / panel buttons never sit under the strip.
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: app.library.sidebarOpen ? 280 : 40)
                    .allowsHitTesting(false)
                WindowMoveStrip(leadingReserve: 0, trailingReserve: 120)
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
            }
            .frame(height: 14)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .overlay {
            if app.noteOpenID != nil {
                NoteEditorLayer()
                    .allowsHitTesting(true)
            }
        }
        .onAppear {
            HiddenTrafficLights.apply(NSApp.keyWindow)
            installKeys()
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .rightMouseDown, .leftMouseUp]) { event in
            if event.type == .rightMouseDown {
                FieldEditor.silenceSystemTextUI()
                guard let window = event.window else { return nil }
                let loc = event.locationInWindow
                let size = window.contentView?.bounds.size ?? .zero
                let point = CGPoint(x: loc.x, y: size.height - loc.y)
                _ = app.openContextMenu(at: point, in: CGSize(width: size.width, height: size.height))
                return nil
            }
            if event.type == .leftMouseUp {
                // Safety net: SwiftUI's DragGesture has no cancel callback, so a resize
                // gesture interrupted mid-drag (window resigns key, a higher-priority
                // gesture wins, the view is torn down) can leave `resizingCardID` stuck
                // forever — the card would silently stop auto-fitting its content. Any
                // mouse-up anywhere, even one the drag gesture itself never sees, clears it.
                if app.resizingCardID != nil {
                    app.endCardResize()
                }
                return event
            }
            return handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let typing = isTyping
        if event.type == .keyUp, event.keyCode == 49 {
            app.spaceDown = false
            return false
        }
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)

        if event.keyCode == 49, !typing {
            if let id = app.selectedIDs.first, let card = app.card(id) {
                if card.kind == .image, let src = card.src {
                    app.lightbox = LightboxItem(src: src, alt: card.alt, bytes: Theme.fileBytes(src))
                    return true
                }
                if card.kind == .video, let poster = card.poster {
                    app.lightbox = LightboxItem(src: poster, alt: card.title, videoSrc: card.src)
                    return true
                }
            }
            app.spaceDown = true
            return true
        }
        if event.keyCode == 53 {
            if app.handleTextToolEscape() { return true }
            app.dismissOverlays()
            return true
        }
        // Tab hides chrome only when not in a text field — while typing, pass through
        // so focus / indent inside GrowingTextView & note editor keep working.
        if event.keyCode == 48, !typing {
            app.settings.showChrome.toggle()
            return true
        }
        // ` — toggle navigator / minimap
        if event.keyCode == 50, !typing, !cmd {
            app.navigatorOpen.toggle()
            AppSounds.play(app.navigatorOpen ? .transitionUp : .transitionDown)
            AppHaptics.perform(.generic)
            return true
        }

        // ⌘⌥S — macOS sidebar alternate (Finder/Mail/Notes); ⌘\ remains via menu.
        if cmd, flags.contains(.option), !shift, event.keyCode == 1, !typing {
            app.toggleSidebar()
            return true
        }

        // Layer shortcuts work for every block even while a text field has focus.
        if cmd {
            switch event.keyCode {
            case 30: // ⌘]
                app.layer(1)
                return true
            case 33: // ⌘[
                app.layer(-1)
                return true
            default:
                break
            }
        }

        if typing { return false }

        if event.keyCode == 51 || event.keyCode == 117 {
            app.deleteSelected()
            return true
        }

        // Physical keyCodes (US QWERTY) — same keys on Latin and Russian layouts.
        if !cmd {
            switch event.keyCode {
            case 3: // F
                app.pickFiles(); return true
            case 17: // T
                app.tool = app.tool == .text ? .select : .text
                return true
            case 37: // L
                app.linkPrompt = true; return true
            case 35: // P
                app.tool = app.tool == .draw ? .select : .draw
                return true
            case 45: // N
                app.insertBlankNote(); return true
            case 1: // S
                return true
            case 0: // A — photo/link image → Google Lens; text/note → Ask AI
                if let id = app.selectedIDs.first, let card = app.card(id) {
                    if card.kind == .image {
                        app.openLens(card.src)
                        return true
                    }
                    if card.kind == .link, let image = card.image {
                        app.openLens(image)
                        return true
                    }
                }
                if !app.selectedTextCardIDs().isEmpty {
                    app.askAbout(app.selectedTextCardIDs().first)
                    return true
                }
                return false
            default:
                break
            }
        }

        if cmd {
            switch event.keyCode {
            case 5: // ⌘G
                if shift {
                    app.ungroupSelection()
                } else {
                    app.groupSelection()
                }
                return true
            case 0: // ⌘A — select all cards (menu also routes here when not typing)
                app.selectAllCards()
                return true
            case 17: // ⌘T
                let all = AppSettings.Appearance.allCases
                if let i = all.firstIndex(of: app.settings.appearance) {
                    app.settings.appearance = all[(i + 1) % all.count]
                }
                return true
            case 38: // ⌘J — open AI chat
                app.openAIChat()
                return true
            case 46: // ⌘M
                let next = !app.settings.sounds
                if next {
                    app.settings.sounds = true
                    AppSounds.playToggle(true)
                } else {
                    AppSounds.playToggle(false)
                    app.settings.sounds = false
                }
                return true
            case 1: // ⌘S
                app.settings.snapping.toggle()
                AppSounds.playToggle(app.settings.snapping)
                AppHaptics.perform(.generic)
                return true
            case 24: // ⌘= / ⌘+
                zoom(1.15)
                return true
            case 27: // ⌘-
                zoom(1 / 1.15)
                return true
            case 29: // ⌘0
                zoom(to: 1)
                return true
            default:
                break
            }
        }

        let step: Double = shift ? 80 : 8
        switch event.keyCode {
        case 123: app.nudge(-step, 0); return true
        case 124: app.nudge(step, 0); return true
        case 126: app.nudge(0, -step); return true
        case 125: app.nudge(0, step); return true
        default: return false
        }
    }

    private var isTyping: Bool {
        // App state, not just the responder chain — a text card can be marked
        // `editingID` a frame before its NSTextView actually wins first responder,
        // and in that gap keystrokes would otherwise fall through to tool shortcuts.
        if app.editingID != nil || app.noteOpenID != nil { return true }
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView { return view.isEditable }
        return NSApp.keyWindow?.firstResponder is NSText
    }

    private func zoom(_ factor: Double) {
        guard let cam = app.activeLesson?.camera else { return }
        let newZoom = Format.clamp(cam.zoom * factor, 0.2, 3)
        let vw = app.viewport.width
        let vh = app.viewport.height
        let center = CGPoint(x: vw / 2, y: vh / 2)
        let wx = (center.x - cam.x) / cam.zoom
        let wy = (center.y - cam.y) / cam.zoom
        app.cameraEase = true
        app.setCamera(center.x - wx * newZoom, center.y - wy * newZoom, zoom: newZoom, persist: false)
        easeOff()
    }

    private func zoom(to targetZoom: Double) {
        guard let cam = app.activeLesson?.camera else { return }
        let newZoom = Format.clamp(targetZoom, 0.2, 3)
        let vw = app.viewport.width
        let vh = app.viewport.height
        let center = CGPoint(x: vw / 2, y: vh / 2)
        let wx = (center.x - cam.x) / cam.zoom
        let wy = (center.y - cam.y) / cam.zoom
        app.cameraEase = true
        app.setCamera(center.x - wx * newZoom, center.y - wy * newZoom, zoom: newZoom, persist: false)
        easeOff()
    }

    private func easeOff() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            app.cameraEase = false
        }
    }
}

struct LinkPrompt: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var value = "https://"

    var body: some View {
        ZStack {
            Color.black.opacity(scheme == .dark ? 0.45 : 0.28).onTapGesture { app.linkPrompt = false }
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a URL")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryInk(scheme))
                TextField("https://", text: $value)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { app.linkPrompt = false }
                    Button("Add") {
                        app.insertURL(value)
                        app.linkPrompt = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(Theme.cardSurface(scheme).opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline(scheme)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 20, y: 8)
        }
    }
}

struct ProjectWave: View {
    var token: Int
    @State private var scale = 0.2
    @State private var opacity = 0.0

    var body: some View {
        Circle()
            .stroke(Theme.ink.opacity(0.16), lineWidth: 18)
            .scaleEffect(scale)
            .opacity(opacity)
            .frame(width: 240, height: 240)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .onChange(of: token) { _, _ in
                scale = 0.12
                opacity = 0.45
                withAnimation(.easeOut(duration: 0.72)) {
                    scale = 6
                    opacity = 0
                }
            }
    }
}

struct HiddenTrafficLights: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowHook()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowHook)?.coordinator = context.coordinator
        Self.apply(view.window)
    }

    static func apply(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        DispatchQueue.main.async {
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

    @MainActor
    final class Coordinator {
        func hide(_ window: NSWindow?) {
            HiddenTrafficLights.apply(window)
        }
    }

    /// Must never steal clicks — a full-frame background NSView otherwise blocks
    /// sidebar / settings buttons intermittently.
    final class WindowHook: NSView {
        var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.hide(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WindowMoveStrip: NSViewRepresentable {
    /// Keep the drag strip clear of the left chrome (sidebar / settings ~252+padding).
    var leadingReserve: CGFloat = 280
    /// Keep the drag strip clear of the zoom controls pinned top-trailing —
    /// they sit close enough to the top edge (padding as little as 10pt with
    /// the sidebar open) to fall inside this strip's height, and the strip
    /// otherwise wins the mouseDown and drags the window instead of clicking.
    var trailingReserve: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let view = Strip()
        view.leadingReserve = leadingReserve
        view.trailingReserve = trailingReserve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Strip)?.leadingReserve = leadingReserve
        (nsView as? Strip)?.trailingReserve = trailingReserve
    }

    final class Strip: NSView {
        var leadingReserve: CGFloat = 280
        var trailingReserve: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Don’t cover sidebar/settings close controls along the top-left,
            // or the zoom controls along the top-right.
            if point.x < leadingReserve { return nil }
            if point.x > bounds.width - trailingReserve { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var isFlipped: Bool { true }
    }
}

private struct BoardMenuSizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

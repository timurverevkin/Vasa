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
                // One panel that swaps its content: the slide-in belongs to opening the
                // sidebar, not to stepping into settings. Sharing the container (and
                // killing the animation for that flag) makes the swap instant instead of
                // sliding a second opaque panel over the first.
                ZStack(alignment: .topLeading) {
                    if app.settingsOpen {
                        SettingsView()
                    } else {
                        SidebarView()
                    }
                }
                .animation(nil, value: app.settingsOpen)
                .padding(10)
                .zIndex(600)
                .contentShape(Rectangle())
                .transition(Self.sidebarTransition)
            } else if app.settings.showChrome {
                ProjectChip()
                    .transition(Self.chipTransition)
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .zIndex(600)
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
        .overlay(alignment: .top) {
            // Centered on the window, not on the canvas area: the bar must not shift
            // when the sidebar opens or closes. `ignoresSafeArea` puts it on the same
            // 14pt line as the zoom controls — without it the titlebar inset pushed the
            // bar a row lower than everything else in the top chrome.
            if app.tool == .draw, app.settings.showChrome, app.noteOpenID == nil {
                DrawInkBar()
                    .blocksWindowDrag()
                    .padding(.top, 14)
                    .ignoresSafeArea(edges: .top)
                    .zIndex(800)
            }
        }
        .overlay(alignment: .topTrailing) {
            if app.settings.showChrome, app.noteOpenID == nil, app.lightbox == nil {
                ZoomControls()
                    // Constant inset — tying it to the sidebar made the controls hop
                    // 4pt every time the sidebar opened or closed.
                    .padding(.top, 14)
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
                if card.kind == .video {
                    app.openVideoPreview(card)
                    return true
                }
            }
            app.spaceDown = true
            return true
        }
        if event.keyCode == 53 {
            if app.handleTextToolEscape() { return true }
            if app.handleDrawEscape() { return true }
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

/// Halftone bloom on project open — the window-scale sibling of `TextGaussianWave`.
/// A lit front runs from the canvas center out past the corners; everything behind it
/// stays lit and the whole field fades out together.
///
/// Measured off the reference capture (30 fps, 2× display): lattice pitch 32 px = 16 pt,
/// peak dot ≈ the pitch, the front clears the corners in ~0.21 s and the field is gone at
/// ~0.5 s; behind the front the dot weight follows ≈ 0.8 · (1 - t)^0.9 (coverage 0.43 →
/// 0.01 across the run), and the crest itself is only marginally brighter than the
/// interior — this is a filling bloom, not a thin ring.
struct ProjectWave: View {
    var token: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Nil while idle so no timeline runs between projects.
    @State private var startedAt: Date?

    private let duration: TimeInterval = 0.5
    private let step: CGFloat = 16
    /// Peak diameter equals the lattice pitch — fully swollen dots touch, no gaps.
    private var peakDot: CGFloat { step }
    private let baseDot: CGFloat = 1.5

    /// Fraction of the run the front needs to clear the corners (0.21 s of 0.5 s).
    private let frontSpan: CGFloat = 0.42
    /// Soft edge on the front, as a fraction of the half-diagonal.
    private let frontFeather: CGFloat = 0.14
    /// Weight of the lit field right behind the front, and its decay exponent.
    private let fieldAmp: CGFloat = 0.80
    private let fieldDecay: CGFloat = 0.9
    /// The crest reads only slightly brighter than the interior.
    private let crestBoost: CGFloat = 0.06
    /// Push the front past the corners so it fully leaves the viewport.
    private let radiusOvershoot: CGFloat = 1.15

    var body: some View {
        GeometryReader { geo in
            Group {
                if let startedAt {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                        let t = CGFloat(min(1, max(0, context.date.timeIntervalSince(startedAt) / duration)))
                        Canvas { ctx, size in
                            draw(ctx: ctx, size: size, t: t)
                        }
                        .onChange(of: t) { _, value in
                            if value >= 1 { self.startedAt = nil }
                        }
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .onChange(of: token) { _, _ in
            guard !reduceMotion else { return }
            startedAt = .now
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, t: CGFloat) {
        // Origin is the canvas viewport center — the same point the camera is centered
        // on. The sidebar floats above the canvas, so it must not shift this.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxDist = max(1, hypot(size.width, size.height) / 2)
        // Dot positions never move; only each dot's diameter is modulated. The front
        // advances at a constant speed and clears the corners well before the run ends —
        // the rest of the run is the whole field fading out at once.
        let front = maxDist * radiusOvershoot * min(1, t / frontSpan)
        let feather = maxDist * frontFeather
        // Resting state belongs to `DotGrid`, which is already painted underneath, so the
        // field fades back out at the end instead of leaving a second lattice behind.
        let amp = fieldAmp * pow(max(0, 1 - t), fieldDecay)
        let color = Theme.primaryInk(scheme)

        var x = center.x.truncatingRemainder(dividingBy: step)
        while x < size.width {
            var y = center.y.truncatingRemainder(dividingBy: step)
            while y < size.height {
                let d = hypot(x - center.x, y - center.y)
                // 1 behind the front, fading to 0 just outside it.
                let lit = 1 - ShapeSDF.smoothstep(front - feather, front + feather * 0.35, d)
                let crest = exp(-0.5 * pow((d - front) / (feather * 0.7), 2))
                let weight = amp * (lit + crestBoost * crest)
                if weight > 0.03 {
                    let dot = baseDot + (peakDot - baseDot) * min(1, weight)
                    let alpha = min(1, weight) * 0.42
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                }
                y += step
            }
            x += step
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
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
        // Dragging is owned by `WindowMoveStrip` alone: with background dragging on, a
        // drag that started on chrome (the ink-thickness slider) moved the window too.
        window.isMovableByWindowBackground = false
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

/// Mouse handling for a slider that sits inside the window's titlebar band. AppKit decides
/// window-dragging from the hit view at mouseDown, before a SwiftUI `DragGesture` ever runs,
/// so dragging the ink-thickness slider moved the whole window. This view takes the events
/// itself and reports the position back, and answers `false` to `mouseDownCanMoveWindow`.
struct SliderDragCatcher: NSViewRepresentable {
    /// Position of the pointer inside the view, in points from its left edge.
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Catcher()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Catcher)?.onDrag = onDrag
    }

    final class Catcher: NSView {
        var onDrag: ((CGFloat) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func report(_ event: NSEvent) {
            onDrag?(convert(event.locationInWindow, from: nil).x)
        }

        override func mouseDown(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseUp(with event: NSEvent) { report(event) }
    }
}

/// Suspends window dragging while the pointer is over a control.
///
/// The ink bar sits inside the titlebar band, where AppKit starts a window drag from the
/// hit view's `mouseDownCanMoveWindow` before any SwiftUI gesture runs — and `NSHostingView`
/// answers every `hitTest` with itself, so a nested `NSViewRepresentable` can never be that
/// hit view and can never change the answer. `NSWindow.isMovable` is the supported lever:
/// off while the pointer is on the control, on again the moment it leaves.
private struct WindowDragSuspender: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onHover { inside in
                (window ?? NSApp.keyWindow)?.isMovable = !inside
            }
            .onDisappear {
                (window ?? NSApp.keyWindow)?.isMovable = true
            }
    }
}

extension View {
    /// A press inside this view never drags the window.
    func blocksWindowDrag() -> some View {
        modifier(WindowDragSuspender())
    }
}

/// Hands back the window the view landed in.
private struct WindowReader: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
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

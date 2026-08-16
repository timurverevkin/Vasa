import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasView()
            if app.library.sidebarOpen {
                if app.settingsOpen {
                    SettingsView()
                        .padding(10)
                } else {
                    SidebarView()
                        .padding(10)
                }
            } else if app.settings.showChrome {
                ProjectChip()
                    .padding(.top, 14)
                    .padding(.leading, 14)
            }
            if let id = app.boardMenuID, let lesson = app.library.lessons.first(where: { $0.id == id }) {
                BoardMenuCard(lesson: lesson)
                    .offset(x: 270, y: app.boardMenuY)
                    .zIndex(400)
            }
            if app.settings.showChrome {
                if app.noteOpenID == nil {
                    ZoomControls()
                        .padding(.top, 14)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if !app.library.sidebarOpen {
                    FloatingToolbar()
                        .padding(.leading, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                MinimapView()
                    .padding(.leading, app.library.sidebarOpen ? 276 : 14)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if app.askAICardID != nil { AskAIPanel() }
            if app.paletteOpen { CommandPalette() }
            if let item = app.lightbox { LightboxView(item: item) }
            if app.audioDetailID != nil { AudioDetailView() }
            if app.linkPrompt { LinkPrompt() }
            if let menu = app.menu { ItemMenuOverlay(anchor: menu) }
            ProjectWave(token: app.boardWave)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasColor(app.settings.appearance.colorScheme ?? scheme))
        .ignoresSafeArea()
        .background(HiddenTrafficLights())
        .preferredColorScheme(app.settings.appearance.colorScheme)
        .overlay(alignment: .top) {
            WindowMoveStrip()
                .frame(height: 14)
                .frame(maxWidth: .infinity)
        }
        .overlay {
            if app.noteOpenID != nil {
                NoteEditorLayer()
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .rightMouseDown]) { event in
            if event.type == .rightMouseDown {
                FieldEditor.silenceSystemTextUI()
                guard let window = event.window else { return nil }
                let loc = event.locationInWindow
                let size = window.contentView?.bounds.size ?? .zero
                let point = CGPoint(x: loc.x, y: size.height - loc.y)
                _ = app.openContextMenu(at: point, in: CGSize(width: size.width, height: size.height))
                return nil
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
                    app.lightbox = LightboxItem(src: poster, alt: card.title)
                    return true
                }
            }
            app.spaceDown = true
            return true
        }
        if event.keyCode == 53 {
            app.dismissOverlays()
            return true
        }
        if event.keyCode == 48, !typing {
            app.settings.showChrome.toggle()
            return true
        }
        if typing { return false }

        if event.keyCode == 51 || event.keyCode == 117 {
            app.deleteSelected()
            return true
        }

        if !cmd {
            switch event.charactersIgnoringModifiers {
            case "f": app.pickFiles(); return true
            case "t":
                app.tool = app.tool == .text ? .select : .text
                return true
            case "l": app.linkPrompt = true; return true
            case "p":
                app.tool = app.tool == .draw ? .select : .draw
                return true
            case "n": app.insertBlankNote(); return true
            case "s": return true
            default: break
            }
        }

        if cmd, event.charactersIgnoringModifiers == "t" {
            let all = AppSettings.Appearance.allCases
            if let i = all.firstIndex(of: app.settings.appearance) {
                app.settings.appearance = all[(i + 1) % all.count]
            }
            return true
        }
        if cmd, event.charactersIgnoringModifiers == "m" {
            app.settings.sounds.toggle()
            return true
        }
        if cmd, event.charactersIgnoringModifiers == "s" {
            app.settings.snapping.toggle()
            return true
        }

        if !cmd, event.charactersIgnoringModifiers == "a" {
            if let id = app.selectedIDs.first, let card = app.card(id), card.kind == .image {
                app.openLens(card.src)
            } else {
                app.askAbout(app.selectedIDs.first ?? "board")
            }
            return true
        }
        if cmd, event.charactersIgnoringModifiers == "]" {
            app.layer(1)
            return true
        }
        if cmd, event.charactersIgnoringModifiers == "[" {
            app.layer(-1)
            return true
        }
        if cmd, (event.charactersIgnoringModifiers == "=" || event.charactersIgnoringModifiers == "+") {
            zoom(1.15)
            return true
        }
        if cmd, event.charactersIgnoringModifiers == "-" {
            zoom(1 / 1.15)
            return true
        }
        if cmd, event.charactersIgnoringModifiers == "0" {
            app.cameraEase = true
            app.setCamera(zoom: 1)
            easeOff()
            return true
        }
        let step: Double = shift ? 32 : 8
        switch event.keyCode {
        case 123: app.nudge(-step, 0); return true
        case 124: app.nudge(step, 0); return true
        case 126: app.nudge(0, -step); return true
        case 125: app.nudge(0, step); return true
        default: return false
        }
    }

    private var isTyping: Bool {
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView { return view.isEditable }
        return NSApp.keyWindow?.firstResponder is NSText
    }

    private func zoom(_ factor: Double) {
        guard let cam = app.activeLesson?.camera else { return }
        app.cameraEase = true
        app.setCamera(zoom: Format.clamp(cam.zoom * factor, 0.2, 3))
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
    @State private var value = "https://"

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).onTapGesture { app.linkPrompt = false }
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a URL").font(.headline)
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
            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.chromeBorder))
            .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
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

    final class WindowHook: NSView {
        var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.hide(window)
        }
    }
}

struct WindowMoveStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Strip() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Strip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var isFlipped: Bool { true }
    }
}

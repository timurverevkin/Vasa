import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CanvasView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var marquee: CGRect?
    @State private var panning = false
    @State private var hostSize: CGSize = .zero
    @State private var wheelMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let cam = app.activeLesson?.camera ?? Camera(x: 40, y: 36, zoom: 1)
            ZStack(alignment: .topLeading) {
                Theme.canvasColor(scheme)
                if app.settings.showGrid {
                    DotGrid(camera: cam)
                }
                // Behind cards: empty canvas receives pan / text place / marquee.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(canvasDrag)
                    .onTapGesture(count: 1, coordinateSpace: .local) { point in
                        let world = toWorld(point, cam)
                        app.lastWorld = world
                        if app.tool == .text {
                            app.insertBlankText(at: world)
                            return
                        }
                        if app.cardAt(world) == nil {
                            app.clearSelection()
                            app.menu = nil
                        }
                    }
                WorldLayer(camera: cam, ease: app.cameraEase)
                if let marquee {
                    Rectangle()
                        .stroke(Theme.selection, lineWidth: 1)
                        .background(Theme.selection.opacity(0.08))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
                if app.activeLesson?.cards.isEmpty == true {
                    Text("Drop files here, or paste a link")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onAppear { hostSize = geo.size; app.viewport = geo.size; installWheel() }
            .onChange(of: geo.size) { _, size in hostSize = size; app.viewport = size }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                hostSize = size
                app.viewport = size
            }
            .onDisappear {
                if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            .cursor(app.spaceDown || panning ? .closedHand : (app.tool == .draw ? .crosshair : (app.tool == .text ? .iBeam : .arrow)))
        }
    }

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: app.tool == .text ? 0 : 4)
            .onChanged { value in
                guard let lesson = app.activeLesson else { return }
                let cam = lesson.camera
                let world = toWorld(value.startLocation, cam)
                app.lastWorld = world

                if app.tool == .text { return }
                if app.tool == .draw, !app.spaceDown {
                    draw(value, origin: world)
                    return
                }
                if app.spaceDown {
                    if panOrigin == nil { panOrigin = cam }
                    let origin = panOrigin ?? cam
                    let next = app.clampCamera(
                        x: origin.x + value.translation.width,
                        y: origin.y + value.translation.height,
                        rubber: true
                    )
                    panning = true
                    app.setCamera(next.x, next.y, persist: false)
                    return
                }
                if app.cardAt(world) != nil {
                    return
                }
                let origin = value.startLocation
                let current = value.location
                marquee = CGRect(
                    x: min(origin.x, current.x),
                    y: min(origin.y, current.y),
                    width: abs(current.x - origin.x),
                    height: abs(current.y - origin.y)
                )
            }
            .onEnded { value in
                if app.tool == .text, hypot(value.translation.width, value.translation.height) < 8,
                   let cam = app.activeLesson?.camera
                {
                    app.insertBlankText(at: toWorld(value.startLocation, cam))
                    marquee = nil
                    panning = false
                    drawingID = nil
                    panOrigin = nil
                    dragAxis = nil
                    dragging = false
                    return
                }
                if let lesson = app.activeLesson, let marquee, marquee.width > 4, marquee.height > 4 {
                    let a = toWorld(value.startLocation, lesson.camera)
                    let b = toWorld(value.location, lesson.camera)
                    let rect = CGRect(
                        x: min(a.x, b.x), y: min(a.y, b.y),
                        width: abs(a.x - b.x), height: abs(a.y - b.y)
                    )
                    app.select(lesson.cards.filter { $0.frame.intersects(rect) }.map(\.id))
                } else if hypot(value.translation.width, value.translation.height) < 4,
                          app.tool != .text,
                          !app.spaceDown,
                          let lesson = app.activeLesson,
                          app.cardAt(toWorld(value.startLocation, lesson.camera)) == nil
                {
                    app.clearSelection()
                }
                marquee = nil
                panning = false
                drawingID = nil
                panOrigin = nil
                dragAxis = nil
                dragging = false
                app.settlePan()
            }
    }

    @State private var drawingID: String?
    @State private var dragStart: CGPoint = .zero
    @State private var dragging = false
    @State private var lastWorldPoint: CGPoint = .zero
    @State private var panOrigin: Camera?
    @State private var dragAxis: Axis?
    @State private var wheelSettle: Task<Void, Never>?

    private func draw(_ value: DragGesture.Value, origin: CGPoint) {
        if drawingID == nil {
            let id = NexusID.make("c")
            drawingID = id
            var card = DemoLibrary.base(id, .draw, origin.x, origin.y, 8, 8, 1)
            card.points = [DrawPoint(x: 0, y: 0)]
            card.stroke = "#111318"
            app.addCard(card)
        }
        guard let id = drawingID, var card = app.card(id), let cam = app.activeLesson?.camera else { return }
        let w = toWorld(value.location, cam)
        var pts = card.points ?? []
        pts.append(DrawPoint(x: w.x - origin.x, y: w.y - origin.y))
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let minX = min(0, xs.min() ?? 0)
        let minY = min(0, ys.min() ?? 0)
        app.updateCard(id, persist: false) {
            $0.points = pts.map { DrawPoint(x: $0.x - minX, y: $0.y - minY) }
            $0.x = origin.x + minX
            $0.y = origin.y + minY
            $0.width = max(8, (xs.max() ?? 0) - minX)
            $0.height = max(8, (ys.max() ?? 0) - minY)
        }
        _ = card
        _ = cam
    }

    private func dragCard(_ hit: Card, value: DragGesture.Value, start: CGPoint) {
        if !dragging {
            if hypot(value.translation.width, value.translation.height) < 6 {
                if !app.selectedIDs.contains(hit.id) { app.select([hit.id]) }
                return
            }
            dragging = true
            app.pushUndo()
            app.bringToFront(hit.id)
            if !app.selectedIDs.contains(hit.id) { app.select([hit.id]) }
            lastWorldPoint = start
        }
        guard let cam = app.activeLesson?.camera else { return }
        let w = toWorld(value.location, cam)
        var dx = w.x - lastWorldPoint.x
        var dy = w.y - lastWorldPoint.y
        if NSEvent.modifierFlags.contains(.shift) {
            if dragAxis == nil {
                dragAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
            }
            if dragAxis == .horizontal { dy = 0 } else { dx = 0 }
        } else {
            dragAxis = nil
        }
        app.moveCards(app.selectedIDs, dx: dx, dy: dy)
        lastWorldPoint = CGPoint(x: lastWorldPoint.x + dx, y: lastWorldPoint.y + dy)
    }

    private func toWorld(_ p: CGPoint, _ cam: Camera) -> CGPoint {
        CGPoint(x: (p.x - cam.x) / cam.zoom, y: (p.y - cam.y) / cam.zoom)
    }

    private func installWheel() {
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            if eventOverNotePanel(event) { return event }
            guard let lesson = app.activeLesson else { return event }
            let cam = lesson.camera
            let point = canvasPoint(from: event)

            if event.type == .magnify {
                let zoom = Format.clamp(cam.zoom * (1 + event.magnification), 0.2, 3)
                zoomToward(point, zoom: zoom, camera: cam)
                return nil
            }

            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                let factor = exp(-event.scrollingDeltaY * 0.01)
                let zoom = Format.clamp(cam.zoom * factor, 0.2, 3)
                zoomToward(point, zoom: zoom, camera: cam)
                return nil
            }

            let next = app.clampCamera(
                x: cam.x + event.scrollingDeltaX,
                y: cam.y + event.scrollingDeltaY,
                rubber: true
            )
            app.setCamera(next.x, next.y, persist: false)
            wheelSettle?.cancel()
            wheelSettle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                app.settlePan()
            }
            return nil
        }
    }

    private func canvasPoint(from event: NSEvent) -> CGPoint {
        let loc = event.locationInWindow
        let size = event.window?.contentView?.bounds.size ?? hostSize
        return CGPoint(x: loc.x, y: size.height - loc.y)
    }

    private func eventOverNotePanel(_ event: NSEvent) -> Bool {
        guard app.noteOpenID != nil else { return false }
        let size = event.window?.contentView?.bounds.size ?? hostSize
        let loc = event.locationInWindow
        let yFromTop = size.height - loc.y
        if loc.x < size.width - Format.notePanelOuterWidth { return false }
        if yFromTop < Format.notePanelVertical { return false }
        if yFromTop > size.height - Format.notePanelVertical { return false }
        return true
    }

    private func zoomToward(_ point: CGPoint, zoom: Double, camera cam: Camera) {
        let wx = (point.x - cam.x) / cam.zoom
        let wy = (point.y - cam.y) / cam.zoom
        app.setCamera(point.x - wx * zoom, point.y - wy * zoom, zoom: zoom, persist: false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    app.drop(urls: [url], at: app.lastWorld)
                }
            }
        }
        return true
    }
}

struct WorldLayer: View {
    @Environment(AppModel.self) private var app
    let camera: Camera
    let ease: Bool

    var body: some View {
        let selected = Set(app.selectedIDs)
        ZStack(alignment: .topLeading) {
            ForEach(app.activeLesson?.cards ?? []) { card in
                CardView(card: card, selected: selected.contains(card.id))
                    .zIndex(Double(card.z))
            }
            if let wave = app.textWave {
                TextGaussianWave(token: wave.id)
                    .position(x: wave.x, y: wave.y)
                    .allowsHitTesting(false)
                    .zIndex(10_000)
            }
            // Outside card bounds so toolbar clicks aren't clipped / eaten by the canvas.
            if let id = app.editingID,
               let card = app.activeLesson?.cards.first(where: { $0.id == id && $0.kind == .text }) {
                TextFormatBar(card: card)
                    .fixedSize(horizontal: true, vertical: true)
                    .offset(x: card.x, y: card.y + card.previewHeight + 12)
                    .zIndex(20_000)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scaleEffect(camera.zoom, anchor: .topLeading)
        .offset(x: camera.x, y: camera.y)
        .animation(ease ? .easeOut(duration: 0.28) : nil, value: camera)
    }
}

struct DotGrid: View {
    let camera: Camera
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let step = 24 * camera.zoom
            guard step > 6 else { return }
            let t = Format.clamp((camera.zoom - 0.2) / 1.8, 0, 1)
            let gray = scheme == .dark ? (0.28 + 0.18 * t) : (0.50 + 0.34 * t)
            let opacity = camera.zoom < 0.28 ? max(0.35, (camera.zoom - 0.15) / 0.13) : 1
            var x = camera.x.truncatingRemainder(dividingBy: step)
            if x > 0 { x -= step }
            var y = camera.y.truncatingRemainder(dividingBy: step)
            if y > 0 { y -= step }
            while x < size.width {
                var yy = y
                while yy < size.height {
                    let r = CGRect(x: x, y: yy, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: r), with: .color(Color(white: gray).opacity(opacity)))
                    yy += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }
}

extension AppModel {
    func cardAt(_ point: CGPoint) -> Card? {
        activeLesson?.cards
            .sorted { $0.z > $1.z }
            .first { $0.frame.contains(point) }
    }
}

private extension View {
    func cursor(_ ns: NSCursor) -> some View {
        onHover { inside in
            if inside { ns.push() } else { NSCursor.pop() }
        }
    }
}

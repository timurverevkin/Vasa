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
                        // Text placement is owned by TextToolReducer via canvasDrag —
                        // do not insert here (avoids double-create with pointerUp).
                        if app.tool == .text { return }
                        if app.cardAt(world) == nil {
                            app.clearSelection()
                            app.menu = nil
                        }
                    }
                WorldLayer(camera: cam, ease: app.cameraEase)
                // Under the note editor overlay — same canvas geometry + camera as cards.
                if app.noteOpenID != nil {
                    NoteConnectorOverlay()
                        .allowsHitTesting(false)
                        .zIndex(8_000)
                }
                if let marquee {
                    Rectangle()
                        .stroke(Theme.selection, lineWidth: 1)
                        .background(Theme.selection.opacity(0.08))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
                // Screen-space chrome — must sit outside WorldLayer.scaleEffect.
                CanvasScreenChrome(camera: cam)
                if app.activeLesson?.cards.isEmpty == true {
                    Text("Drop files here, or paste a link")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .coordinateSpace(.named("canvas"))
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
            .onDrop(of: [.fileURL, .image], isTargeted: nil, perform: handleDrop)
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                updateCanvasCursor(phase, camera: cam)
            }
        }
    }

    /// Tool-wide cursor (i-beam for text tool, crosshair for draw, closed hand
    /// while panning). Uses `.set()`, not `.push()/.pop()` — mixing a push/pop
    /// stack with per-view cursor rects desyncs the two systems and leaves a
    /// cursor stuck. This is the single source of truth for the whole canvas,
    /// including over cards: GrowingTextView's own `resetCursorRects` cannot
    /// be trusted to cover an unselected/non-editing card, since its custom
    /// `hitTest` deliberately returns nil there (so clicks fall through to
    /// card selection) — and AppKit's cursor-rect resolution also goes
    /// through hit-testing, so a rect on a view that just opted itself out of
    /// hit-testing for that point may never be consulted either. Only truly
    /// editing a text card (where GrowingTextView is genuinely hit-testable
    /// and its default NSTextView i-beam behavior is correct) defers to it.
    private func updateCanvasCursor(_ phase: HoverPhase, camera cam: Camera) {
        guard case .active(let point) = phase else {
            NSCursor.arrow.set()
            return
        }
        if app.spaceDown || panning {
            NSCursor.closedHand.set()
            return
        }
        let world = toWorld(point, cam)
        if let hit = app.cardAt(world) {
            if hit.kind == .text, app.editingID == hit.id { return }
            NSCursor.arrow.set()
            return
        }
        switch app.tool {
        case .draw: NSCursor.crosshair.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.arrow.set()
        }
    }

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: app.tool == .text ? 0 : 4)
            .onChanged { value in
                guard let lesson = app.activeLesson else { return }
                let cam = lesson.camera
                let world = toWorld(value.startLocation, cam)
                app.lastWorld = world

                // Space+drag pans regardless of active tool (Ticket C).
                if app.spaceDown {
                    if case .armed = app.textToolState { app.dispatchTextTool(.escape) }
                    else if case .creating = app.textToolState { app.dispatchTextTool(.escape) }
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

                if app.tool == .text {
                    let point = toWorld(value.location, cam)
                    if case .idle = app.textToolState {
                        app.dispatchTextTool(
                            .pointerDown(toWorld(value.startLocation, cam)),
                            threshold: TextToolReducer.dragThreshold / max(cam.zoom, 0.01)
                        )
                    }
                    app.dispatchTextTool(.pointerMoved(point))
                    return
                }
                if app.tool == .draw {
                    draw(value, origin: world)
                    return
                }
                if app.cardAt(world) != nil {
                    return
                }
                // A press inside the bounding box of the current multi-selection, but not on
                // any single card, drags the whole selection instead of restarting a marquee.
                if app.selectedIDs.count > 1, let bounds = app.selectionBounds(), bounds.contains(world) {
                    if !dragging {
                        dragging = true
                        app.pushUndo()
                        moveOrigins = Dictionary(uniqueKeysWithValues: app.idsMoving(with: app.selectedIDs).compactMap { id -> (String, CGPoint)? in
                            guard let c = app.card(id) else { return nil }
                            return (id, CGPoint(x: c.x, y: c.y))
                        })
                        dragStart = world
                        dragAxis = nil
                    }
                    var tx = world.x - dragStart.x
                    var ty = world.y - dragStart.y
                    if NSEvent.modifierFlags.contains(.shift) {
                        if dragAxis == nil {
                            dragAxis = abs(tx) >= abs(ty) ? .horizontal : .vertical
                        }
                        if dragAxis == .horizontal { ty = 0 } else { tx = 0 }
                    } else {
                        dragAxis = nil
                    }
                    app.moveCardsFromOrigins(moveOrigins, tx: tx, ty: ty, allowSnapX: dragAxis != .vertical, allowSnapY: dragAxis != .horizontal)
                    return
                }
                let origin = value.startLocation
                let current = value.location
                let box = CGRect(
                    x: min(origin.x, current.x),
                    y: min(origin.y, current.y),
                    width: abs(current.x - origin.x),
                    height: abs(current.y - origin.y)
                )
                marquee = box
                if box.width > 4, box.height > 4 {
                    let a = toWorld(origin, cam)
                    let b = toWorld(current, cam)
                    let rect = CGRect(
                        x: min(a.x, b.x), y: min(a.y, b.y),
                        width: abs(a.x - b.x), height: abs(a.y - b.y)
                    )
                    app.select(
                        lesson.cards.filter { $0.frame.intersects(rect) }.map(\.id),
                        playSound: false
                    )
                }
            }
            .onEnded { value in
                // Pan end must not commit a text block (Ticket C).
                if panning || (app.spaceDown && panOrigin != nil) {
                    if case .armed = app.textToolState { app.dispatchTextTool(.escape) }
                    else if case .creating = app.textToolState { app.dispatchTextTool(.escape) }
                    marquee = nil
                    panning = false
                    drawingID = nil
                    strokeWorld = []
                    inkBaseWorld = []
                    panOrigin = nil
                    dragAxis = nil
                    dragging = false
                    moveOrigins = [:]
                    app.settlePan()
                    return
                }
                if app.tool == .text, let cam = app.activeLesson?.camera {
                    if case .idle = app.textToolState {
                        app.dispatchTextTool(
                            .pointerDown(toWorld(value.startLocation, cam)),
                            threshold: TextToolReducer.dragThreshold / max(cam.zoom, 0.01)
                        )
                    }
                    app.dispatchTextTool(.pointerUp(toWorld(value.location, cam)))
                    marquee = nil
                    panning = false
                    drawingID = nil
                    strokeWorld = []
                    inkBaseWorld = []
                    panOrigin = nil
                    dragAxis = nil
                    dragging = false
                    moveOrigins = [:]
                    return
                }
                if drawingID != nil {
                    app.persistSoon()
                } else if app.drawMode == .eraser, app.tool == .draw {
                    app.persistSoon()
                }
                if dragging, !moveOrigins.isEmpty {
                    app.reconcileGroups(afterMoving: Array(moveOrigins.keys))
                    app.snapSelected()
                    app.saveNow()
                } else if let lesson = app.activeLesson, let marquee, marquee.width > 4, marquee.height > 4 {
                    let a = toWorld(value.startLocation, lesson.camera)
                    let b = toWorld(value.location, lesson.camera)
                    let rect = CGRect(
                        x: min(a.x, b.x), y: min(a.y, b.y),
                        width: abs(a.x - b.x), height: abs(a.y - b.y)
                    )
                    app.select(lesson.cards.filter { $0.frame.intersects(rect) }.map(\.id))
                } else if drawingID == nil,
                          hypot(value.translation.width, value.translation.height) < 4,
                          app.tool != .text,
                          !app.spaceDown,
                          let lesson = app.activeLesson,
                          app.cardAt(toWorld(value.startLocation, lesson.camera)) == nil
                {
                    // Draw tool: empty click ends the current ink object so the next stroke is new.
                    app.clearSelection()
                    app.activeInkCardID = nil
                }
                marquee = nil
                panning = false
                drawingID = nil
                strokeWorld = []
                inkBaseWorld = []
                panOrigin = nil
                dragAxis = nil
                dragging = false
                moveOrigins = [:]
                app.clearSnapGuides()
                app.settlePan()
            }
    }

    @State private var drawingID: String?
    /// Absolute world-space polyline for the in-progress stroke (avoids remapping churn).
    @State private var strokeWorld: [CGPoint] = []
    /// Committed strokes in world space while a pen gesture is active on a card.
    @State private var inkBaseWorld: [(points: [CGPoint], color: String, width: Double)] = []
    @State private var dragStart: CGPoint = .zero
    @State private var dragging = false
    @State private var lastWorldPoint: CGPoint = .zero
    @State private var moveOrigins: [String: CGPoint] = [:]
    @State private var panOrigin: Camera?
    @State private var dragAxis: Axis?
    @State private var wheelSettle: Task<Void, Never>?

    private func draw(_ value: DragGesture.Value, origin: CGPoint) {
        guard let cam = app.activeLesson?.camera else { return }
        let w = toWorld(value.location, cam)
        if app.drawMode == .eraser {
            if drawingID == nil {
                drawingID = "erase"
                app.pushUndo()
            }
            erase(at: w, width: app.drawWidth)
            return
        }
        if drawingID == nil || drawingID == "erase" {
            beginPenStroke(at: w)
            return
        }
        if let last = strokeWorld.last, hypot(w.x - last.x, w.y - last.y) < 0.5 { return }
        strokeWorld.append(w)
        if let id = drawingID {
            applyInkBounds(id: id)
        }
    }

    /// Continue on the active ink card; color changes stay on the same object.
    private func beginPenStroke(at world: CGPoint) {
        strokeWorld = [world]
        if let existing = activeDrawTarget() {
            drawingID = existing.id
            app.activeInkCardID = existing.id
            inkBaseWorld = existing.inkStrokes.map { stroke in
                (
                    points: stroke.points.map { CGPoint(x: existing.x + $0.x, y: existing.y + $0.y) },
                    color: stroke.color,
                    width: stroke.width
                )
            }
            app.pushUndo()
            app.select([existing.id], playSound: false)
            applyInkBounds(id: existing.id)
            return
        }
        inkBaseWorld = []
        let id = VasaID.make("c")
        drawingID = id
        app.activeInkCardID = id
        var card = DemoLibrary.base(id, .draw, world.x, world.y, 8, 8, 1)
        card.stroke = app.drawColorCustom ? app.drawColor : "#111318"
        card.strokeWidth = app.drawWidth
        card.points = [DrawPoint(x: 0, y: 0)]
        card.strokes = [
            DrawStroke(points: [DrawPoint(x: 0, y: 0)], color: card.stroke ?? "#111318", width: app.drawWidth)
        ]
        app.addCard(card)
        applyInkBounds(id: id)
    }

    private func activeDrawTarget() -> Card? {
        guard let lesson = app.activeLesson else { return nil }
        if let id = app.activeInkCardID,
           let card = lesson.cards.first(where: { $0.id == id }),
           card.kind == .draw
        {
            return card
        }
        if app.selectedIDs.count == 1,
           let id = app.selectedIDs.first,
           let card = lesson.cards.first(where: { $0.id == id }),
           card.kind == .draw
        {
            return card
        }
        return nil
    }

    private func applyInkBounds(id: String) {
        var all = inkBaseWorld
        if !strokeWorld.isEmpty {
            let color = app.drawColorCustom ? app.drawColor : "#111318"
            all.append((points: strokeWorld, color: color, width: app.drawWidth))
        }
        guard !all.isEmpty else { return }
        let pad = max(4, (all.map(\.width).max() ?? 3) / 2 + 2)
        let xs = all.flatMap { $0.points.map(\.x) }
        let ys = all.flatMap { $0.points.map(\.y) }
        let minX = (xs.min() ?? 0) - pad
        let minY = (ys.min() ?? 0) - pad
        let maxX = (xs.max() ?? 0) + pad
        let maxY = (ys.max() ?? 0) + pad
        let strokes = all.map { stroke in
            DrawStroke(
                points: stroke.points.map { DrawPoint(x: $0.x - minX, y: $0.y - minY) },
                color: stroke.color,
                width: stroke.width
            )
        }
        app.updateCard(id, persist: false) {
            $0.x = minX
            $0.y = minY
            $0.width = max(8, maxX - minX)
            $0.height = max(8, maxY - minY)
            $0.setInkStrokes(strokes)
        }
    }

    private func erase(at world: CGPoint, width: Double) {
        guard let lesson = app.activeLesson else { return }
        let brush = max(6, width * 1.4)
        for card in lesson.cards where card.kind == .draw {
            let origin = CGPoint(x: card.x, y: card.y)
            var kept: [(points: [CGPoint], color: String, width: Double)] = []
            for stroke in card.inkStrokes {
                let worldPts = stroke.points.map { CGPoint(x: origin.x + $0.x, y: origin.y + $0.y) }
                let fragments = erasePolyline(worldPts, at: world, radius: brush + stroke.width * 0.5)
                for frag in fragments {
                    kept.append((points: frag, color: stroke.color, width: stroke.width))
                }
            }
            if kept.isEmpty {
                app.patchLesson { $0.cards.removeAll { $0.id == card.id } }
                if app.selectedIDs.contains(card.id) {
                    app.selectedIDs.removeAll { $0 == card.id }
                }
                continue
            }
            let pad = max(4, (kept.map(\.width).max() ?? 3) / 2 + 2)
            let xs = kept.flatMap { $0.points.map(\.x) }
            let ys = kept.flatMap { $0.points.map(\.y) }
            let minX = (xs.min() ?? 0) - pad
            let minY = (ys.min() ?? 0) - pad
            let maxX = (xs.max() ?? 0) + pad
            let maxY = (ys.max() ?? 0) + pad
            let strokes = kept.map { stroke in
                DrawStroke(
                    points: stroke.points.map { DrawPoint(x: $0.x - minX, y: $0.y - minY) },
                    color: stroke.color,
                    width: stroke.width
                )
            }
            app.updateCard(card.id, persist: false) {
                $0.x = minX
                $0.y = minY
                $0.width = max(8, maxX - minX)
                $0.height = max(8, maxY - minY)
                $0.setInkStrokes(strokes)
            }
        }
    }

    /// Split a polyline where the eraser brush hits — never reconnect across a gap.
    private func erasePolyline(_ points: [CGPoint], at eraser: CGPoint, radius: Double) -> [[CGPoint]] {
        guard points.count >= 2 else { return [] }
        let r2 = radius * radius
        var fragments: [[CGPoint]] = []
        var current: [CGPoint] = []

        func flush() {
            if current.count >= 2 { fragments.append(current) }
            current = []
        }

        func inside(_ p: CGPoint) -> Bool {
            let dx = p.x - eraser.x
            let dy = p.y - eraser.y
            return dx * dx + dy * dy <= r2
        }

        for i in 0..<points.count {
            let p = points[i]
            if inside(p) {
                flush()
                continue
            }
            if let prev = current.last, segmentHitsCircle(prev, p, center: eraser, radius: radius) {
                flush()
            }
            current.append(p)
        }
        flush()
        return fragments
    }

    private func segmentHitsCircle(_ a: CGPoint, _ b: CGPoint, center: CGPoint, radius: Double) -> Bool {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        if len2 < 1e-9 { return false }
        let t = max(0, min(1, ((center.x - a.x) * abx + (center.y - a.y) * aby) / len2))
        let px = a.x + abx * t
        let py = a.y + aby * t
        let dx = px - center.x
        let dy = py - center.y
        return dx * dx + dy * dy <= radius * radius
    }

    private func dragCard(_ hit: Card, value: DragGesture.Value, start: CGPoint) {
        guard let cam = app.activeLesson?.camera else { return }
        let w = toWorld(value.location, cam)
        if !dragging {
            if hypot(value.translation.width, value.translation.height) < 6 {
                if !app.selectedIDs.contains(hit.id) { app.select([hit.id]) }
                return
            }
            dragging = true
            app.pushUndo()
            app.bringToFront(hit.id)
            if !app.selectedIDs.contains(hit.id) { app.select([hit.id]) }
            // Anchor at current pointer — keeps the grab point under the cursor.
            dragStart = w
            lastWorldPoint = w
            moveOrigins = Dictionary(uniqueKeysWithValues: app.selectedIDs.compactMap { id -> (String, CGPoint)? in
                guard let c = app.card(id) else { return nil }
                return (id, CGPoint(x: c.x, y: c.y))
            })
            dragAxis = nil
        }
        var tx = w.x - dragStart.x
        var ty = w.y - dragStart.y
        if NSEvent.modifierFlags.contains(.shift) {
            if dragAxis == nil {
                dragAxis = abs(tx) >= abs(ty) ? .horizontal : .vertical
            }
            if dragAxis == .horizontal { ty = 0 } else { tx = 0 }
        } else {
            dragAxis = nil
        }
        let snapX = dragAxis != .vertical
        let snapY = dragAxis != .horizontal
        app.moveCardsFromOrigins(moveOrigins, tx: tx, ty: ty, allowSnapX: snapX, allowSnapY: snapY)
        lastWorldPoint = w
    }

    private func toWorld(_ p: CGPoint, _ cam: Camera) -> CGPoint {
        CGPoint(x: (p.x - cam.x) / cam.zoom, y: (p.y - cam.y) / cam.zoom)
    }

    private func installWheel() {
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            if app.lightbox != nil { return event }
            if eventOverNotePanel(event) { return event }
            // Floating chrome panels (chat, settings, provider config, AI arrange prompt,
            // command palette) own scroll/pinch inside their own bounds — without this, this
            // window-wide monitor swallows the event first and pans the canvas underneath
            // instead of letting a nested SwiftUI ScrollView handle it.
            if app.askAICardID != nil { return event }
            if app.settingsOpen { return event }
            if app.providerSettingsOpen { return event }
            if app.aiArrangePromptOpen { return event }
            if app.paletteOpen { return event }
            guard let lesson = app.activeLesson else { return event }
            let cam = lesson.camera
            let point = canvasPoint(from: event)

            if event.type == .magnify {
                let zoom = Format.clamp(cam.zoom * (1 + event.magnification), 0.2, 3)
                zoomToward(point, zoom: zoom, camera: cam)
                scheduleCameraSettle()
                return nil
            }

            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                let factor = exp(-event.scrollingDeltaY * 0.01)
                let zoom = Format.clamp(cam.zoom * factor, 0.2, 3)
                zoomToward(point, zoom: zoom, camera: cam)
                scheduleCameraSettle()
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

    private func scheduleCameraSettle() {
        wheelSettle?.cancel()
        wheelSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            app.settleCamera()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let url = item as? URL { return url }
                        if let data = item as? Data {
                            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                                return URL(string: s) ?? URL(fileURLWithPath: s)
                            }
                            // Sometimes the provider hands a bookmark/file path as raw bytes of a URL string.
                            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
                        }
                        if let s = item as? String { return URL(string: s) ?? URL(fileURLWithPath: s) }
                        return nil
                    }()
                    guard let url else { return }
                    Task { @MainActor in
                        app.drop(urls: [url], at: app.lastWorld)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // No file:// URL representation (e.g. a screenshot's drag
                // proxy while its file is still being written, or any raw
                // bitmap drag) — fall back to the in-memory image data, same
                // path Cmd+V paste already uses.
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in
                        app.addImageCard(fromRawImage: image, at: app.lastWorld, alt: "Dropped image")
                    }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        app.drop(urls: [url], at: app.lastWorld)
                    }
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
        let visible = Self.visibleCards(app: app, camera: camera, selected: selected)
        ZStack(alignment: .topLeading) {
            ForEach(visible) { card in
                let editingBoost: Double = (app.editingID == card.id && card.kind == .text) ? 10_000 : 0
                CardView(card: card, selected: selected.contains(card.id))
                    .zIndex(Double(card.z) + editingBoost)
            }
            if let preview = app.textCreatePreview {
                RoundedRectangle(cornerRadius: Format.cardBorderedRadius, style: .continuous)
                    .stroke(Theme.selection, lineWidth: 1 / max(camera.zoom, 0.01))
                    .background(Theme.selection.opacity(0.06))
                    .frame(width: max(1, preview.width), height: max(1, preview.height))
                    .offset(x: preview.minX, y: preview.minY)
                    .allowsHitTesting(false)
                    .zIndex(9_000)
            }
            if !app.snapGuides.isEmpty {
                let zoom = max(camera.zoom, 0.01)
                // Screen-constant thin stroke (matches purple guide refs).
                let stroke = 1.15 / zoom
                let dashOn = 5.5 / zoom
                let dashOff = 3.5 / zoom
                Canvas { context, _ in
                    for guide in app.snapGuides {
                        var path = Path()
                        switch guide.axis {
                        case .vertical:
                            path.move(to: CGPoint(x: guide.position, y: guide.start))
                            path.addLine(to: CGPoint(x: guide.position, y: guide.end))
                        case .horizontal:
                            path.move(to: CGPoint(x: guide.start, y: guide.position))
                            path.addLine(to: CGPoint(x: guide.end, y: guide.position))
                        }
                        let dash: [CGFloat] = guide.style == .dashed ? [dashOn, dashOff] : []
                        context.stroke(
                            path,
                            with: .color(Theme.snapGuide),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round, dash: dash)
                        )

                        guard guide.style == .spacing else { continue }
                        // Capsule ticks perpendicular to the guide, centered on each
                        // matched gap boundary — marks where the two equal gaps start/end.
                        let tickLength = 16.0 / zoom
                        let tickWidth = 3.4 / zoom
                        for t in guide.ticks {
                            var tickPath = Path()
                            let rect: CGRect
                            switch guide.axis {
                            case .vertical:
                                rect = CGRect(
                                    x: guide.position - tickLength / 2,
                                    y: t - tickWidth / 2,
                                    width: tickLength,
                                    height: tickWidth
                                )
                            case .horizontal:
                                rect = CGRect(
                                    x: t - tickWidth / 2,
                                    y: guide.position - tickLength / 2,
                                    width: tickWidth,
                                    height: tickLength
                                )
                            }
                            tickPath.addRoundedRect(in: rect, cornerSize: CGSize(width: tickWidth / 2, height: tickWidth / 2))
                            context.fill(tickPath, with: .color(Theme.snapGuide))
                        }
                    }
                }
                // Must fill the world layer — ideal Canvas size is ~0 and guides never paint.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .zIndex(9_500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scaleEffect(camera.zoom, anchor: .topLeading)
        .offset(x: camera.x, y: camera.y)
        // While the note editor is open, keep camera transforms instantaneous so the
        // dashed connector (screen-space) stays glued to the card.
        .animation(
            (ease && app.noteOpenID == nil) ? .easeOut(duration: 0.28) : nil,
            value: camera
        )
    }

    /// Viewport culling: every card was previously rendered unconditionally,
    /// each backed by a real AppKit view (NSTextView for `.text` cards) that
    /// `WorldLayer`'s single `.scaleEffect` re-lays-out as zoom changes —
    /// with a large board that's real work per frame regardless of what's
    /// actually on screen, and zooming out (bringing more of the board into
    /// nominal view) made it worse. Keep only cards whose frame intersects a
    /// padded viewport rect, plus anything selected/being-edited so a drag or
    /// edit session can never make its own card disappear mid-interaction.
    private static func visibleCards(app: AppModel, camera: Camera, selected: Set<String>) -> [Card] {
        guard let cards = app.activeLesson?.cards else { return [] }
        let viewport = app.viewport
        guard viewport.width > 0, viewport.height > 0 else { return cards }
        let zoom = max(camera.zoom, 0.01)
        let pad: CGFloat = 400 / zoom
        let minX = (-camera.x) / zoom - pad
        let minY = (-camera.y) / zoom - pad
        let maxX = (viewport.width - camera.x) / zoom + pad
        let maxY = (viewport.height - camera.y) / zoom + pad
        let visibleRect = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        return cards.filter { card in
            selected.contains(card.id) || app.editingID == card.id || card.frame.intersects(visibleRect)
        }
    }
}

/// Burst + format bar in screen space so zoom does not scale UI chrome (Ticket D).
struct CanvasScreenChrome: View {
    @Environment(AppModel.self) private var app
    let camera: Camera
    // Measured lazily via FormatBarSizeKey — stays nil until first render so the
    // bar never clamps against a guessed size and momentarily overflows the window.
    @State private var formatBarSize: CGSize?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let wave = app.textWave {
                    let w = wave.width * camera.zoom
                    let h = wave.height * camera.zoom
                    let screen = toScreen(CGPoint(x: wave.x, y: wave.y), camera)
                    let field = CGRect(x: screen.x - w / 2, y: screen.y - h / 2, width: w, height: h)
                    TextGaussianWave(
                        fieldFrame: field,
                        startDate: wave.startedAt,
                        gridStep: 24 * camera.zoom
                    ) {
                        if app.textWave?.id == wave.id { app.textWave = nil }
                    }
                    .zIndex(10_000)
                }
                ForEach(app.deleteWaves, id: \.id) { (wave: DeleteWaveEvent) in
                    DeleteWaveChrome(wave: wave, camera: camera) {
                        app.finishDeleteWave(wave.id)
                    }
                    .zIndex(10_000)
                }
                if app.showsTextFormatBar,
                   let id = app.editingID,
                   let card = app.activeLesson?.cards.first(where: { $0.id == id && $0.kind == .text })
                {
                    let placement = formatBarPlacement(
                        card: card,
                        barSize: formatBarSize ?? .zero,
                        canvasSize: CGSize(
                            width: geo.size.width,
                            height: AppModel.visibleChromeHeight(fallback: geo.size.height)
                        )
                    )
                    TextFormatBar(card: card)
                        .fixedSize(horizontal: true, vertical: true)
                        .background(
                            GeometryReader { barGeo in
                                Color.clear.preference(key: FormatBarSizeKey.self, value: barGeo.size)
                            }
                        )
                        .onPreferenceChange(FormatBarSizeKey.self) { formatBarSize = $0 }
                        // Top-leading of the bar at `placement` — never centered over the text.
                        .offset(x: placement.x, y: placement.y)
                        .opacity(formatBarSize == nil ? 0 : 1)
                        .zIndex(20_000)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // Empty chrome must not eat canvas / sidebar hits.
        .allowsHitTesting(app.showsTextFormatBar || app.textWave != nil || !app.deleteWaves.isEmpty)
    }

    /// Top-left of the format bar so its top edge clears the selection (or sits above if no room below).
    private func formatBarPlacement(card: Card, barSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let gap: CGFloat = 12
        let margin: CGFloat = 8
        let sel = app.textSelectionScreenRect
        let midX: CGFloat
        let belowY: CGFloat
        let aboveY: CGFloat
        if let rect = sel {
            midX = rect.midX
            belowY = rect.maxY + gap
            aboveY = rect.minY - gap - barSize.height
        } else {
            let under = toScreen(
                CGPoint(x: card.x + card.previewWidth / 2, y: card.y + card.previewHeight),
                camera
            )
            midX = under.x
            belowY = under.y + gap
            aboveY = under.y - card.previewHeight * camera.zoom - gap - barSize.height
        }
        let fitsBelow = belowY + barSize.height + margin <= canvasSize.height
        let topY = fitsBelow ? belowY : max(margin, aboveY)
        let left = midX - barSize.width / 2
        let clampedX = min(max(margin, left), max(margin, canvasSize.width - barSize.width - margin))
        return CGPoint(x: clampedX, y: topY)
    }

    private func toScreen(_ world: CGPoint, _ cam: Camera) -> CGPoint {
        CGPoint(x: world.x * cam.zoom + cam.x, y: world.y * cam.zoom + cam.y)
    }
}

private struct DeleteWaveChrome: View {
    let wave: DeleteWaveEvent
    let camera: Camera
    var onComplete: () -> Void

    var body: some View {
        let w = wave.width * camera.zoom
        let h = wave.height * camera.zoom
        let screen = CGPoint(x: wave.x * camera.zoom + camera.x, y: wave.y * camera.zoom + camera.y)
        let field = CGRect(x: screen.x - w / 2, y: screen.y - h / 2, width: w, height: h)
        let step = 24 * camera.zoom
        let ox: CGFloat = {
            var v = camera.x.truncatingRemainder(dividingBy: step)
            if v > 0 { v -= step }
            return v
        }()
        let oy: CGFloat = {
            var v = camera.y.truncatingRemainder(dividingBy: step)
            if v > 0 { v -= step }
            return v
        }()
        return DeleteHalftoneWave(
            fieldFrame: field,
            cornerRadius: CGFloat(wave.cornerRadius) * camera.zoom,
            startDate: wave.startedAt,
            gridStep: step,
            gridOrigin: CGPoint(x: ox, y: oy),
            onComplete: onComplete
        )
    }
}

private struct FormatBarSizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .init(width: 260, height: 44)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
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

import AppKit
import SwiftUI

struct FloatingToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            toolButton("square.and.arrow.up", "File") { app.pickFiles() }
            toolButton("textformat", "Text", app.tool == .text) {
                app.tool = app.tool == .text ? .select : .text
            }
            toolButton("square.dashed", "Frame") {}
            toolButton("link", "Link", app.tool == .link) { app.linkPrompt = true }
            toolButton("pencil", "Pen", app.tool == .draw) {
                app.tool = app.tool == .draw ? .select : .draw
            }
            toolButton("cursorarrow", "Select", app.tool == .select) { app.tool = .select }
        }
        .padding(6)
        .chromePill(22)
    }

    private func toolButton(_ system: String, _ title: String, _ active: Bool = false, _ action: @escaping () -> Void) -> some View {
        HoverTool(system: system, title: title, active: active, action: action)
    }
}

private struct HoverTool: View {
    let system: String
    let title: String
    var active = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? Color.white : (scheme == .dark ? Color.white.opacity(0.9) : Color(red: 0.23, green: 0.23, blue: 0.24)))
                .background(
                    active ? Theme.ink : (hover ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct ZoomControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            Button { zoom(1 / 1.15) } label: {
                Image(systemName: "minus").frame(width: 28, height: 32)
            }
            .help("Zoom out")
            Button(action: fit) {
                Circle().fill(Theme.ink).frame(width: 7, height: 7)
                    .frame(width: 28, height: 32)
            }
            .help("Fit")
            Button { zoom(1.15) } label: {
                Image(systemName: "plus").frame(width: 28, height: 32)
            }
            .help("Zoom in")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color(red: 0.23, green: 0.23, blue: 0.24))
        .padding(.horizontal, 2)
        .frame(height: 32)
        .chromePill(10)
    }

    private func zoom(_ factor: Double) {
        guard let cam = app.activeLesson?.camera else { return }
        app.cameraEase = true
        app.setCamera(zoom: Format.clamp(cam.zoom * factor, 0.2, 3))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { app.cameraEase = false }
    }

    private func fit() {
        guard let lesson = app.activeLesson else { return }
        app.cameraEase = true
        if lesson.cards.isEmpty {
            app.setCamera(40, 36, zoom: 1)
        } else {
            let minX = lesson.cards.map(\.x).min() ?? 0
            let minY = lesson.cards.map(\.y).min() ?? 0
            let maxX = lesson.cards.map { $0.x + $0.width }.max() ?? 1
            let maxY = lesson.cards.map { $0.y + $0.height }.max() ?? 1
            let zoom = Format.clamp(min(1200 / (maxX - minX + 80), 800 / (maxY - minY + 80)), 0.3, 1.4)
            app.setCamera(40 - minX * zoom, 36 - minY * zoom, zoom: zoom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { app.cameraEase = false }
    }
}

struct MinimapView: View {
    @Environment(AppModel.self) private var app
    private let w = 280.0
    private let h = 188.0
    private let pad = 40.0

    var body: some View {
        if let lesson = app.activeLesson, !lesson.cards.isEmpty {
            let cards = lesson.cards
            let minX = cards.map(\.x).min() ?? 0
            let minY = cards.map(\.y).min() ?? 0
            let maxX = cards.map { $0.x + $0.previewWidth }.max() ?? 1
            let maxY = cards.map { $0.y + $0.previewHeight }.max() ?? 1
            let bw = max(1, maxX - minX + pad * 2)
            let bh = max(1, maxY - minY + pad * 2)
            let scale = min(w / bw, h / bh)
            let ox = (w - bw * scale) / 2
            let oy = (h - bh * scale) / 2
            let cam = lesson.camera
            let zoom = max(cam.zoom, 0.01)
            let viewW = max(app.viewport.width, 1)
            let viewH = max(app.viewport.height, 1)

            Canvas { context, _ in
                for card in cards {
                    let r = CGRect(
                        x: ox + (card.x - minX + pad) * scale,
                        y: oy + (card.y - minY + pad) * scale,
                        width: max(4, card.previewWidth * scale),
                        height: max(4, card.previewHeight * scale)
                    )
                    let on = app.selectedIDs.contains(card.id)
                    let color = on
                        ? Color(red: 0.48, green: 0.38, blue: 1)
                        : Theme.color(card.color ?? (card.kind == .image ? "#C5C7CC" : "#D8DADD"))
                    context.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
                }
                let visible = CGRect(
                    x: ox + (-cam.x / zoom - minX + pad) * scale,
                    y: oy + (-cam.y / zoom - minY + pad) * scale,
                    width: (viewW / zoom) * scale,
                    height: (viewH / zoom) * scale
                )
                context.stroke(
                    Path(roundedRect: visible, cornerRadius: 3),
                    with: .color(Color(red: 0.48, green: 0.38, blue: 1).opacity(0.9)),
                    lineWidth: 1.5
                )
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.chromeBorder))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pan(to: value.location, scale: scale, ox: ox, oy: oy, minX: minX, minY: minY, zoom: zoom, persist: false)
                    }
                    .onEnded { value in
                        pan(to: value.location, scale: scale, ox: ox, oy: oy, minX: minX, minY: minY, zoom: zoom, persist: true)
                    }
            )
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
        }
    }

    private func pan(to location: CGPoint, scale: Double, ox: Double, oy: Double, minX: Double, minY: Double, zoom: Double, persist: Bool) {
        guard scale > 0 else { return }
        let worldX = (location.x - ox) / scale + minX - pad
        let worldY = (location.y - oy) / scale + minY - pad
        app.cameraEase = false
        app.setCamera(
            app.viewport.width / 2 - worldX * zoom,
            app.viewport.height / 2 - worldY * zoom,
            persist: persist
        )
    }
}

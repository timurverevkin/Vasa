import AppKit
import SwiftUI

struct ZoomControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var hoverOut = false
    @State private var hoverFit = false
    @State private var hoverIn = false

    var body: some View {
        HStack(spacing: 0) {
            Button { zoom(1 / 1.15) } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 32)
                    .background(
                        hoverOut ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoverOut = inside
                        if inside { AppSounds.play(.hover) }
                    }
            }
            .help("Zoom out")
            Button(action: fit) {
                Circle().fill(Theme.primaryInk(scheme)).frame(width: 7, height: 7)
                    .frame(width: 28, height: 32)
                    .background(
                        hoverFit ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoverFit = inside
                        if inside { AppSounds.play(.hover) }
                    }
            }
            .help("Fit")
            Button { zoom(1.15) } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 32)
                    .background(
                        hoverIn ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoverIn = inside
                        if inside { AppSounds.play(.hover) }
                    }
            }
            .help("Zoom in")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.primaryInk(scheme))
        .padding(.horizontal, 2)
        .frame(height: 32)
        .chromePill(10)
    }

    private func zoom(_ factor: Double) {
        guard let cam = app.activeLesson?.camera else { return }
        let newZoom = Format.clamp(cam.zoom * factor, 0.2, 3)
        let vw = app.viewport.width
        let vh = app.viewport.height
        let center = CGPoint(x: vw / 2, y: vh / 2)
        // Convert viewport center to world coordinates, then adjust camera so the
        // same world point stays under the cursor.
        let wx = (center.x - cam.x) / cam.zoom
        let wy = (center.y - cam.y) / cam.zoom
        app.cameraEase = true
        app.setCamera(center.x - wx * newZoom, center.y - wy * newZoom, zoom: newZoom, persist: false)
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
    @Environment(\.colorScheme) private var scheme
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
                        : Theme.color(card.color ?? (card.kind == .image
                            ? (scheme == .dark ? "#5C5E66" : "#C5C7CC")
                            : (scheme == .dark ? "#6A6C74" : "#D8DADD")))
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
            .background(Theme.cardSurface(scheme).opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline(scheme)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.08), radius: 10, y: 3)
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

/// Pen / eraser / thickness / color — shown while the draw tool is active.
struct DrawInkBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var colorsOpen = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                toolButton(system: "pencil.tip", mode: .pen)
                toolButton(system: "eraser", mode: .eraser)
                DrawThicknessSlider(value: Binding(
                    get: { app.drawWidth },
                    set: { app.drawWidth = min(28, max(1, $0)) }
                ))
                colorButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .chromePill(14)

            Button {
                app.tool = .select
                app.drawMode = .pen
                app.activeInkCardID = nil
                colorsOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primaryInk(scheme))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .chromePill(10)
        }
        .overlay(alignment: .topLeading) {
            if colorsOpen {
                ColorPalette(
                    current: app.drawColorCustom ? app.drawColor : nil,
                    onReset: {
                        app.drawColor = "#111318"
                        app.drawColorCustom = false
                        app.recolorActiveInk("#111318")
                        colorsOpen = false
                    }
                ) { hex in
                    app.drawColor = hex
                    app.drawColorCustom = true
                    app.recolorActiveInk(hex)
                    colorsOpen = false
                }
                .padding(6)
                .chromePill(12)
                .offset(y: 44)
                .padding(.leading, 120)
            }
        }
    }

    private func toolButton(system: String, mode: DrawMode) -> some View {
        let on = app.drawMode == mode
        return Button {
            app.drawMode = mode
            AppSounds.playTap()
        } label: {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.white : Theme.primaryInk(scheme))
                .frame(width: 28, height: 28)
                .background(on ? Theme.selectFill(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode == .pen ? "Pen" : "Eraser")
    }

    private var colorButton: some View {
        Button {
            colorsOpen.toggle()
            AppSounds.playTap()
        } label: {
            Group {
                if app.drawColorCustom {
                    Circle()
                        .fill(Theme.color(app.drawColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Theme.hairline(scheme), lineWidth: 1))
                } else {
                    HalfFilledColorGlyph(size: 16)
                }
            }
            .frame(width: 28, height: 28)
            .background(
                colorsOpen ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help("Ink color")
    }
}

/// Gray capsule track + white thumb with dark ring (matches draw toolbar refs).
private struct DrawThicknessSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 1...28
    @Environment(\.colorScheme) private var scheme

    private let trackH: CGFloat = 6
    private let thumb: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = thumb / 2 + max(0, min(1, t)) * max(0, w - thumb)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(scheme == .dark ? Color.white.opacity(0.14) : Color(white: 0.90))
                    .frame(height: trackH)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Theme.primaryInk(scheme), lineWidth: 3.5))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let u = (drag.location.x - thumb / 2) / max(1, w - thumb)
                        let clamped = min(1, max(0, u))
                        value = range.lowerBound + Double(clamped) * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(width: 118, height: 28)
    }
}

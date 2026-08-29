import AppKit
import SwiftUI

struct CardRoundedRect: InsettableShape {
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard insetRect.width > 0, insetRect.height > 0 else { return Path() }
        let r = min(max(radius - insetAmount, 0), min(insetRect.width, insetRect.height) / 2)
        // Continuous corners anti-alias cleanly under canvas zoom (circular looks ribbed).
        return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: insetRect)
    }

    func inset(by amount: CGFloat) -> CardRoundedRect {
        CardRoundedRect(radius: radius, insetAmount: insetAmount + amount)
    }
}

struct NotchedRoundedRect: Shape {
    var radius: CGFloat
    var cut: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let gap = min(cut, max(4, r * 0.35))
        let w = rect.width
        let h = rect.height
        var path = Path()

        // Continuous rounded frame with a cut-out at bottom-trailing (resize notch).
        // Corner arc itself is drawn separately as SelectionNotchMark (darker “засечка”).
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addArc(
            center: CGPoint(x: w - r, y: r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: w, y: h - r - gap))

        path.move(to: CGPoint(x: w - r - gap, y: h))
        path.addLine(to: CGPoint(x: r, y: h))
        path.addArc(
            center: CGPoint(x: r, y: h - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(
            center: CGPoint(x: r, y: r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        return path
    }
}

/// Darker bottom-trailing corner arc sitting in the notch gap (serif / засечка).
struct SelectionNotchMark: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w, y: h - r))
        path.addArc(
            center: CGPoint(x: w - r, y: h - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        return path
    }
}

enum SelectionLook: Equatable {
    case solid
    case dashed
    case extracting
}

struct SelectionFrame: View {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 16
    /// Outset so the stroke sits just outside the content (text cards use 0 — hug glyphs).
    var outset: CGFloat = 3
    /// When false, draw a continuous rounded rect (no resize cutout).
    var notched = true
    /// WorldLayer zoom — keep stroke ~1.5 screen points so it stays smooth when zoomed.
    var zoom: CGFloat = 1
    var look: SelectionLook = .solid

    private var strokeWidth: CGFloat { 1.5 / max(zoom, 0.01) }
    private var cut: CGFloat { max(4, min(6, radius * 0.45)) }
    private var showNotch: Bool { notched && look == .solid }

    private var strokeColor: Color {
        look == .extracting ? Theme.extractStroke : Theme.selectionStroke(scheme)
    }

    private var strokeStyle: StrokeStyle {
        let z = max(zoom, 0.01)
        let dash: [CGFloat] = look == .solid ? [] : [7 / z, 5 / z]
        return StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round, dash: dash)
    }

    var body: some View {
        Group {
            if showNotch {
                ZStack {
                    NotchedRoundedRect(radius: radius, cut: cut)
                        .stroke(strokeColor, style: strokeStyle)
                    SelectionNotchMark(radius: radius)
                        .stroke(Theme.selectionNotch(scheme), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
                }
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(strokeColor, style: strokeStyle)
            }
        }
        .padding(-outset)
        .allowsHitTesting(false)
    }
}

struct CardSelection: View {
    let selected: Bool
    var showNotch: Bool
    var radius: CGFloat = 16
    /// Outset for the selection stroke (0 hugs text cards tightly).
    var outset: CGFloat = 3
    /// Live card size in world units — snapshotted once at gesture start.
    var size: CGSize
    var zoom: CGFloat
    var look: SelectionLook = .solid
    /// Absolute world size for the card (`start + screenDelta / zoom`).
    var onResize: (CGSize) -> Void
    var onEnd: () -> Void

    @State private var startSize: CGSize?

    var body: some View {
        if selected {
            ZStack(alignment: .bottomTrailing) {
                SelectionFrame(radius: radius, outset: outset, notched: showNotch, zoom: zoom, look: look)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                if showNotch, look == .solid {
                    // Invisible hit target on the cut-out corner — no filled circle.
                    Color.clear
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .offset(x: 6, y: 6)
                        .onHover { inside in
                            if inside {
                                if #available(macOS 15.0, *) {
                                    NSCursor.frameResize(position: .bottomRight, directions: [.all]).push()
                                } else {
                                    NSCursor.crosshair.push()
                                }
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .highPriorityGesture(resizeGesture)
                }
            }
            // Critical: without this, ZStack can shrink to the notch hit-target and the
            // frame floats under the glyphs instead of wrapping the card.
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private var resizeGesture: some Gesture {
        // Stable canvas space (outside WorldLayer.scaleEffect) — not the moving handle.
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if startSize == nil {
                    startSize = size
                }
                guard let origin = startSize else { return }
                let z = max(zoom, 0.01)
                // Absolute from gesture start — never accumulate frame-to-frame deltas.
                let proposed = CGSize(
                    width: origin.width + value.translation.width / z,
                    height: origin.height + value.translation.height / z
                )
                onResize(Self.clamp(proposed))
            }
            .onEnded { _ in
                startSize = nil
                onEnd()
            }
    }

    /// Defensive floor/ceiling so a single bad sample cannot explode the frame.
    static func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(2_400, max(TextToolReducer.minSized.width, size.width)),
            height: min(2_400, max(TextToolReducer.minSized.height, size.height))
        )
    }
}

struct MenuRow: View {
    var system: String?
    var icon: AppIcon?
    var serifA = false
    var swatch: String?
    let title: String
    var shortcut: String?
    var destructive = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    init(system: String, title: String, shortcut: String? = nil, destructive: Bool = false, action: @escaping () -> Void) {
        self.system = system
        self.title = title
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
    }

    init(icon: AppIcon, title: String, shortcut: String? = nil, destructive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
        self.destructive = destructive
        self.action = action
    }

    init(serifA: Bool, title: String, action: @escaping () -> Void) {
        self.serifA = serifA
        self.title = title
        self.action = action
    }

    init(swatch: String?, title: String, action: @escaping () -> Void) {
        self.swatch = swatch
        self.title = title
        self.action = action
    }

    var body: some View {
        let dark = scheme == .dark
        let highlight = hover && !destructive
        let fill: Color = {
            if !hover { return .clear }
            if dark && !destructive { return .white }
            return Theme.hover
        }()
        let ink: Color = {
            if destructive { return Color(red: 1, green: 0.23, blue: 0.19) }
            if dark && highlight { return Theme.ink }
            if dark { return Color.white.opacity(0.92) }
            return Theme.ink
        }()
        Button {
            if destructive { AppSounds.play(.caution) }
            else { AppSounds.playTap() }
            action()
        } label: {
            HStack(spacing: 10) {
                if serifA {
                    AppIconView(icon: .rename, size: 15)
                        .frame(width: 16)
                } else if title == "Item color" || title == "Group color" {
                    if let swatch {
                        Circle()
                            .fill(Theme.color(swatch))
                            .frame(width: 16, height: 16)
                    } else {
                        AppIconView(icon: .itemColor, size: 15)
                            .frame(width: 16)
                    }
                } else if let icon {
                    AppIconView(icon: icon, size: 15)
                        .frame(width: 16)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: 13))
                        .frame(width: 16)
                }
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Keycap(shortcut, destructive: destructive)
                }
            }
            .foregroundStyle(ink)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            if inside { AppSounds.play(.hover) }
        }
    }
}

struct Keycap: View {
    let text: String
    var destructive = false

    init(_ text: String, destructive: Bool = false) {
        self.text = text
        self.destructive = destructive
    }

    var body: some View {
        let ink = destructive ? Color(red: 1, green: 0.23, blue: 0.19) : Theme.muted
        let line = destructive
            ? Color(red: 1, green: 0.23, blue: 0.19).opacity(0.35)
            : Color(red: 0.86, green: 0.86, blue: 0.88)
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(line, lineWidth: 1)
            )
    }
}

struct StyleMenuRow: View {
    var leading: String? = nil
    let title: String
    var selected = false
    var italicLeading = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button {
            AppSounds.playTap()
            action()
        } label: {
            HStack(spacing: 10) {
                if let leading {
                    Text(leading)
                        .font(
                            italicLeading
                                ? .system(size: 13, weight: .semibold, design: .serif).italic()
                                : .system(size: 13, weight: .semibold, design: .serif)
                        )
                        .frame(width: 28, alignment: .center)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Theme.primaryInk(scheme))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.selectFill(scheme) : (hover ? Theme.elevHover(scheme) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            if inside { AppSounds.play(.hover) }
        }
    }
}

struct ColorPalette: View {
    var current: String?
    /// When set, the first swatch is a default/reset control (`circle.lefthalf.filled`).
    var onReset: (() -> Void)? = nil
    var onPick: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(swatches(for: row), id: \.self) { entry in
                            switch entry {
                            case .reset:
                                resetSwatch
                            case .color(let value):
                                ColorSwatchButton(hex: value, selected: matches(value)) { onPick(value) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("#")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField("", text: $hex)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospaced())
                    .onSubmit { submitHex() }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onAppear {
            hex = (current ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }
        .onChange(of: current) { _, value in
            hex = (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }
    }

    private enum Swatch: Hashable {
        case reset
        case color(String)
    }

    private func swatches(for row: Int) -> [Swatch] {
        if onReset != nil {
            // 2×6 grid: reset + 11 palette colors.
            let colors = Array(Theme.itemColors.prefix(11))
            if row == 0 {
                return [.reset] + colors.prefix(5).map { .color($0) }
            }
            return colors.dropFirst(5).prefix(6).map { .color($0) }
        }
        let slice = Theme.itemColors[(row * 6)..<((row + 1) * 6)]
        return slice.map { .color($0) }
    }

    private var resetSwatch: some View {
        ResetColorSwatch(selected: current == nil, action: { onReset?() })
    }

    private func matches(_ value: String) -> Bool {
        guard let current else { return false }
        return current.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
            == value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    }

    private func submitHex() {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "#", with: "")
        guard value.count == 3 || value.count == 6 else { return }
        onPick("#" + value)
    }
}

struct ColorSwatchButton: View {
    let hex: String
    var selected = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button {
            AppSounds.playTap()
            action()
        } label: {
            Circle()
                .fill(Theme.color(hex))
                .frame(width: 16, height: 16)
                .padding(6)
                .background(
                    selected || hover
                        ? (selected
                            ? Theme.ink.opacity(scheme == .dark ? 0.35 : 0.08)
                            : (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover))
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .onHover { inside in
            hover = inside
            if inside { AppSounds.play(.hover) }
        }
        }
        .buttonStyle(.plain)
    }
}

/// Default / unset color glyph — outlined circle, half filled on a 45° diagonal (dark below).
struct HalfFilledColorGlyph: View {
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, canvasSize in
            let ink = scheme == .dark ? Color.white : Theme.ink
            let s = min(canvasSize.width, canvasSize.height)
            let pad = s * 0.06
            let rect = CGRect(
                x: (canvasSize.width - s) / 2 + pad,
                y: (canvasSize.height - s) / 2 + pad,
                width: s - pad * 2,
                height: s - pad * 2
            )
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2

            context.fill(Path(ellipseIn: rect), with: .color(scheme == .dark ? Color.black.opacity(0.35) : .white))

            // 45° split from top-left to bottom-right. Filled half sits below the line.
            var half = Path()
            half.move(to: center)
            half.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(45),
                endAngle: .degrees(225),
                clockwise: true
            )
            half.closeSubpath()
            context.fill(half, with: .color(ink))

            context.stroke(
                Path(ellipseIn: rect),
                with: .color(ink),
                lineWidth: max(1.25, s * 0.11)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ResetColorSwatch: View {
    var selected = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HalfFilledColorGlyph(size: 14)
                .frame(width: 16, height: 16)
                .padding(6)
                .background(
                    selected || hover
                        ? (selected
                            ? Theme.ink.opacity(scheme == .dark ? 0.35 : 0.08)
                            : (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover))
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .onHover { inside in
            hover = inside
            if inside { AppSounds.play(.hover) }
        }
        }
        .buttonStyle(.plain)
        .help("Default color")
    }
}

struct HoverIconButton: View {
    var system: String?
    var icon: AppIcon?
    var size: CGFloat = 34
    var active = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    init(system: String, size: CGFloat = 34, active: Bool = false, action: @escaping () -> Void) {
        self.system = system
        self.size = size
        self.active = active
        self.action = action
    }

    init(icon: AppIcon, size: CGFloat = 34, active: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.active = active
        self.action = action
    }

    var body: some View {
        Button {
            AppSounds.playTap()
            action()
        } label: {
            Group {
                if let icon {
                    AppIconView(icon: icon, size: size * 0.42)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color.white : (scheme == .dark ? Color.white.opacity(0.9) : Color(red: 0.23, green: 0.23, blue: 0.24)))
            .frame(width: size, height: size)
            .background(
                active ? Theme.ink : (hover ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { inside in
            hover = inside
            if inside { AppSounds.play(.hover) }
        }
        }
        .buttonStyle(.plain)
    }
}

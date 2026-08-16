import AppKit
import SwiftUI

struct CardRoundedRect: InsettableShape {
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard insetRect.width > 0, insetRect.height > 0 else { return Path() }
        let r = min(max(radius - insetAmount, 0), min(insetRect.width, insetRect.height) / 2)
        return Path(roundedRect: insetRect, cornerRadius: r)
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

struct SelectionFrame: View {
    var radius: CGFloat = 16

    var body: some View {
        NotchedRoundedRect(radius: radius, cut: 5)
            .stroke(Theme.selectStroke, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .padding(-3)
            .allowsHitTesting(false)
    }
}

struct CardSelection: View {
    let selected: Bool
    var showNotch: Bool
    var radius: CGFloat = 16
    var onResize: (CGSize) -> Void
    var onEnd: () -> Void

    @State private var last: CGSize = .zero

    var body: some View {
        if selected {
            ZStack(alignment: .bottomTrailing) {
                SelectionFrame(radius: radius)
                if showNotch {
                    Color.clear
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .offset(x: 6, y: 6)
                        .onHover { inside in
                            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let delta = CGSize(
                                        width: value.translation.width - last.width,
                                        height: value.translation.height - last.height
                                    )
                                    last = value.translation
                                    onResize(delta)
                                }
                                .onEnded { _ in
                                    last = .zero
                                    onEnd()
                                }
                        )
                }
            }
        }
    }
}

struct MenuRow: View {
    var system: String?
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
        Button(action: action) {
            HStack(spacing: 10) {
                if serifA {
                    Text("A")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .frame(width: 16)
                } else if swatch != nil || title == "Item color" {
                    Circle()
                        .fill(Theme.color(swatch ?? "#8E8E93"))
                        .overlay {
                            if swatch == nil {
                                AngularGradient(colors: [.red, .yellow, .green, .blue, .red], center: .center)
                                    .clipShape(Circle())
                            }
                        }
                        .frame(width: 16, height: 16)
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
            .onHover { hover = $0 }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
        let line = destructive ? Color(red: 1, green: 0.23, blue: 0.19).opacity(0.28) : Color(red: 0.86, green: 0.86, blue: 0.88)
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(line)
            )
    }
}

struct StyleMenuRow: View {
    let title: String
    var selected = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    selected ? Theme.select : (hover ? Theme.hover : Color.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ColorPalette: View {
    var current: String?
    var onPick: (String) -> Void
    @State private var hex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(Array(Theme.itemColors[(row * 6)..<((row + 1) * 6)]), id: \.self) { value in
                            ColorSwatchButton(hex: value, selected: matches(value)) { onPick(value) }
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
            .background(Theme.hover.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        Button(action: action) {
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
                .onHover { hover = $0 }
        }
        .buttonStyle(.plain)
    }
}

struct HoverIconButton: View {
    let system: String
    var size: CGFloat = 34
    var active = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.white : (scheme == .dark ? Color.white.opacity(0.9) : Color(red: 0.23, green: 0.23, blue: 0.24)))
                .frame(width: size, height: size)
                .background(
                    active ? Theme.ink : (hover ? (scheme == .dark ? Color.white.opacity(0.12) : Theme.hover) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
        .buttonStyle(.plain)
    }
}

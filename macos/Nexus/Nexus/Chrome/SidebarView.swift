import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                IconButton("sidebar.left", action: app.toggleSidebar)
                Spacer()
                IconButton("plus.square", action: app.addLesson)
                IconButton("magnifyingglass") { app.paletteOpen = true }
                IconButton("gearshape") { app.settingsOpen = true }
            }
            .foregroundStyle(Color(red: 0.43, green: 0.43, blue: 0.45))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(app.library.lessons.enumerated()), id: \.element.id) { index, lesson in
                        if index == 2 {
                            Rectangle()
                                .fill(Theme.line)
                                .frame(height: 1)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                        }
                        BoardRow(lesson: lesson)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .frame(width: 252)
        .background(
            scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.18) : Color.white,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.chromeBorder))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
        .alert("Rename", isPresented: Binding(
            get: { app.renameLessonID != nil },
            set: { if !$0 { app.renameLessonID = nil } }
        )) {
            RenameField()
            Button("OK") {}
            Button("Cancel", role: .cancel) { app.renameLessonID = nil }
        }
    }
}

struct IconButton: View {
    let system: String
    let action: () -> Void
    @State private var hover = false

    init(_ system: String, action: @escaping () -> Void) {
        self.system = system
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(hover ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
        .buttonStyle(.plain)
        .background(HoverCatcher { hover = $0 })
    }
}

struct BoardRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let lesson: Lesson
    @State private var hovering = false

    var body: some View {
        let active = lesson.id == app.library.activeLessonId
        let menuOpen = app.boardMenuID == lesson.id
        let hoverFill = scheme == .dark ? Color.white.opacity(0.1) : Theme.hover
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                BoardThumb(url: lesson.thumb)
                Text(lesson.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? Color.white : (scheme == .dark ? Color.white.opacity(0.92) : Theme.ink))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.openLesson(lesson.id) }
            Button {
                if menuOpen {
                    app.boardMenuID = nil
                } else {
                    if let window = NSApp.keyWindow {
                        let loc = window.mouseLocationOutsideOfEventStream
                        let height = window.contentView?.bounds.height ?? 0
                        app.boardMenuY = max(10, height - loc.y - 8)
                    }
                    app.boardMenuID = lesson.id
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(active ? Color.white.opacity(0.9) : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(
                        hovering || menuOpen ? (active ? Color.white.opacity(0.14) : Theme.hover) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(active ? Theme.select : (hovering || menuOpen ? hoverFill : Color.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(
            HoverCatcher { hovering = $0 }
        )
        .padding(.horizontal, 8)
        .zIndex(menuOpen ? 80 : (hovering ? 2 : 0))
    }
}

struct BoardThumb: View {
    let url: String?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96))
            if let url {
                RemoteImage(src: url).scaledToFill()
            }
        }
        .frame(width: 32, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.06)))
    }
}

struct LessonMenu: View {
    @Environment(AppModel.self) private var app
    let lesson: Lesson

    var body: some View {
        Text("Last edited: \(Format.relativeTime(lesson.updatedAt))\nFile size: \(Format.bytes(lesson.bytes))")
        Divider()
        Button("Rename") { app.renameLessonID = lesson.id }
        Button(lesson.pinned == true ? "Unpin" : "Pin") { app.pinLesson(lesson.id) }
        Button("Duplicate") { app.duplicateLesson(lesson.id) }
        Button("Reveal in Finder", action: app.revealInFinder)
        Divider()
        Button("Delete", role: .destructive) {
            Task {
                let alert = NSAlert()
                alert.messageText = "Delete “\(lesson.title)”?"
                alert.informativeText = "This board will be removed from the library."
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    app.deleteLesson(lesson.id)
                }
            }
        }
    }
}

struct RenameField: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        TextField("Name", text: Binding(
            get: {
                guard let id = app.renameLessonID else { return "" }
                return app.library.lessons.first { $0.id == id }?.title ?? ""
            },
            set: { value in
                if let id = app.renameLessonID { app.renameLesson(id, value) }
            }
        ))
    }
}

struct ProjectChip: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Button(action: app.toggleSidebar) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                Text(app.activeLesson?.title ?? "Untitled Project")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 32)
            .chromePill(10)
        }
        .buttonStyle(.plain)
    }
}

struct HoverCatcher: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onHover = onHover
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button { app.settingsOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 16) {
                settingRow("circle", "Theme", shortcut: "⌘T") {
                    Segmented(
                        options: [("Light", AppSettings.Appearance.light), ("Dark", .dark), ("Auto", .auto)],
                        value: app.settings.appearance
                    ) { app.settings.appearance = $0 }
                }
                settingRow("speaker.wave.2", "Sounds", shortcut: "⌘M") {
                    DualToggle(on: app.settings.sounds) { app.settings.sounds = $0 }
                }
                settingRow("square.grid.2x2", "Haptic feedback") {
                    DualToggle(on: app.settings.haptics) { app.settings.haptics = $0 }
                }
                settingRow("rectangle", "Interface", shortcut: "Tab") {
                    DualToggle(on: app.settings.showChrome, onLabel: "Show", offLabel: "Hide") {
                        app.settings.showChrome = $0
                    }
                }
                settingRow("circle.grid.3x3", "Canvas Grid") {
                    DualToggle(on: app.settings.showGrid, onLabel: "Show", offLabel: "Hide") {
                        app.settings.showGrid = $0
                    }
                }
                settingRow("arrow.up.and.down.and.arrow.left.and.right", "Snapping", shortcut: "⌘S") {
                    DualToggle(on: app.settings.snapping) { app.settings.snapping = $0 }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Projects Folder", systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 8) {
                        Text(displayPath)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button("Change", action: changeFolder)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.muted)
                Text("EMA App")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Version: 1.0")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            }
            .padding(14)
        }
        .frame(width: 252)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.chromeBorder))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
    }

    private var displayPath: String {
        app.settings.projectsFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.projectsFolder = url.path
            app.saveNow()
        }
    }

    private func settingRow<Content: View>(_ system: String, _ title: String, shortcut: String? = nil, @ViewBuilder control: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: system)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }
            control()
        }
    }
}

struct DualToggle: View {
    var on: Bool
    var onLabel = "On"
    var offLabel = "Off"
    var set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            pill(onLabel, on)
            pill(offLabel, !on)
        }
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pill(_ title: String, _ active: Bool) -> some View {
        Button {
            set(title == onLabel)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(active ? Theme.select : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct Segmented<Value: Equatable>: View {
    let options: [(String, Value)]
    var value: Value
    var set: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { title, option in
                Button {
                    set(option)
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(option == value ? Color.white : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(option == value ? Theme.select : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct BoardMenuCard: View {
    @Environment(AppModel.self) private var app
    let lesson: Lesson

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Format.relativeTime(lesson.updatedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text(Format.bytes(lesson.bytes))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 4)
            MenuRow(serifA: true, title: "Rename") {
                app.renameLessonID = lesson.id
                app.boardMenuID = nil
            }
            MenuRow(system: "pin", title: lesson.pinned == true ? "Unpin" : "Pin") {
                app.pinLesson(lesson.id)
                app.boardMenuID = nil
            }
            MenuRow(system: "plus.square.on.square", title: "Duplicate") {
                app.duplicateLesson(lesson.id)
                app.boardMenuID = nil
            }
            MenuRow(system: "square.and.arrow.up", title: "Export") {
                app.exportLesson(lesson.id)
                app.boardMenuID = nil
            }
            MenuRow(system: "folder", title: "Reveal in Finder") {
                app.revealInFinder()
                app.boardMenuID = nil
            }
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 4).padding(.vertical, 4)
            MenuRow(system: "trash", title: "Delete", destructive: true) {
                confirmDelete()
            }
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.chromeBorder))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .compositingGroup()
    }

    private func confirmDelete() {
        app.boardMenuID = nil
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

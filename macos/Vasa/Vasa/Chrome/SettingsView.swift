import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                AppIconView(icon: .panelOpen, size: 14)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button { app.settingsOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingRow("circle", "Theme", shortcut: "⌘T") {
                        Segmented(
                            options: [("Light", AppSettings.Appearance.light), ("Dark", .dark), ("Auto", .auto)],
                            value: app.settings.appearance
                        ) { app.settings.appearance = $0 }
                    }
                    settingRow("speaker.wave.2", "App Sounds", shortcut: "⌘M") {
                        DualToggle(on: app.settings.sounds) { next in
                            if next {
                                app.settings.sounds = true
                                AppSounds.playToggle(true)
                            } else {
                                AppSounds.playToggle(false)
                                app.settings.sounds = false
                            }
                        }
                    }
                    settingRow("square.grid.2x2", "Haptic feedback") {
                        DualToggle(on: app.settings.haptics) { next in
                            app.settings.haptics = next
                            AppSounds.playToggle(next)
                        }
                    }
                    settingRow("rectangle", "Interface", shortcut: "Tab") {
                        DualToggle(on: app.settings.showChrome, onLabel: "Show", offLabel: "Hide") { next in
                            app.settings.showChrome = next
                            AppSounds.playToggle(next)
                        }
                    }
                    settingRow("circle.grid.3x3", "Canvas Grid") {
                        DualToggle(on: app.settings.showGrid, onLabel: "Show", offLabel: "Hide") { next in
                            app.settings.showGrid = next
                            AppSounds.playToggle(next)
                        }
                    }
                    settingRow("arrow.up.and.down.and.arrow.left.and.right", "Snapping", shortcut: "⌘S") {
                        DualToggle(on: app.settings.snapping) { next in
                            app.settings.snapping = next
                            AppSounds.playToggle(next)
                        }
                    }

                    ChatProviderSettings()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Projects Folder", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primaryInk(scheme))
                        HStack(spacing: 8) {
                            Text(displayPath)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Button("Change", action: changeFolder)
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.muted)
                Text("Vasa")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Version: 1.0")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline(scheme)))
            }
            .padding(14)
        }
        .frame(width: 252)
        .frame(maxHeight: 760)
        .background(
            scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.18) : Color.white,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline(scheme)))
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.08), radius: 18, y: 6)
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
    /// Flips immediately on tap; cleared when `on` catches up from the model.
    @Environment(\.colorScheme) private var scheme
    @State private var pending: Bool?

    private var active: Bool { pending ?? on }

    var body: some View {
        HStack(spacing: 0) {
            pill(onLabel, active)
            pill(offLabel, !active)
        }
        .padding(2)
        .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: on) { _, value in
            if pending == value { pending = nil }
        }
    }

    private func pill(_ title: String, _ selected: Bool) -> some View {
        Button {
            let next = title == onLabel
            guard next != active else { return }
            pending = next
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                set(next)
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Theme.primaryInk(scheme))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(selected ? Theme.selectFill(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Segmented<Value: Equatable>: View {
    let options: [(String, Value)]
    var value: Value
    var set: (Value) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var pending: Value?

    private var active: Value { pending ?? value }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { title, option in
                Button {
                    guard option != active else { return }
                    pending = option
                    AppSounds.playTap()
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        set(option)
                    }
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(option == active ? Color.white : Theme.primaryInk(scheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(option == active ? Theme.selectFill(scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.elevHover(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: value) { _, newValue in
            if pending == newValue { pending = nil }
        }
    }
}

struct BoardMenuCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let lesson: Lesson

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Format.relativeTime(lesson.updatedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk(scheme))
                Spacer()
                // Same plate as the preview header: square hairline outline, no fill.
                Text(Format.bytes(lesson.bytes))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk(scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(Rectangle().stroke(Theme.hairline(scheme), lineWidth: 1))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.hairline(scheme)).frame(height: 1).padding(.horizontal, 4)
            MenuRow(icon: .rename, title: "Rename") {
                app.renameLessonID = lesson.id
                app.boardMenuID = nil
            }
            MenuRow(icon: .pin, title: lesson.pinned == true ? "Unpin" : "Pin") {
                app.pinLesson(lesson.id)
                app.boardMenuID = nil
            }
            MenuRow(icon: .duplicate, title: "Duplicate") {
                app.duplicateLesson(lesson.id)
                app.boardMenuID = nil
            }
            MenuRow(icon: .export, title: "Export") {
                app.exportLesson(lesson.id)
                app.boardMenuID = nil
            }
            MenuRow(icon: .revealInFinder, title: "Reveal in Finder") {
                app.revealInFinder()
                app.boardMenuID = nil
            }
            Rectangle().fill(Theme.hairline(scheme)).frame(height: 1).padding(.horizontal, 4).padding(.vertical, 4)
            MenuRow(icon: .delete, title: "Delete", destructive: true) {
                confirmDelete()
            }
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
        .background(Theme.cardSurface(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline(scheme)))
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

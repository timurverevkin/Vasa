import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.windows.forEach { HiddenTrafficLights.apply($0) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideLights(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func hideLights(_ note: Notification) {
        HiddenTrafficLights.apply(note.object as? NSWindow)
    }
}

@main
struct VasaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.saveNow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Board") { model.addLesson() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Search") { model.paletteOpen = true }
                    .keyboardShortcut("k")
                Button("Toggle Sidebar") { model.toggleSidebar() }
                    .keyboardShortcut("\\")
                // macOS-native alternate (Finder / Mail / Notes / Xcode); Notion’s ⌘\ stays primary.
                Button("Toggle Sidebar") { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Toggle Navigator") { model.navigatorOpen.toggle() }
                    .keyboardShortcut("`", modifiers: [])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { textAction(#selector(UndoManager.undo), else: { model.undo() }) }
                    .keyboardShortcut("z")
                Button("Redo") { textAction(#selector(UndoManager.redo), else: { model.redo() }) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { textAction(#selector(NSText.cut(_:)), else: {}) }
                    .keyboardShortcut("x")
                Button("Copy") { textAction(#selector(NSText.copy(_:)), else: { model.copySelected() }) }
                    .keyboardShortcut("c")
                Button("Paste") { textAction(#selector(NSText.paste(_:)), else: { model.paste(at: model.lastWorld) }) }
                    .keyboardShortcut("v")
                Button("Select All") { textAction(#selector(NSText.selectAll(_:)), else: { model.selectAllCards() }) }
                    .keyboardShortcut("a")
                Button("Duplicate") {
                    if !Self.editingText { model.duplicateSelected() }
                }
                    .keyboardShortcut("d")
                Button("Group") {
                    if !Self.editingText { model.groupSelection() }
                }
                    .keyboardShortcut("g")
                Button("Ungroup") {
                    if !Self.editingText { model.ungroupSelection() }
                }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Arrange") {
                    if !Self.editingText { model.arrangeSelection() }
                }
                Button("Delete") {
                    if Self.editingText {
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.deleteBackward(nil)
                    } else {
                        model.deleteSelected()
                    }
                }
                .keyboardShortcut(.delete)
            }
        }
    }

    private static var editingText: Bool {
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView { return view.isEditable }
        return NSApp.keyWindow?.firstResponder is NSText
    }

    private func textAction(_ selector: Selector, else fallback: () -> Void) {
        if Self.editingText {
            if selector == #selector(UndoManager.undo) {
                NSApp.keyWindow?.firstResponder?.undoManager?.undo()
                return
            }
            if selector == #selector(UndoManager.redo) {
                NSApp.keyWindow?.firstResponder?.undoManager?.redo()
                return
            }
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            fallback()
        }
    }
}

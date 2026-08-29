import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {
    var library: Library
    var selectedIDs: [String] = []
    var tool: Tool = .select {
        didSet {
            if oldValue == .text, tool != .text {
                switch textToolState {
                case .armed, .creating:
                    dispatchTextTool(.toolSwitched)
                case .idle, .editing:
                    break
                }
            }
            if oldValue == .draw, tool != .draw {
                activeInkCardID = nil
            }
        }
    }
    /// Pen vs eraser while `tool == .draw`.
    var drawMode: DrawMode = .pen
    var drawColor: String = "#111318"
    /// False while still on the default ink — swatch shows half-filled editor icon.
    var drawColorCustom = false
    var drawWidth: Double = 3
    /// Last ink card while the draw tool is active — survives accidental deselection.
    var activeInkCardID: String?
    var spaceDown = false
    var menu: MenuAnchor?
    /// Pure text-tool gesture SM — see `TextToolReducer`.
    var textToolState: TextToolState = .idle
    /// World-space drag-to-size rubber band while `.creating`.
    var textCreatePreview: CGRect?
    /// World-space threshold for the current gesture (`14 / zoom` at pointerDown).
    private var textToolThreshold: CGFloat = TextToolReducer.dragThreshold
    /// Wall-clock of the current text-tool pointerDown (tap-vs-drag time shield).
    @ObservationIgnored private var textToolPointerDownAt: Date?
    /// World origin captured at pointerDown (for short-gesture createBlank fallback).
    @ObservationIgnored private var textToolOrigin: CGPoint?
    var askAICardID: String?
    /// lessonId -> chat thread. Loaded lazily on first open in `startOrContinueChat`.
    var chatThreads: [String: ChatThread] = [:]
    private var dirtyChatLessonIDs: Set<String> = []
    var paletteOpen = false
    var lightbox: LightboxItem?
    var playingID: String?
    var playbackPaused = false
    var audioDetailID: String?
    var noteOpenID: String?
    var lastWorld = CGPoint(x: 120, y: 120)
    var cameraEase = false
    var editingID: String?
    /// Card-local point the double-click that opened `editingID` landed on — consumed once
    /// by `CanvasTextEditor`'s coordinator to place the caret there (word-selected) instead
    /// of wherever it was left after the previous editing session. The double-click itself
    /// never reaches the NSTextView (it's not hit-testable until `isEditable` flips on the
    /// next render pass), so AppKit's own click-to-position never fires on its own.
    var pendingTextCaret: (cardID: String, point: CGPoint)?
    /// Inline rename of a group plaque title.
    var editingGroupID: String?
    /// Keeps the live canvas text view while the format bar steals first responder.
    @ObservationIgnored weak var activeCanvasTextView: GrowingTextView?
    /// Non-zero while the user has a text selection (drives TextFormatBar visibility).
    var textSelectionLength: Int = 0
    /// Selection rect in top-left window coordinates for floating the format bar.
    var textSelectionScreenRect: CGRect?
    /// Last non-empty canvas text selection — survives format-bar focus steal.
    var textEditingRange = NSRange(location: 0, length: 0)
    /// Keeps the format bar visible while the pointer is over it (selection may clear on focus steal).
    var formatBarHovered = false
    var linkPrompt = false
    var renameLessonID: String?
    var settingsOpen = false
    /// Dedicated provider-config window opened from the "Provider" row in Settings.
    var providerSettingsOpen = false
    /// "Organize with AI" prompt popup (see `openAIArrangePrompt`).
    var aiArrangePromptOpen = false
    /// Last-used clustering criterion — prefills the field on reopen.
    var aiArrangeCriterion = ""
    var aiArrangeInFlight = false
    var aiArrangeError: String?
    /// Canvas navigator (minimap) — toggled with `` ` ``.
    var navigatorOpen = false
    var boardMenuID: String?
    var boardMenuY: CGFloat = 56
    var boardWave = 0
    var textWave: TextWaveEvent?
    /// One dissolve burst per deleted card (screen-space geometry snapshotted via world size).
    var deleteWaves: [DeleteWaveEvent] = []
    /// Alignment guides while dragging cards (cleared on drag end).
    var snapGuides: [SnapGuide] = []
    /// Live lift / extract / drop-target feedback while dragging cards relative to groups.
    var groupDrag: GroupDragFeedback?
    var viewport = CGSize(width: 1440, height: 900)
    var settings = AppSettings.load() {
        didSet {
            // Encode on MainActor, write off-thread (Swift 6: save() is actor-isolated).
            guard let data = try? JSONEncoder().encode(settings) else { return }
            let url = AppSettings.file
            Task.detached(priority: .utility) {
                try? data.write(to: url, options: [.atomic])
            }
        }
    }

    private var past: [(lessonID: String, cards: [Card])] = []
    private var future: [(lessonID: String, cards: [Card])] = []
    private var saveTask: Task<Void, Never>?
    private var dirtyLessonIDs: Set<String> = []
    private var indexDirty = false
    private var clipboard: [Card] = []
    /// System pasteboard's changeCount at the moment `clipboard` was captured — lets `paste`
    /// tell whether something was copied elsewhere since, so it doesn't keep re-pasting a
    /// stale in-app copy over a newer external one.
    private var clipboardChangeCount = -1
    /// Fixed card metrics for the active corner-resize gesture (Ticket G).
    @ObservationIgnored private var cardResizeSession: (
        id: String,
        width: Double,
        height: Double,
        font: Double,
        aspect: Double,
        strokes: [DrawStroke]?
    )?
    /// Observed so SwiftUI can suppress content-driven auto-fit during corner-drag.
    var resizingCardID: String? = nil
    /// Member frames snapshotted at the start of a group-plaque resize, so every member
    /// scales together with the plaque (Figma/Illustrator "scale group" behavior) instead
    /// of the plaque resizing around content that stays put.
    @ObservationIgnored private var groupResizeMembers: [String: CGRect] = [:]

    init() {
        if let saved = Persistence.load(), saved.rev == Format.libraryRev, !saved.lessons.isEmpty {
            library = saved
            var healed = false
            if DemoLibrary.ensureGuide(in: &library) {
                dirtyLessonIDs.insert(DemoLibrary.guideLessonID)
                indexDirty = true
                healed = true
            }
            for i in library.lessons.indices {
                let before = library.lessons[i].cards.map(\.src)
                Persistence.healMediaPaths(&library.lessons[i], subjects: library.subjects)
                if library.lessons[i].cards.map(\.src) != before {
                    dirtyLessonIDs.insert(library.lessons[i].id)
                    healed = true
                }
            }
            if healed {
                indexDirty = true
                persistSoon()
            }
        } else {
            library = DemoLibrary.make()
            markAllLessonsDirty()
            persistSoon(prune: true)
        }
        Playback.shared.onEnded { [weak self] in
            self?.playingID = nil
            self?.playbackPaused = false
            Playback.shared.stop()
        }
        AppSounds.isEnabled = { [weak self] in self?.settings.sounds ?? false }
        AppHaptics.isEnabled = { [weak self] in self?.settings.haptics ?? false }
        ChatKeychain.migrateLegacyDeepSeekTokenIfNeeded()
    }

    var activeLesson: Lesson? {
        library.lessons.first { $0.id == library.activeLessonId }
    }

    var activeLessonIndex: Int? {
        library.lessons.firstIndex { $0.id == library.activeLessonId }
    }

    private func markActiveDirty() {
        if let id = library.activeLessonId {
            dirtyLessonIDs.insert(id)
        }
    }

    private func markAllLessonsDirty() {
        dirtyLessonIDs = Set(library.lessons.map(\.id))
        indexDirty = true
    }

    private func materializePaths() {
        var taken = Set(library.lessons.compactMap(\.path).filter { !$0.isEmpty })
        for i in library.lessons.indices {
            if let path = library.lessons[i].path, !path.isEmpty {
                taken.insert(path)
                continue
            }
            var lesson = library.lessons[i]
            let path = Persistence.resolvedPath(for: &lesson, subjects: library.subjects, taken: &taken)
            library.lessons[i].path = path
        }
    }

    func persistSoon(prune: Bool = false) {
        saveTask?.cancel()
        materializePaths()
        let dirty = dirtyLessonIDs
        let writeIndexOnly = dirty.isEmpty && !prune
        let batch = Persistence.prepareWrites(
            library,
            dirtyLessonIDs: writeIndexOnly ? [] : dirty,
            prune: prune,
            recomputeBytes: prune
        )
        dirtyLessonIDs = []
        indexDirty = false
        let chatFiles = prepareChatWrites()
        saveTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let files = batch.files + chatFiles
            let keeping = batch.pruneKeeping
            await Task.detached(priority: .utility) {
                VasaDisk.write(files)
            }.value
            if let keeping {
                Persistence.pruneLessonFolders(keeping: keeping)
            }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        markActiveDirty()
        materializePaths()
        let dirty = dirtyLessonIDs.isEmpty ? Set(library.lessons.map(\.id)) : dirtyLessonIDs
        let batch = Persistence.prepareWrites(
            library,
            dirtyLessonIDs: dirty,
            prune: false,
            recomputeBytes: false
        )
        dirtyLessonIDs = []
        indexDirty = false
        let chatFiles = prepareChatWrites()
        let files = batch.files + chatFiles
        Task(priority: .utility) {
            await Task.detached(priority: .utility) {
                VasaDisk.write(files)
            }.value
        }
    }

    /// Chats are session-only by design: never written to or read from disk, so relaunching
    /// the app always starts every lesson with a clean thread. `dirtyChatLessonIDs` stays wired
    /// up (harmlessly) in case persistence is reintroduced later, but this never touches disk.
    private func prepareChatWrites() -> [(URL, Data)] {
        dirtyChatLessonIDs = []
        return []
    }

    /// Ensures an in-memory chat thread exists for `lessonId` (creating an empty one on first
    /// access this session — never loaded from disk, see `prepareChatWrites`). Does NOT
    /// auto-send `seedSources` — callers should prefill the composer with them instead, so the
    /// user can review before sending.
    @discardableResult
    func startOrContinueChat(lessonId: String, seedSources: [String] = []) -> ChatThread {
        if let existing = chatThreads[lessonId] {
            return existing
        }
        let thread = ChatThread(lessonId: lessonId, providerId: settings.activeProviderId, model: activeProviderModel)
        chatThreads[lessonId] = thread
        return thread
    }

    var activeProviderModel: String {
        settings.aiProviders.first { $0.id == settings.activeProviderId }?.defaultModel
            ?? ProviderCatalog.defaults.first { $0.id == "giga" }?.defaultModel
            ?? DeepSeekProvider.model
    }

    func updateChatThread(lessonId: String, _ patch: (inout ChatThread) -> Void) {
        var thread = chatThreads[lessonId] ?? startOrContinueChat(lessonId: lessonId)
        patch(&thread)
        thread.updatedAt = Date().timeIntervalSince1970 * 1000
        chatThreads[lessonId] = thread
        dirtyChatLessonIDs.insert(lessonId)
        persistSoon()
    }

    func patchLesson(_ fn: (inout Lesson) -> Void) {
        guard let idx = activeLessonIndex else { return }
        fn(&library.lessons[idx])
        library.lessons[idx].updatedAt = Date().timeIntervalSince1970 * 1000
        markActiveDirty()
    }

    func setCamera(_ x: Double? = nil, _ y: Double? = nil, zoom: Double? = nil, persist: Bool = true) {
        patchLesson { lesson in
            if let x { lesson.camera.x = x }
            if let y { lesson.camera.y = y }
            if let zoom { lesson.camera.zoom = zoom }
        }
        if persist { persistSoon() }
    }

    /// Selects a card and centers the camera on it at its current zoom — used by the
    /// search palette to jump straight to a match instead of just opening the board blind.
    func revealCard(_ id: String) {
        guard let lesson = activeLesson, let card = lesson.cards.first(where: { $0.id == id }) else { return }
        let zoom = max(lesson.camera.zoom, 0.01)
        let cx = card.x + card.previewWidth / 2
        let cy = card.y + card.previewHeight / 2
        cameraEase = true
        setCamera(viewport.width / 2 - cx * zoom, viewport.height / 2 - cy * zoom)
        select([id])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { self.cameraEase = false }
    }

    func toggleSidebar() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            library.sidebarOpen.toggle()
            if !library.sidebarOpen { settingsOpen = false }
        }
        AppSounds.play(library.sidebarOpen ? .transitionUp : .transitionDown)
        AppHaptics.perform(.generic)
        indexDirty = true
        persistSoon()
    }

    func openLesson(_ id: String, playSound: Bool = true) {
        let switching = library.activeLessonId != id
        Playback.shared.stop()
        playingID = nil
        playbackPaused = false
        audioDetailID = nil
        selectedIDs = []
        menu = nil
        boardMenuID = nil
        library.activeLessonId = id
        if let i = library.lessons.firstIndex(where: { $0.id == id }) {
            let before = library.lessons[i].cards.map(\.src)
            Persistence.healMediaPaths(&library.lessons[i], subjects: library.subjects)
            if library.lessons[i].cards.map(\.src) != before {
                dirtyLessonIDs.insert(id)
            }
        }
        if !library.openLessonIds.contains(id) {
            library.openLessonIds.append(id)
        }
        indexDirty = true
        persistSoon()
        if playSound, switching { AppSounds.playSwipe() }
        if switching { autoTagUntaggedCards(in: id) }
    }

    /// "August 29, 2026" — fixed English formatting regardless of system locale, so project
    /// names stay consistent across machines/languages instead of drifting with `Locale.current`.
    private static var newProjectTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: Date())
    }

    func addLesson() {
        guard let subject = library.subjects.first else { return }
        var lesson = Lesson(
            id: VasaID.make("les"),
            subjectId: subject.id,
            title: Self.newProjectTitle,
            cards: [],
            camera: Camera(x: 0, y: 0, zoom: 1),
            updatedAt: Date().timeIntervalSince1970 * 1000,
            pinned: nil,
            bytes: 0,
            thumb: nil,
            path: nil
        )
        library.lessons.insert(lesson, at: 0)
        dirtyLessonIDs.insert(lesson.id)
        indexDirty = true
        openLesson(lesson.id, playSound: false)
        boardWave += 1
        AppSounds.play(.celebration)
    }

    /// Handles `.vasa` packages opened from Finder. Returns whether anything was taken in.
    @discardableResult
    func importVasaPackages(_ urls: [URL]) -> Bool {
        let packages = urls.filter { $0.pathExtension.lowercased() == "vasa" }
        guard !packages.isEmpty, let subject = library.subjects.first else { return false }

        var lastID: String?
        for url in packages {
            // Opening a package that already lives in the library just reveals it —
            // re-importing would leave the user with a silent duplicate.
            if let existing = library.lessons.first(where: {
                Persistence.lessonDirectory($0, subjects: library.subjects)
                    .standardizedFileURL.path == url.standardizedFileURL.path
            }) {
                lastID = existing.id
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let imported = Persistence.importPackage(
                at: url,
                subjectId: subject.id,
                subjects: library.subjects,
                newID: VasaID.make("les")
            ) else { continue }
            library.lessons.insert(imported, at: 0)
            lastID = imported.id
        }

        guard let lastID else {
            AppSounds.play(.caution)
            return false
        }
        indexDirty = true
        saveNow()
        openLesson(lastID, playSound: false)
        boardWave += 1
        AppSounds.play(.celebration)
        return true
    }

    func renameLesson(_ id: String, _ title: String) {
        guard let i = library.lessons.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Persistence.renameLessonFolder(&library.lessons[i], subjects: library.subjects, title: trimmed)
        dirtyLessonIDs.insert(id)
        indexDirty = true
        persistSoon()
    }

    func pinLesson(_ id: String) {
        if let i = library.lessons.firstIndex(where: { $0.id == id }) {
            library.lessons[i].pinned = !(library.lessons[i].pinned ?? false)
            dirtyLessonIDs.insert(id)
            indexDirty = true
            persistSoon()
        }
    }

    func duplicateLesson(_ id: String) {
        guard let lesson = library.lessons.first(where: { $0.id == id }) else { return }
        let newID = VasaID.make("les")
        let newTitle = "\(lesson.title) copy"
        if let copy = Persistence.duplicateLessonFolder(lesson, subjects: library.subjects, newID: newID, newTitle: newTitle) {
            library.lessons.insert(copy, at: 0)
            dirtyLessonIDs.insert(copy.id)
        } else {
            var copy = lesson
            copy.id = newID
            copy.title = newTitle
            copy.path = nil
            library.lessons.insert(copy, at: 0)
            dirtyLessonIDs.insert(newID)
        }
        indexDirty = true
        persistSoon()
    }

    func deleteLesson(_ id: String) {
        if let lesson = library.lessons.first(where: { $0.id == id }) {
            Persistence.deleteLessonFolder(lesson, subjects: library.subjects)
        }
        library.lessons.removeAll { $0.id == id }
        library.openLessonIds.removeAll { $0 == id }
        dirtyLessonIDs.remove(id)
        if library.activeLessonId == id {
            library.activeLessonId = library.lessons.first?.id
        }
        indexDirty = true
        persistSoon(prune: true)
        AppSounds.play(.caution)
    }

    func select(_ ids: [String], additive: Bool = false, playSound: Bool = true) {
        let next: [String] = {
            if additive { return Array(Set(selectedIDs + ids)) }
            return ids
        }()
        if next == selectedIDs, menu == nil, boardMenuID == nil,
           editingID == nil || ids.contains(where: { $0 == editingID }) {
            return
        }
        let gained = !next.isEmpty && next != selectedIDs
        selectedIDs = next
        if playSound, gained { AppSounds.playCanvasTap() }
        if let id = editingID, !ids.contains(where: { $0 == id }) {
            stopEditingText()
        }
        if let open = noteOpenID, !ids.contains(open) {
            if let first = ids.first, !additive, card(first)?.kind == .note {
                openNoteEditor(first)
            } else {
                closeNoteEditor()
            }
        }
        menu = nil
        boardMenuID = nil
    }

    /// Adds/removes a single id from the selection, leaving the rest untouched. Used for
    /// shift-click on a group member, which should pick that one card out of the group
    /// instead of selecting the whole group.
    func toggleSelect(_ id: String, playSound: Bool = true) {
        var ids = selectedIDs
        if let idx = ids.firstIndex(of: id) {
            ids.remove(at: idx)
        } else {
            ids.append(id)
        }
        select(ids, additive: false, playSound: playSound)
    }

    /// Resign canvas text editing and apply the empty-discard rule once.
    func stopEditingText() {
        guard let id = editingID else {
            activeCanvasTextView?.setSelectedRange(NSRange(location: 0, length: 0))
            activeCanvasTextView = nil
            clearTextSelection()
            return
        }
        activeCanvasTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        editingID = nil
        activeCanvasTextView = nil
        clearTextSelection()
        finishTextEditing(cardID: id)
    }

    func updateTextSelection(range: NSRange, screenRect: CGRect?) {
        if range.length > 0 {
            textSelectionLength = range.length
            textSelectionScreenRect = screenRect
            textEditingRange = range
            return
        }
        // Empty selection: hide bar unless the format chrome is hovered
        // (clicking a button steals first responder and clears the range).
        if !formatBarHovered {
            clearTextSelection()
        }
    }

    func clearTextSelection() {
        textSelectionLength = 0
        textSelectionScreenRect = nil
        textEditingRange = NSRange(location: 0, length: 0)
        formatBarHovered = false
    }

    var showsTextFormatBar: Bool {
        guard editingID != nil else { return false }
        return textSelectionLength > 0 || formatBarHovered
    }

    /// Begin editing an existing text card (double-click / enter). `at` is the card-local
    /// point the double-click landed on — see `pendingTextCaret`.
    func beginTextEditing(cardID: String, at point: CGPoint? = nil) {
        guard card(cardID)?.kind == .text else { return }
        if let current = editingID, current != cardID {
            stopEditingText()
        }
        editingID = cardID
        pendingTextCaret = point.map { (cardID, $0) }
        selectedIDs = [cardID]
        textToolState = .editing(cardID: cardID)
        clearTextSelection()
    }

    func clearSelection() {
        selectedIDs = []
        stopEditingText()
        editingGroupID = nil
        menu = nil
        boardMenuID = nil
        clearSnapGuides()
    }

    func selectAllCards() {
        guard let lesson = activeLesson else { return }
        let ids = lesson.cards.map(\.id)
        guard !ids.isEmpty else { return }
        select(ids)
    }

    /// ⌘G — wrap the selection, or drop an empty group plaque at the last click.
    func groupSelection() {
        guard let lesson = activeLesson else { return }
        let selected = lesson.cards.filter { selectedIDs.contains($0.id) }
        let members = selected.filter { $0.kind != .group }
        if members.isEmpty {
            insertEmptyGroup()
            return
        }
        // Dropping onto an already-selected group adds members to it.
        if let existing = selected.first(where: { $0.kind == .group }) {
            pushUndo()
            addCards(members.map(\.id), toGroup: existing.id)
            selectedIDs = [existing.id]
            persistSoon()
            AppSounds.playSwipe()
            return
        }
        wrapInGroup(members)
    }

    func ungroupSelection() {
        guard let lesson = activeLesson else { return }
        let groupIDs = lesson.cards
            .filter { selectedIDs.contains($0.id) && $0.kind == .group }
            .map(\.id)
        let fromMembers = Set(
            lesson.cards
                .filter { selectedIDs.contains($0.id) }
                .compactMap(\.groupId)
        )
        let ids = Set(groupIDs).union(fromMembers)
        guard !ids.isEmpty else { return }
        pushUndo()
        patchLesson { lesson in
            for i in lesson.cards.indices where ids.contains(lesson.cards[i].groupId ?? "") {
                lesson.cards[i].groupId = nil
            }
            lesson.cards.removeAll { ids.contains($0.id) && $0.kind == .group }
        }
        selectedIDs = selectedIDs.filter { !ids.contains($0) }
        persistSoon()
        AppSounds.playSwipe()
    }

    func beginGroupRename(_ id: String) {
        guard card(id)?.kind == .group else { return }
        editingGroupID = id
        selectedIDs = [id]
    }

    func commitGroupRename(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateCard(id) { $0.title = trimmed.isEmpty ? "Group" : trimmed }
        if editingGroupID == id { editingGroupID = nil }
    }

    /// IDs that must travel together — a group plaque takes its members.
    /// World-space bounding box of the current selection, or nil when nothing is selected.
    func selectionBounds() -> CGRect? {
        guard let lesson = activeLesson else { return nil }
        let frames = lesson.cards.filter { selectedIDs.contains($0.id) }.map(\.frame)
        guard var box = frames.first else { return nil }
        for f in frames.dropFirst() { box = box.union(f) }
        return box
    }

    func idsMoving(with selected: [String]) -> [String] {
        guard let lesson = activeLesson else { return selected }
        var set = Set(selected)
        for id in selected {
            guard card(id)?.kind == .group else { continue }
            for child in lesson.cards where child.groupId == id {
                set.insert(child.id)
            }
        }
        return Array(set)
    }

    func reconcileGroups(afterMoving ids: [String]) {
        guard let lesson = activeLesson else { return }
        let moving = Set(ids)
        let movedGroups = Set(ids.filter { card($0)?.kind == .group })
        var dirtyGroups = movedGroups
        var beforeCount: [String: Int] = [:]
        for gid in lesson.cards where gid.kind == .group {
            beforeCount[gid.id] = lesson.cards.filter { $0.groupId == gid.id }.count
        }
        for id in ids {
            guard let item = card(id), item.kind != .group else { continue }
            if let gid = item.groupId, moving.contains(gid) { continue }
            let center = CGPoint(x: item.x + item.previewWidth / 2, y: item.y + item.previewHeight / 2)
            // Hysteresis: a member already in its group stays put unless it clears the
            // frame by a real margin, not just the exact edge — a stray pixel or the
            // plaque re-fitting slightly smaller shouldn't silently drop it out.
            if let currentGid = item.groupId, !moving.contains(currentGid),
               let currentGroup = lesson.cards.first(where: { $0.id == currentGid && $0.kind == .group }),
               currentGroup.frame.insetBy(dx: -Format.groupStayMargin, dy: -Format.groupStayMargin).contains(center)
            {
                dirtyGroups.insert(currentGid)
                continue
            }
            let host = lesson.cards
                .filter { $0.kind == .group && !moving.contains($0.id) && $0.frame.contains(center) }
                .sorted { $0.z > $1.z }
                .first
            let nextID = host?.id
            if item.groupId != nextID {
                updateCard(id, persist: false) { $0.groupId = nextID }
                if let nextID { dirtyGroups.insert(nextID) }
                if let prev = item.groupId { dirtyGroups.insert(prev) }
            } else if let gid = item.groupId {
                dirtyGroups.insert(gid)
            }
        }
        for gid in dirtyGroups {
            sinkGroup(gid)
            let after = activeLesson?.cards.filter { $0.groupId == gid }.count ?? 0
            let before = beforeCount[gid] ?? 0
            if after == 0 { continue }
            fitGroup(gid, mode: after < before ? .wrap : .grow)
        }
        persistSoon()
    }

    func beginGroupDrag(ids: [String]) {
        var origin: [String: String] = [:]
        let moving = Set(ids)
        var liftingGroup = false
        for id in ids {
            guard let item = card(id) else { continue }
            if item.kind == .group {
                liftingGroup = true
                continue
            }
            guard let gid = item.groupId, !moving.contains(gid) else { continue }
            origin[id] = gid
        }
        groupDrag = GroupDragFeedback(movingIDs: moving, originGroupByCard: origin)
        if !origin.isEmpty || liftingGroup {
            AppSounds.playSwipe()
        }
        updateGroupDrag()
    }

    func updateGroupDrag() {
        guard var drag = groupDrag, let lesson = activeLesson else { return }
        var extracting = Set<String>()
        for (cardID, gid) in drag.originGroupByCard {
            guard let item = card(cardID), let group = card(gid) else { continue }
            let center = CGPoint(x: item.x + item.previewWidth / 2, y: item.y + item.previewHeight / 2)
            // Match reconcileGroups' stay margin so the live dashed/extracting feedback
            // never promises a detach that the drag-end commit wouldn't actually apply.
            if !group.frame.insetBy(dx: -Format.groupStayMargin, dy: -Format.groupStayMargin).contains(center) {
                extracting.insert(cardID)
            }
        }
        let newlyOut = extracting.subtracting(drag.extractingIDs)
        let returned = drag.extractingIDs.subtracting(extracting)
        if !newlyOut.isEmpty { AppSounds.play(.caution) }
        if !returned.isEmpty { AppSounds.playToggle(true) }

        var hover: String?
        for id in drag.movingIDs {
            guard let item = card(id), item.kind != .group else { continue }
            let center = CGPoint(x: item.x + item.previewWidth / 2, y: item.y + item.previewHeight / 2)
            let host = lesson.cards
                .filter { $0.kind == .group && !drag.movingIDs.contains($0.id) && $0.frame.contains(center) }
                .sorted { $0.z > $1.z }
                .first
            guard let host else { continue }
            if drag.originGroupByCard[id] == host.id, !extracting.contains(id) { continue }
            hover = host.id
            break
        }
        if hover != drag.hoverGroupID {
            if hover != nil { AppSounds.play(.hover) }
            else if drag.hoverGroupID != nil { AppSounds.playToggle(false) }
        }
        if drag.extractingIDs != extracting || drag.hoverGroupID != hover {
            drag.extractingIDs = extracting
            drag.hoverGroupID = hover
            groupDrag = drag
        }
    }

    func endGroupDrag() {
        groupDrag = nil
    }

    func groupDragLook(for id: String) -> SelectionLook {
        guard let drag = groupDrag, drag.movingIDs.contains(id) else { return .solid }
        if drag.extractingIDs.contains(id) { return .extracting }
        if drag.originGroupByCard[id] != nil { return .dashed }
        if drag.hoverGroupID != nil, card(id)?.kind != .group { return .dashed }
        return .solid
    }

    func groupFrameLook(for id: String) -> SelectionLook? {
        guard let drag = groupDrag else { return nil }
        if drag.hoverGroupID == id { return .dashed }
        let kids = drag.originGroupByCard.filter { $0.value == id }.map(\.key)
        guard !kids.isEmpty else { return nil }
        if kids.contains(where: { drag.extractingIDs.contains($0) }) { return .extracting }
        return .dashed
    }

    private func insertEmptyGroup() {
        let size = Format.groupEmptySize
        let origin = placementOrigin(for: size)
        let id = VasaID.make("c")
        var card = DemoLibrary.group(id, origin.x, origin.y, size.width, size.height)
        pushUndo()
        patchLesson { lesson in
            card.z = (lesson.cards.map(\.z).min() ?? 1) - 1
            lesson.cards.append(card)
        }
        selectedIDs = [id]
        persistSoon()
        AppSounds.playSwipe()
    }

    /// Tight bounding frame for a group plaque wrapping `members`, using the same padding
    /// and minimum-size constants as `fitGroup`. Shared by `wrapInGroup` (manual ⌘G) and
    /// `createCardsFromChat` (AI-authored clusters) so both produce identical plaque math.
    private func groupPlaqueFrame(for members: [Card]) -> CGRect {
        let padX = Format.groupPadX
        let padTop = Format.groupPadTop
        let padBottom = Format.groupPadBottom
        let minX = members.map { Double($0.frame.minX) }.min() ?? 0
        let minY = members.map { Double($0.frame.minY) }.min() ?? 0
        let maxX = members.map { Double($0.frame.maxX) }.max() ?? 0
        let maxY = members.map { Double($0.frame.maxY) }.max() ?? 0
        return CGRect(
            x: minX - padX,
            y: minY - padTop,
            width: max(Format.groupMinWrap.width, (maxX - minX) + padX * 2),
            height: max(Format.groupMinWrap.height, (maxY - minY) + padTop + padBottom)
        )
    }

    private func wrapInGroup(_ members: [Card]) {
        let frame = groupPlaqueFrame(for: members)
        let id = VasaID.make("c")
        let memberIDs = Set(members.map(\.id))
        let minZ = members.map(\.z).min() ?? 0
        pushUndo()
        patchLesson { lesson in
            var group = DemoLibrary.group(id, frame.minX, frame.minY, frame.width, frame.height)
            group.z = minZ - 1
            for i in lesson.cards.indices where memberIDs.contains(lesson.cards[i].id) {
                lesson.cards[i].groupId = id
            }
            lesson.cards.append(group)
        }
        selectedIDs = [id]
        persistSoon()
        AppSounds.playSwipe()
    }

    private func addCards(_ ids: [String], toGroup groupID: String) {
        let set = Set(ids)
        patchLesson { lesson in
            for i in lesson.cards.indices where set.contains(lesson.cards[i].id) {
                lesson.cards[i].groupId = groupID
            }
        }
        sinkGroup(groupID)
        fitGroup(groupID, mode: .grow)
    }

    private func sinkGroup(_ id: String) {
        guard let lesson = activeLesson, let group = card(id), group.kind == .group else { return }
        let childZ = lesson.cards.filter { $0.groupId == id }.map(\.z).min() ?? group.z
        if group.z >= childZ {
            updateCard(id, persist: false) { $0.z = childZ - 1 }
        }
    }

    enum GroupFitMode {
        /// Tight wrap around members (create / after a member leaves).
        case wrap
        /// Expand to keep padding; never shrink the current plaque.
        case grow
    }

    func fitGroup(_ id: String, mode: GroupFitMode = .grow) {
        guard let lesson = activeLesson, let group = card(id), group.kind == .group else { return }
        let kids = lesson.cards.filter { $0.groupId == id }
        guard !kids.isEmpty else { return }
        let padX = Format.groupPadX
        let padTop = Format.groupPadTop
        let padBottom = Format.groupPadBottom
        let minX = kids.map { Double($0.frame.minX) }.min() ?? group.x
        let minY = kids.map { Double($0.frame.minY) }.min() ?? group.y
        let maxX = kids.map { Double($0.frame.maxX) }.max() ?? group.x + group.width
        let maxY = kids.map { Double($0.frame.maxY) }.max() ?? group.y + group.height
        let neededX = minX - padX
        let neededY = minY - padTop
        let neededW = max(Format.groupMinWrap.width, (maxX - minX) + padX * 2)
        let neededH = max(Format.groupMinWrap.height, (maxY - minY) + padTop + padBottom)

        switch mode {
        case .wrap:
            updateCard(id, persist: false) {
                $0.x = neededX
                $0.y = neededY
                $0.width = neededW
                $0.height = neededH
            }
        case .grow:
            var x = group.x
            var y = group.y
            var right = group.x + group.width
            var bottom = group.y + group.height
            if neededX < x { x = neededX }
            if neededY < y { y = neededY }
            if maxX + padX > right { right = maxX + padX }
            if maxY + padBottom > bottom { bottom = maxY + padBottom }
            updateCard(id, persist: false) {
                $0.x = x
                $0.y = y
                $0.width = max(group.width, max(Format.groupMinWrap.width, right - x))
                $0.height = max(group.height, max(Format.groupMinWrap.height, bottom - y))
            }
        }
    }

    func closeNoteEditor() {
        guard noteOpenID != nil else { return }
        noteOpenID = nil
        AppSounds.play(.transitionDown)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func openNoteEditor(_ id: String) {
        guard noteOpenID != id else { return }
        let wasClosed = noteOpenID == nil
        noteOpenID = id
        if wasClosed { AppSounds.play(.transitionUp) }
    }

    func card(_ id: String) -> Card? {
        activeLesson?.cards.first { $0.id == id }
    }

    func updateCard(_ id: String, persist: Bool = true, _ patch: (inout Card) -> Void) {
        patchLesson { lesson in
            if let i = lesson.cards.firstIndex(where: { $0.id == id }) {
                patch(&lesson.cards[i])
            }
        }
        if persist { persistSoon() }
    }

    func addCard(_ card: Card) {
        pushUndo()
        patchLesson { lesson in
            var next = card
            next.z = (lesson.cards.map(\.z).max() ?? 0) + 1
            lesson.cards.append(next)
            // First media card in a lesson becomes its sidebar cover, so a
            // fresh project doesn't sit with a blank thumbnail forever.
            if lesson.thumb == nil {
                if next.kind == .image, let src = next.src {
                    lesson.thumb = src
                } else if next.kind == .video, let poster = next.poster {
                    lesson.thumb = poster
                }
            }
        }
        selectedIDs = [card.id]
        persistSoon()
    }

    func moveCards(
        _ ids: [String],
        dx: Double,
        dy: Double,
        allowSnapX: Bool = true,
        allowSnapY: Bool = true
    ) {
        let set = Set(idsMoving(with: ids))
        guard let lesson = activeLesson, !set.isEmpty else { return }
        guard dx != 0 || dy != 0 else { return }

        var adjX = 0.0
        var adjY = 0.0
        var guides: [SnapGuide] = []

        if settings.snapping {
            let moved = lesson.cards.compactMap { card -> Card? in
                guard set.contains(card.id) else { return nil }
                var next = card
                next.x += dx
                next.y += dy
                return next
            }
            let others = lesson.cards.filter { !set.contains($0.id) }
            if !moved.isEmpty, !others.isEmpty {
                let zoom = max(lesson.camera.zoom, 0.01)
                let result = Self.alignmentSnap(
                    moving: moved,
                    against: others,
                    threshold: Self.snapThreshold(zoom: zoom),
                    allowSnapX: allowSnapX,
                    allowSnapY: allowSnapY
                )
                adjX = result.dx
                adjY = result.dy
                guides = result.guides
            }
        } else if !snapGuides.isEmpty {
            guides = []
        }

        if guides.isEmpty != snapGuides.isEmpty, !guides.isEmpty {
            AppHaptics.perform(.alignment)
        }

        let fx = dx + adjX
        let fy = dy + adjY
        guard fx != 0 || fy != 0 else {
            snapGuides = guides
            return
        }
        patchLesson { lesson in
            var cards = lesson.cards
            for i in cards.indices where set.contains(cards[i].id) {
                cards[i].x += fx
                cards[i].y += fy
            }
            lesson.cards = cards
        }
        snapGuides = guides
    }

    /// Absolute placement from drag-start origins (avoids sticky snap from per-frame deltas).
    func moveCardsFromOrigins(
        _ origins: [String: CGPoint],
        tx: Double,
        ty: Double,
        allowSnapX: Bool = true,
        allowSnapY: Bool = true
    ) {
        guard !origins.isEmpty, let lesson = activeLesson else { return }
        let ids = Array(origins.keys)
        let set = Set(ids)

        var proposed: [Card] = []
        for id in ids {
            guard var card = lesson.cards.first(where: { $0.id == id }), let origin = origins[id] else { continue }
            card.x = origin.x + tx
            card.y = origin.y + ty
            proposed.append(card)
        }
        guard !proposed.isEmpty else { return }

        var adjX = 0.0
        var adjY = 0.0
        var guides: [SnapGuide] = []
        if settings.snapping {
            let others = lesson.cards.filter { !set.contains($0.id) }
            if !others.isEmpty {
                let zoom = max(lesson.camera.zoom, 0.01)
                let threshold = Self.snapThreshold(zoom: zoom)
                let result = Self.alignmentSnap(
                    moving: proposed,
                    against: others,
                    threshold: threshold,
                    allowSnapX: allowSnapX,
                    allowSnapY: allowSnapY
                )
                // Escape hysteresis: release magnetic pull past ~2.5× threshold so dense
                // boards don't feel glued — but keep painting guides while still near.
                let release = threshold * 2.5
                let holdX = allowSnapX && result.dx != 0
                    && !(abs(tx) > release && abs(tx + result.dx) < abs(tx))
                let holdY = allowSnapY && result.dy != 0
                    && !(abs(ty) > release && abs(ty + result.dy) < abs(ty))
                if holdX { adjX = result.dx }
                if holdY { adjY = result.dy }
                guides = result.guides.filter { guide in
                    switch guide.axis {
                    case .vertical: return allowSnapX && result.dx != 0
                    case .horizontal: return allowSnapY && result.dy != 0
                    }
                }

                // Equal-gap distribution — only on axes edge/center snap left untouched,
                // so a card being centered between siblings never fights the spacing guide.
                if !holdX || !holdY {
                    let atSnap = proposed.map { card -> Card in
                        var c = card
                        c.x += adjX
                        c.y += adjY
                        return c
                    }
                    let spacing = Self.spacingSnap(
                        moving: atSnap,
                        against: others,
                        threshold: threshold,
                        allowSnapX: allowSnapX && !holdX,
                        allowSnapY: allowSnapY && !holdY
                    )
                    if spacing.dx != 0 { adjX += spacing.dx }
                    if spacing.dy != 0 { adjY += spacing.dy }
                    guides += spacing.guides
                }
            }
        } else if !snapGuides.isEmpty {
            guides = []
        }

        if guides.isEmpty != snapGuides.isEmpty, !guides.isEmpty {
            AppHaptics.perform(.alignment)
        }

        patchLesson { lesson in
            var cards = lesson.cards
            for i in cards.indices {
                let id = cards[i].id
                guard let origin = origins[id] else { continue }
                cards[i].x = origin.x + tx + adjX
                cards[i].y = origin.y + ty + adjY
            }
            lesson.cards = cards
        }
        snapGuides = guides
        updateGroupDrag()
    }

    func clearSnapGuides() {
        if !snapGuides.isEmpty { snapGuides = [] }
    }

    /// Recolor the in-progress / selected draw card when the ink swatch changes.
    func recolorActiveInk(_ hex: String) {
        let id = activeInkCardID
            ?? (selectedIDs.count == 1 ? selectedIDs.first : nil)
        guard let id, let card = card(id), card.kind == .draw else { return }
        let strokes = card.inkStrokes
        guard !strokes.isEmpty else { return }
        pushUndo()
        updateCard(id) { c in
            c.setInkStrokes(strokes.map {
                DrawStroke(points: $0.points, color: hex, width: $0.width)
            })
        }
    }

    /// Screen-constant snap radius (floored so high zoom still catches edges).
    private static func snapThreshold(zoom: Double) -> Double {
        max(10, 12 / max(zoom, 0.01))
    }

    /// Snap selected cards' edges/centers to other cards; returns residual delta + guides.
    /// Targets every non-moving card kind (text, link, image, note, …) — not text-only.
    private static func alignmentSnap(
        moving: [Card],
        against: [Card],
        threshold: Double,
        allowSnapX: Bool = true,
        allowSnapY: Bool = true
    ) -> (dx: Double, dy: Double, guides: [SnapGuide]) {
        func xs(_ c: Card) -> [Double] {
            let f = c.snapFrame
            return [f.minX, f.midX, f.maxX]
        }
        func ys(_ c: Card) -> [Double] {
            let f = c.snapFrame
            return [f.minY, f.midY, f.maxY]
        }

        // Every moving card's own edges (not only the selection AABB), so a link
        // can snap to an image the same way text snaps to text.
        let movingV = Array(Set(moving.flatMap(xs))).sorted()
        let movingH = Array(Set(moving.flatMap(ys))).sorted()
        let minX = moving.map(\.snapFrame.minX).min() ?? 0
        let maxX = moving.map(\.snapFrame.maxX).max() ?? 0
        let minY = moving.map(\.snapFrame.minY).min() ?? 0
        let maxY = moving.map(\.snapFrame.maxY).max() ?? 0

        var bestDX: Double?
        var bestDY: Double?
        if allowSnapX {
            for mv in movingV {
                for other in against {
                    for tv in xs(other) {
                        let d = tv - mv
                        if abs(d) <= threshold, bestDX.map({ abs(d) < abs($0) }) ?? true {
                            bestDX = d
                        }
                    }
                }
            }
        }
        if allowSnapY {
            for mh in movingH {
                for other in against {
                    for th in ys(other) {
                        let d = th - mh
                        if abs(d) <= threshold, bestDY.map({ abs(d) < abs($0) }) ?? true {
                            bestDY = d
                        }
                    }
                }
            }
        }

        let dx = bestDX ?? 0
        let dy = bestDY ?? 0
        /// Extend past both objects so the guide clearly bridges and touches them.
        let overhang = 18.0
        let matchEps = max(0.75, threshold * 0.08)
        var guides: [SnapGuide] = []

        if bestDX != nil {
            let snappedMinY = minY + dy
            let snappedMaxY = maxY + dy
            // Group by snap X so one long line covers every target on that edge.
            var byX: [Double: (y0: Double, y1: Double, center: Bool)] = [:]
            let snappedV = movingV.map { $0 + dx }
            let movingCentersX = Set(moving.map { (($0.snapFrame.midX + dx) * 100).rounded() / 100 })
            for other in against {
                let of = other.snapFrame
                for tv in xs(other) where snappedV.contains(where: { abs($0 - tv) < matchEps }) {
                    let key = (tv * 100).rounded() / 100
                    let y0 = min(snappedMinY, of.minY)
                    let y1 = max(snappedMaxY, of.maxY)
                    let isCenter = abs(tv - of.midX) < matchEps
                        || movingCentersX.contains(key)
                    if let prev = byX[key] {
                        byX[key] = (min(prev.y0, y0), max(prev.y1, y1), prev.center || isCenter)
                    } else {
                        byX[key] = (y0, y1, isCenter)
                    }
                }
            }
            for (x, span) in byX {
                guides.append(
                    SnapGuide(
                        axis: .vertical,
                        style: span.center ? .dashed : .solid,
                        position: x,
                        start: span.y0 - overhang,
                        end: span.y1 + overhang
                    )
                )
            }
        }
        if bestDY != nil {
            let snappedMinX = minX + dx
            let snappedMaxX = maxX + dx
            var byY: [Double: (x0: Double, x1: Double, center: Bool)] = [:]
            let snappedH = movingH.map { $0 + dy }
            let movingCentersY = Set(moving.map { (($0.snapFrame.midY + dy) * 100).rounded() / 100 })
            for other in against {
                let of = other.snapFrame
                for th in ys(other) where snappedH.contains(where: { abs($0 - th) < matchEps }) {
                    let key = (th * 100).rounded() / 100
                    let x0 = min(snappedMinX, of.minX)
                    let x1 = max(snappedMaxX, of.maxX)
                    let isCenter = abs(th - of.midY) < matchEps
                        || movingCentersY.contains(key)
                    if let prev = byY[key] {
                        byY[key] = (min(prev.x0, x0), max(prev.x1, x1), prev.center || isCenter)
                    } else {
                        byY[key] = (x0, x1, isCenter)
                    }
                }
            }
            for (y, span) in byY {
                guides.append(
                    SnapGuide(
                        axis: .horizontal,
                        style: span.center ? .dashed : .solid,
                        position: y,
                        start: span.x0 - overhang,
                        end: span.x1 + overhang
                    )
                )
            }
        }

        return (dx, dy, guides)
    }

    /// Equal-gap distribution snap: when the moving selection sits between two
    /// row/column neighbors and its gap to one of them nearly matches its gap
    /// to the other, snap so both gaps are exactly equal (Figma/Sketch-style
    /// "insert into an evenly spaced row" guide) and mark both gap boundaries
    /// with tick capsules. Only engages where `alignmentSnap` found no edge/
    /// center candidate on that axis — edge snap always wins.
    private static func spacingSnap(
        moving: [Card],
        against: [Card],
        threshold: Double,
        allowSnapX: Bool,
        allowSnapY: Bool
    ) -> (dx: Double, dy: Double, guides: [SnapGuide]) {
        guard !moving.isEmpty else { return (0, 0, []) }
        let minX = moving.map(\.snapFrame.minX).min() ?? 0
        let maxX = moving.map(\.snapFrame.maxX).max() ?? 0
        let minY = moving.map(\.snapFrame.minY).min() ?? 0
        let maxY = moving.map(\.snapFrame.maxY).max() ?? 0

        var dx = 0.0
        var dy = 0.0
        var guides: [SnapGuide] = []

        // Ticks paint whenever the moving selection sits between a flanking pair (so the
        // measurement is visible while lining the gap up), but the magnetic correction only
        // engages once the two gaps are within snap `threshold` of each other. Gating both on
        // `threshold` meant the ticks only ever appeared in the last pixel of the snap itself —
        // functionally invisible in normal dragging.
        let previewThreshold = threshold * 4

        if allowSnapX {
            // Row = sibling cards whose vertical extent overlaps the moving selection.
            let row = against.filter { $0.snapFrame.minY < maxY && $0.snapFrame.maxY > minY }
            let left = row.filter { $0.snapFrame.maxX <= minX }.max(by: { $0.snapFrame.maxX < $1.snapFrame.maxX })
            let right = row.filter { $0.snapFrame.minX >= maxX }.min(by: { $0.snapFrame.minX < $1.snapFrame.minX })
            if let left, let right {
                let leftGap = minX - left.snapFrame.maxX
                let rightGap = right.snapFrame.minX - maxX
                let diff = rightGap - leftGap
                if leftGap >= 0, rightGap >= 0, abs(diff) <= previewThreshold {
                    let matched = diff == 0 || abs(diff) <= threshold
                    if matched, diff != 0 { dx = diff / 2 }
                    let snappedMinX = minX + dx
                    let snappedMaxX = maxX + dx
                    let y0 = min(minY, min(left.snapFrame.minY, right.snapFrame.minY))
                    let y1 = max(maxY, max(left.snapFrame.maxY, right.snapFrame.maxY))
                    guides.append(
                        SnapGuide(
                            axis: .horizontal,
                            style: .spacing,
                            position: (y0 + y1) / 2,
                            start: left.snapFrame.maxX,
                            end: right.snapFrame.minX,
                            ticks: [left.snapFrame.maxX, snappedMinX, snappedMaxX, right.snapFrame.minX]
                        )
                    )
                }
            } else if let left {
                // Edge card, neighbor only on the left — match the gap it's carving to the
                // gap that neighbor already keeps with its own left neighbor (chain match).
                let leftGap = minX - left.snapFrame.maxX
                let left2 = row.filter { $0.snapFrame.maxX <= left.snapFrame.minX }
                    .max(by: { $0.snapFrame.maxX < $1.snapFrame.maxX })
                if let left2 {
                    let refGap = left.snapFrame.minX - left2.snapFrame.maxX
                    let diff = leftGap - refGap
                    if leftGap >= 0, refGap >= 0, abs(diff) <= previewThreshold {
                        let matched = diff == 0 || abs(diff) <= threshold
                        if matched, diff != 0 { dx = -diff }
                        let snappedMinX = minX + dx
                        let y0 = min(minY, min(left.snapFrame.minY, left2.snapFrame.minY))
                        let y1 = max(maxY, max(left.snapFrame.maxY, left2.snapFrame.maxY))
                        guides.append(
                            SnapGuide(
                                axis: .horizontal,
                                style: .spacing,
                                position: (y0 + y1) / 2,
                                start: left2.snapFrame.maxX,
                                end: snappedMinX,
                                ticks: [left2.snapFrame.maxX, left.snapFrame.minX, left.snapFrame.maxX, snappedMinX]
                            )
                        )
                    }
                }
            } else if let right {
                // Edge card, neighbor only on the right — chain-match against that
                // neighbor's own gap to its next sibling over.
                let rightGap = right.snapFrame.minX - maxX
                let right2 = row.filter { $0.snapFrame.minX >= right.snapFrame.maxX }
                    .min(by: { $0.snapFrame.minX < $1.snapFrame.minX })
                if let right2 {
                    let refGap = right2.snapFrame.minX - right.snapFrame.maxX
                    let diff = rightGap - refGap
                    if rightGap >= 0, refGap >= 0, abs(diff) <= previewThreshold {
                        let matched = diff == 0 || abs(diff) <= threshold
                        if matched, diff != 0 { dx = diff }
                        let snappedMaxX = maxX + dx
                        let y0 = min(minY, min(right.snapFrame.minY, right2.snapFrame.minY))
                        let y1 = max(maxY, max(right.snapFrame.maxY, right2.snapFrame.maxY))
                        guides.append(
                            SnapGuide(
                                axis: .horizontal,
                                style: .spacing,
                                position: (y0 + y1) / 2,
                                start: snappedMaxX,
                                end: right.snapFrame.minX,
                                ticks: [snappedMaxX, right.snapFrame.minX, right.snapFrame.maxX, right2.snapFrame.minX]
                            )
                        )
                    }
                }
            }
        }

        if allowSnapY {
            // Column = sibling cards whose horizontal extent overlaps the moving selection.
            let column = against.filter { $0.snapFrame.minX < maxX && $0.snapFrame.maxX > minX }
            let top = column.filter { $0.snapFrame.maxY <= minY }.max(by: { $0.snapFrame.maxY < $1.snapFrame.maxY })
            let bottom = column.filter { $0.snapFrame.minY >= maxY }.min(by: { $0.snapFrame.minY < $1.snapFrame.minY })
            if let top, let bottom {
                let topGap = minY - top.snapFrame.maxY
                let bottomGap = bottom.snapFrame.minY - maxY
                let diff = bottomGap - topGap
                if topGap >= 0, bottomGap >= 0, abs(diff) <= previewThreshold {
                    let matched = diff == 0 || abs(diff) <= threshold
                    if matched, diff != 0 { dy = diff / 2 }
                    let snappedMinY = minY + dy
                    let snappedMaxY = maxY + dy
                    let x0 = min(minX, min(top.snapFrame.minX, bottom.snapFrame.minX))
                    let x1 = max(maxX, max(top.snapFrame.maxX, bottom.snapFrame.maxX))
                    guides.append(
                        SnapGuide(
                            axis: .vertical,
                            style: .spacing,
                            position: (x0 + x1) / 2,
                            start: top.snapFrame.maxY,
                            end: bottom.snapFrame.minY,
                            ticks: [top.snapFrame.maxY, snappedMinY, snappedMaxY, bottom.snapFrame.minY]
                        )
                    )
                }
            } else if let top {
                // Edge card, neighbor only above — chain-match against that neighbor's own
                // gap to its next sibling up.
                let topGap = minY - top.snapFrame.maxY
                let top2 = column.filter { $0.snapFrame.maxY <= top.snapFrame.minY }
                    .max(by: { $0.snapFrame.maxY < $1.snapFrame.maxY })
                if let top2 {
                    let refGap = top.snapFrame.minY - top2.snapFrame.maxY
                    let diff = topGap - refGap
                    if topGap >= 0, refGap >= 0, abs(diff) <= previewThreshold {
                        let matched = diff == 0 || abs(diff) <= threshold
                        if matched, diff != 0 { dy = -diff }
                        let snappedMinY = minY + dy
                        let x0 = min(minX, min(top.snapFrame.minX, top2.snapFrame.minX))
                        let x1 = max(maxX, max(top.snapFrame.maxX, top2.snapFrame.maxX))
                        guides.append(
                            SnapGuide(
                                axis: .vertical,
                                style: .spacing,
                                position: (x0 + x1) / 2,
                                start: top2.snapFrame.maxY,
                                end: snappedMinY,
                                ticks: [top2.snapFrame.maxY, top.snapFrame.minY, top.snapFrame.maxY, snappedMinY]
                            )
                        )
                    }
                }
            } else if let bottom {
                // Edge card, neighbor only below — chain-match against that neighbor's own
                // gap to its next sibling down.
                let bottomGap = bottom.snapFrame.minY - maxY
                let bottom2 = column.filter { $0.snapFrame.minY >= bottom.snapFrame.maxY }
                    .min(by: { $0.snapFrame.minY < $1.snapFrame.minY })
                if let bottom2 {
                    let refGap = bottom2.snapFrame.minY - bottom.snapFrame.maxY
                    let diff = bottomGap - refGap
                    if bottomGap >= 0, refGap >= 0, abs(diff) <= previewThreshold {
                        let matched = diff == 0 || abs(diff) <= threshold
                        if matched, diff != 0 { dy = diff }
                        let snappedMaxY = maxY + dy
                        let x0 = min(minX, min(bottom.snapFrame.minX, bottom2.snapFrame.minX))
                        let x1 = max(maxX, max(bottom.snapFrame.maxX, bottom2.snapFrame.maxX))
                        guides.append(
                            SnapGuide(
                                axis: .vertical,
                                style: .spacing,
                                position: (x0 + x1) / 2,
                                start: snappedMaxY,
                                end: bottom.snapFrame.minY,
                                ticks: [snappedMaxY, bottom.snapFrame.minY, bottom.snapFrame.maxY, bottom2.snapFrame.minY]
                            )
                        )
                    }
                }
            }
        }

        return (dx, dy, guides)
    }

    /// One resize axis: snaps the dragged edge (origin + proposedLength) to a
    /// neighbor's edge/center, or the raw length to a neighbor's matching
    /// dimension outright — same "closest candidate within threshold" rule as
    /// `alignmentSnap`, just per-axis since resize moves one corner, not a
    /// whole card.
    private static func resizeSnapAxis(
        origin: Double,
        proposedLength: Double,
        edges: (Card) -> (min: Double, mid: Double, max: Double),
        length: (Card) -> Double,
        against: [Card],
        threshold: Double
    ) -> Double? {
        var best: Double?
        let edge = origin + proposedLength
        for other in against {
            let e = edges(other)
            for target in [e.min, e.mid, e.max] {
                let d = target - edge
                if abs(d) <= threshold, best.map({ abs(d) < abs($0) }) ?? true { best = d }
            }
            let sizeDelta = length(other) - proposedLength
            if abs(sizeDelta) <= threshold, best.map({ abs(sizeDelta) < abs($0) }) ?? true { best = sizeDelta }
        }
        return best
    }

    /// Snaps a resize's proposed size (card's x/y stay fixed as the anchor
    /// corner) to nearby cards' edges or matching width/height, so cards can
    /// be resized flush/uniform with their neighbors the same way drag
    /// already snaps position. Returns per-axis deltas (0 = no snap) plus
    /// guide lines reusing the drag-snap visual language.
    private static func resizeSnap(
        origin: CGPoint,
        proposedSize: CGSize,
        against: [Card],
        threshold: Double
    ) -> (dw: Double, dh: Double, guides: [SnapGuide]) {
        guard !against.isEmpty else { return (0, 0, []) }
        let dw = resizeSnapAxis(
            origin: origin.x,
            proposedLength: proposedSize.width,
            edges: { let f = $0.snapFrame; return (f.minX, f.midX, f.maxX) },
            length: { $0.snapFrame.width },
            against: against,
            threshold: threshold
        ) ?? 0
        let dh = resizeSnapAxis(
            origin: origin.y,
            proposedLength: proposedSize.height,
            edges: { let f = $0.snapFrame; return (f.minY, f.midY, f.maxY) },
            length: { $0.snapFrame.height },
            against: against,
            threshold: threshold
        ) ?? 0

        let overhang = 18.0
        var guides: [SnapGuide] = []
        if dw != 0 {
            let x = origin.x + proposedSize.width + dw
            guides.append(SnapGuide(
                axis: .vertical, style: .solid, position: x,
                start: origin.y - overhang, end: origin.y + proposedSize.height + dh + overhang
            ))
        }
        if dh != 0 {
            let y = origin.y + proposedSize.height + dh
            guides.append(SnapGuide(
                axis: .horizontal, style: .solid, position: y,
                start: origin.x - overhang, end: origin.x + proposedSize.width + dw + overhang
            ))
        }
        return (dw, dh, guides)
    }

    func contentBounds() -> CGRect? {
        guard let cards = activeLesson?.cards, !cards.isEmpty else { return nil }
        let minX = cards.map(\.x).min() ?? 0
        let minY = cards.map(\.y).min() ?? 0
        let maxX = cards.map { $0.x + $0.width }.max() ?? 1
        let maxY = cards.map { $0.y + $0.height }.max() ?? 1
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func clampCamera(x: Double, y: Double, rubber: Bool) -> CGPoint {
        guard let bounds = contentBounds() else { return CGPoint(x: x, y: y) }
        let zoom = max(activeLesson?.camera.zoom ?? 1, 0.01)
        let viewW = max(viewport.width, 1)
        let viewH = max(viewport.height, 1)
        // Room around content in world units — scales with the viewport so a sparse
        // board (one text card) still has space to pan past the edges.
        let pad = max(900.0, max(viewW, viewH) / zoom * 0.75)
        let expanded = bounds.insetBy(dx: -pad, dy: -pad)
        var minCamX = viewW - expanded.maxX * zoom
        var maxCamX = -expanded.minX * zoom
        var minCamY = viewH - expanded.maxY * zoom
        var maxCamY = -expanded.minY * zoom
        // When content (+ pad) fits the screen, old code locked to the midpoint and
        // felt like a hard wall. Keep at least ~half a viewport of free travel.
        let minSpanX = viewW * 0.6
        let minSpanY = viewH * 0.6
        if maxCamX - minCamX < minSpanX {
            let mid = (minCamX + maxCamX) / 2
            minCamX = mid - minSpanX / 2
            maxCamX = mid + minSpanX / 2
        }
        if maxCamY - minCamY < minSpanY {
            let mid = (minCamY + maxCamY) / 2
            minCamY = mid - minSpanY / 2
            maxCamY = mid + minSpanY / 2
        }
        func rubberClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            if v < lo { return rubber ? lo + (v - lo) * 0.38 : lo }
            if v > hi { return rubber ? hi + (v - hi) * 0.38 : hi }
            return v
        }
        return CGPoint(x: rubberClamp(x, minCamX, maxCamX), y: rubberClamp(y, minCamY, maxCamY))
    }

    func settlePan() {
        guard let cam = activeLesson?.camera else { return }
        let clamped = clampCamera(x: cam.x, y: cam.y, rubber: false)
        if hypot(clamped.x - cam.x, clamped.y - cam.y) > 0.8 {
            cameraEase = true
            setCamera(clamped.x, clamped.y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                self.cameraEase = false
                self.saveNow()
            }
        } else {
            saveNow()
        }
    }

    /// Flush camera after zoom gestures that used `persist: false`.
    func settleCamera() {
        saveNow()
    }

    func snapSelected() {
        // Object-edge snap runs live in `moveCards` while dragging (with guides).
        // Do not re-round to an 8pt grid here — that undoes edge alignment.
        clearSnapGuides()
    }

    /// Absolute corner-resize from a stable gesture start (Ticket G).
    /// `size` is already `start + screenDelta / zoom` from `CardSelection`.
    func resizeCard(_ id: String, to size: CGSize) {
        guard let card = card(id) else { return }
        if cardResizeSession?.id != id {
            pushUndo()
            cardResizeSession = (
                id: id,
                width: card.width,
                height: card.height,
                font: card.fontSize ?? 16,
                aspect: card.width / max(1, card.height),
                strokes: card.kind == .draw ? card.inkStrokes : nil
            )
            resizingCardID = id
            if card.kind == .group, let lesson = activeLesson {
                groupResizeMembers = Dictionary(uniqueKeysWithValues: lesson.cards
                    .filter { $0.groupId == id }
                    .map { ($0.id, CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) })
            } else {
                groupResizeMembers = [:]
            }
        }
        guard let session = cardResizeSession, session.id == id else { return }

        // Shortcut/folder tiles have a fixed 58pt icon + padding — below ~104×120
        // the icon and title clip against the card's rounded-rect mask.
        let isShortcutTile = card.kind == .shortcut || card.kind == .folder
        let minW: Double = card.kind == .note ? 220 : (card.kind == .text ? 64 : (isShortcutTile ? 104 : 64))
        // A bit taller still (136) so the "Not found" state doesn't clip either.
        let minH: Double = card.kind == .note ? 100 : (card.kind == .text ? 28 : (isShortcutTile ? 136 : 64))
        let maxW: Double = card.kind == .note ? 420 : 2400
        let maxH: Double = card.kind == .note ? 160 : 2400
        // Keep the raw corner — clamping before scale made a horizontal drag
        // snap onto minH/minW and jump the other axis.
        let rawW = Double(size.width)
        let rawH = Double(size.height)
        let proposedW = min(maxW, max(minW, rawW))
        let proposedH = min(maxH, max(minH, rawH))

        if card.kind == .text {
            // Frame follows the gesture continuously; font tracks scale from session start.
            // Do not derive width/height from quantized fontScale — that fought content-fit.
            updateCard(id, persist: false) {
                let originHyp = hypot(session.width, session.height)
                let nextHyp = hypot(rawW, rawH)
                let scale = max(0.05, nextHyp / max(originHyp, 1))
                $0.fontSize = min(200, max(8, (session.font * scale * 10).rounded() / 10))
                $0.width = proposedW
                $0.height = proposedH
            }
            return
        }

        let free = NSEvent.modifierFlags.contains(.shift) || card.kind == .note || card.kind == .group
        if !free {
            let scale = Self.aspectScale(
                proposedW: rawW,
                proposedH: rawH,
                sessionW: session.width,
                sessionH: session.height,
                minW: minW,
                minH: minH,
                maxW: maxW,
                maxH: maxH
            )
            var width = min(maxW, max(minW, session.width * scale))
            var height = min(maxH, max(minH, session.height * scale))
            var guides: [SnapGuide] = []
            if settings.snapping, let lesson = activeLesson {
                let others = lesson.cards.filter { $0.id != id }
                if !others.isEmpty {
                    let threshold = Self.snapThreshold(zoom: max(lesson.camera.zoom, 0.01))
                    let snap = Self.resizeSnap(
                        origin: CGPoint(x: card.x, y: card.y),
                        proposedSize: CGSize(width: width, height: height),
                        against: others,
                        threshold: threshold
                    )
                    // Aspect stays locked through the snap: take whichever axis has
                    // the closer match and re-derive the other from the ratio,
                    // rather than snapping both independently and distorting it.
                    if snap.dw != 0, snap.dh == 0 || abs(snap.dw) <= abs(snap.dh) {
                        width = min(maxW, max(minW, width + snap.dw))
                        height = min(maxH, max(minH, width / max(session.aspect, 0.0001)))
                        guides = snap.guides.filter { $0.axis == .vertical }
                    } else if snap.dh != 0 {
                        height = min(maxH, max(minH, height + snap.dh))
                        width = min(maxW, max(minW, height * session.aspect))
                        guides = snap.guides.filter { $0.axis == .horizontal }
                    }
                }
            }
            snapGuides = guides
            if card.kind == .draw, let base = session.strokes {
                let sx = width / max(session.width, 1)
                updateCard(id, persist: false) {
                    $0.width = width
                    $0.height = height
                    $0.setInkStrokes(base.map { stroke in
                        DrawStroke(
                            points: stroke.points.map { DrawPoint(x: $0.x * sx, y: $0.y * sx) },
                            color: stroke.color,
                            width: max(1, stroke.width * sx)
                        )
                    })
                }
                return
            }
            updateCard(id, persist: false) {
                $0.width = width
                $0.height = height
            }
            return
        }

        var freeW = proposedW
        var freeH = proposedH
        var freeGuides: [SnapGuide] = []
        if settings.snapping, let lesson = activeLesson {
            let others = lesson.cards.filter { $0.id != id }
            if !others.isEmpty {
                let threshold = Self.snapThreshold(zoom: max(lesson.camera.zoom, 0.01))
                let snap = Self.resizeSnap(
                    origin: CGPoint(x: card.x, y: card.y),
                    proposedSize: CGSize(width: freeW, height: freeH),
                    against: others,
                    threshold: threshold
                )
                freeW = min(maxW, max(minW, freeW + snap.dw))
                freeH = min(maxH, max(minH, freeH + snap.dh))
                freeGuides = snap.guides
            }
        }
        snapGuides = freeGuides
        if card.kind == .group, !groupResizeMembers.isEmpty {
            // Floor the scale itself (not just each member's output size) so the plaque
            // can't keep shrinking past what its smallest member can legibly show — that
            // mismatch is what let the frame and its members drift out of sync and produced
            // the distorted/overflowing layout when a group was squeezed too far.
            let memberFloor: Double = 64
            var minSx = 0.0, minSy = 0.0
            for origin in groupResizeMembers.values {
                minSx = max(minSx, memberFloor / max(origin.width, 1))
                minSy = max(minSy, memberFloor / max(origin.height, 1))
            }
            var sx = freeW / max(session.width, 1)
            var sy = freeH / max(session.height, 1)
            sx = max(sx, minSx)
            sy = max(sy, minSy)
            freeW = session.width * sx
            freeH = session.height * sy
            for (memberID, origin) in groupResizeMembers {
                updateCard(memberID, persist: false) {
                    $0.x = card.x + (origin.minX - card.x) * sx
                    $0.y = card.y + (origin.minY - card.y) * sy
                    $0.width = origin.width * sx
                    $0.height = origin.height * sy
                }
            }
        }
        updateCard(id, persist: false) {
            $0.width = freeW
            $0.height = freeH
        }
    }

    /// Project the dragged corner onto the aspect diagonal so a purely
    /// horizontal/vertical move cannot switch axes and jump the other side.
    private static func aspectScale(
        proposedW: Double,
        proposedH: Double,
        sessionW: Double,
        sessionH: Double,
        minW: Double,
        minH: Double,
        maxW: Double,
        maxH: Double
    ) -> Double {
        let w = max(sessionW, 1)
        let h = max(sessionH, 1)
        let projected = (proposedW * w + proposedH * h) / (w * w + h * h)
        let floor = max(minW / w, minH / h)
        let ceiling = min(maxW / w, maxH / h)
        return min(ceiling, max(floor, projected))
    }

    func endCardResize() {
        cardResizeSession = nil
        resizingCardID = nil
        groupResizeMembers = [:]
        clearSnapGuides()
    }

    func isResizingCard(_ id: String) -> Bool {
        resizingCardID == id
    }

    /// Exports a project as a `.vasa` package — the same self-contained layout the app
    /// already stores on disk (`board.json` + `media/`), so the copy carries its images,
    /// audio and video with it. The previous implementation wrote a bare `board.json`,
    /// whose media paths are relative to a `media/` folder that was never included.
    func exportLesson(_ id: String) {
        guard library.lessons.contains(where: { $0.id == id }) else { return }
        // The package on disk is what gets copied, so pending edits must land first.
        // Re-read afterwards: saving is what assigns `path` to a project that never had one.
        saveNow()
        guard let lesson = library.lessons.first(where: { $0.id == id }) else { return }
        let source = Persistence.lessonDirectory(lesson, subjects: library.subjects)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let panel = NSSavePanel()
        if let type = UTType("app.vasa.project") {
            panel.allowedContentTypes = [type]
        }
        // Name without the extension: AppKit owns it once the type is allowed, and
        // hides it from the field either way — spelling it out here only risks
        // "Name.vasa.vasa" if the panel ever stops recognising the type. The message
        // below is what actually tells the user what they are getting.
        panel.nameFieldStringValue = Persistence.sanitize(lesson.title)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Project"
        panel.prompt = "Export"
        panel.message = "Exports a .vasa package — the board and all of its media in one file."
        guard panel.runModal() == .OK, var dest = panel.url else { return }
        // The panel can hand back a bare name when the type is a package; keep the
        // extension so Finder still shows the result as one Vasa document.
        if dest.pathExtension.lowercased() != "vasa" {
            dest.appendPathExtension("vasa")
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            AppSounds.play(.celebration)
        } catch {
            AppSounds.play(.caution)
        }
    }

    func bringToFront(_ id: String) {
        let z = (activeLesson?.cards.map(\.z).max() ?? 0) + 1
        updateCard(id) { $0.z = z }
    }

    /// Move selection one step forward (`dir > 0`) or back (`dir < 0`) in z-order.
    /// Works for every card kind; multi-select moves as a stable block.
    func layer(_ dir: Int) {
        guard dir != 0, !selectedIDs.isEmpty, let lesson = activeLesson, lesson.cards.count > 1 else { return }
        let selected = Set(selectedIDs)
        // Need at least one unselected neighbor to move past.
        guard lesson.cards.contains(where: { !selected.contains($0.id) }) else { return }

        pushUndo()
        patchLesson { lesson in
            var cards = lesson.cards
            var order = cards.indices.sorted { a, b in
                if cards[a].z != cards[b].z { return cards[a].z < cards[b].z }
                return cards[a].id < cards[b].id
            }

            if dir > 0 {
                var i = order.count - 2
                while i >= 0 {
                    if selected.contains(cards[order[i]].id),
                       !selected.contains(cards[order[i + 1]].id)
                    {
                        order.swapAt(i, i + 1)
                    }
                    i -= 1
                }
            } else {
                var i = 1
                while i < order.count {
                    if selected.contains(cards[order[i]].id),
                       !selected.contains(cards[order[i - 1]].id)
                    {
                        order.swapAt(i - 1, i)
                    }
                    i += 1
                }
            }

            for (z, idx) in order.enumerated() {
                cards[idx].z = z
            }
            // Full array write so @Observable reliably refreshes every card kind.
            lesson.cards = cards
        }
        persistSoon()
        AppSounds.playSwipe()
    }

    /// What a given selection means for arranging: either "rebuild this group's own contents"
    /// (frame stays put, `fitGroup` wraps it afterward) or "arrange these top-level things as
    /// blocks" (children of an also-selected group are excluded — they ride with their parent).
    private enum ArrangeTarget {
        case groupContents(groupID: String, memberIDs: [String])
        case freeform(ids: [String])
    }

    /// Selection → arrange target. A lone selected group rebuilds itself. Selected cards that
    /// share one common (unselected) parent group rebuild inside that group. Anything else is
    /// a mixed/free-card selection arranged as top-level blocks, with children of a selected
    /// group excluded so they move with the group instead of being arranged individually.
    private func resolveArrangeTargets(selectedIDs: [String], cards: [Card]) -> ArrangeTarget? {
        let selectedSet = Set(selectedIDs)
        let selectedCards = cards.filter { selectedSet.contains($0.id) }
        guard !selectedCards.isEmpty else { return nil }

        if selectedCards.count == 1, let only = selectedCards.first, only.kind == .group {
            let memberIDs = cards.filter { $0.groupId == only.id }.map(\.id)
            guard memberIDs.count >= 2 else { return nil }
            return .groupContents(groupID: only.id, memberIDs: memberIDs)
        }

        let hasGroupCardSelected = selectedCards.contains { $0.kind == .group }
        if !hasGroupCardSelected {
            let groupIDs = Set(selectedCards.compactMap(\.groupId))
            if groupIDs.count == 1, let gid = groupIDs.first, selectedCards.count >= 2 {
                return .groupContents(groupID: gid, memberIDs: selectedCards.map(\.id))
            }
        }

        let topLevel = selectedCards.filter { card in
            guard let gid = card.groupId else { return true }
            return !selectedSet.contains(gid)
        }
        guard topLevel.count >= 2 else { return nil }
        return .freeform(ids: topLevel.map(\.id))
    }

    private func arrangeTargetInfo() -> (memberIDs: [String], groupID: String?)? {
        guard let lesson = activeLesson,
              let target = resolveArrangeTargets(selectedIDs: selectedIDs, cards: lesson.cards)
        else { return nil }
        switch target {
        case .groupContents(let groupID, let memberIDs): return (memberIDs, groupID)
        case .freeform(let ids): return (ids, nil)
        }
    }

    /// Order clusters read left to right in.
    private static let arrangeKindOrder: [CardKind] = [
        .note, .text, .link, .folder, .shortcut, .image, .draw, .video, .youtube, .audio, .group
    ]

    /// Organize by types: clusters the selection by `CardKind` (notes together, texts together,
    /// files/bookmarks together, videos together, ...), then compactly packs each cluster by
    /// aspect ratio (potpack) and lines the clusters up left to right. Cards keep their own
    /// size — only position changes. Deterministic: re-running on the same selection yields the
    /// same layout.
    func arrangeSelection() {
        guard let (memberIDs, groupID) = arrangeTargetInfo() else { return }
        guard performArrange(memberIDs: memberIDs) else { return }
        if let groupID { fitGroup(groupID, mode: .grow) }
    }

    // MARK: - Organize with AI

    /// Opens the "Organize with AI" prompt popup for the current selection/group.
    func openAIArrangePrompt() {
        aiArrangeError = nil
        aiArrangePromptOpen = true
    }

    private var activeAIConfig: AIProviderConfig {
        settings.aiProviders.first { $0.id == settings.activeProviderId } ?? ProviderCatalog.defaults[0]
    }

    /// Compact plain-text summary of a card for AI prompts (tagging + arrange), regardless
    /// of kind: strips HTML from note/text bodies, falls back to title/alt/url for
    /// link/image/file cards.
    private func cardSummary(_ card: Card) -> String {
        var bits: [String] = ["kind: \(card.kind.rawValue)"]
        if let title = card.title, !title.isEmpty { bits.append("title: \(title)") }
        let plain = CanvasTextEditor.plainText(html: card.html, fallback: card.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty { bits.append("text: \(String(plain.prefix(200)))") }
        if let alt = card.alt, !alt.isEmpty { bits.append("alt: \(alt)") }
        if let hostname = card.hostname, !hostname.isEmpty { bits.append("site: \(hostname)") }
        if let url = card.url, !url.isEmpty, card.hostname == nil { bits.append("url: \(url)") }
        if let color = card.color { bits.append("color: \(color)") }
        if let tags = card.tags {
            var hints: [String] = []
            if let theme = tags.theme { hints.append("theme=\(theme)") }
            if let subject = tags.subject { hints.append("subject=\(subject)") }
            if let colorTag = tags.colorTag { hints.append("colorTag=\(colorTag)") }
            if !hints.isEmpty { bits.append("tags: \(hints.joined(separator: ", "))") }
        }
        return bits.joined(separator: " | ")
    }

    /// Loads an image card's bytes as a base64 `data:` URL for the GigaChat vision path — local
    /// files via `ImageMedia.fileURL`/`Data(contentsOf:)`, remote via `URLSession`. MIME type is
    /// sniffed from the file extension (defaulting to `image/jpeg`); any failure returns `nil` so
    /// the caller can silently skip that card's vision classification.
    private func imageDataURL(for card: Card) async -> String? {
        guard let src = card.src, !src.isEmpty else { return nil }
        let mime: String
        switch (src as NSString).pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "jpg", "jpeg": mime = "image/jpeg"
        default: mime = "image/jpeg"
        }
        let data: Data?
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let url = URL(string: src) else { return nil }
            data = try? await URLSession.shared.data(from: url).0
        } else if let fileURL = ImageMedia.fileURL(from: src) {
            data = try? Data(contentsOf: fileURL)
        } else {
            data = nil
        }
        guard let data, !data.isEmpty else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Runs the GigaChat vision classification pass on `images` (capped by caller) via the
    /// `giga-vision` gateway route, returning the same `[id: theme/subject/colorTag]`-shaped
    /// entries the text path produces so both merge into one final pass. Returns `[]` on any
    /// failure (missing token, network, malformed JSON) — callers treat that as "skip vision
    /// classification for these cards", matching each call site's existing failure contract.
    private func classifyImagesWithVision(_ images: [Card], instructionsPrefix: String) async -> [[String: Any]] {
        guard !images.isEmpty else { return [] }
        let apiKey = ChatKeychain.load("giga-vision")
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let handler = APIServiceFactory.handler(for: ProviderCatalog.gigaVision) as? ChatGPTHandler else { return [] }

        var payload: [(cardId: String, dataURL: String)] = []
        for card in images {
            guard let dataURL = await imageDataURL(for: card) else { continue }
            payload.append((cardId: card.id, dataURL: dataURL))
        }
        guard !payload.isEmpty else { return [] }

        let instructions = instructionsPrefix + "\n\nEach input_image block carries a \"card_id\" — use that exact id in your JSON \"id\" field."
        do {
            let raw = try await handler.sendVisionRequest(imageDataURLs: payload, instructions: instructions, apiKey: apiKey)
            let cleaned = Self.stripThinking(raw)
            return Self.extractJSONArray(cleaned) ?? []
        } catch {
            return []
        }
    }

    /// Strips `<think>...</think>` reasoning blocks a model may emit before its JSON answer.
    private static func stripThinking(_ text: String) -> String {
        guard let range = text.range(of: "</think>") else { return text }
        return String(text[range.upperBound...])
    }

    /// Finds the first `[...]` JSON array substring in `text` (models sometimes wrap JSON in
    /// prose or code fences despite instructions) and decodes it with `JSONSerialization`.
    private static func extractJSONArray(_ text: String) -> [[String: Any]]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return nil }
        let slice = text[start...end]
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Parses the `id|group|role` plain-line clustering protocol shared by `arrangeWithAI` and
    /// `smartPasteAIPlan` — cheaper than JSON per card, and easy to line-scan defensively since a
    /// model occasionally transposes the last two columns (role is the one constrained to a
    /// fixed vocabulary, so it identifies which column is which).
    private static func parsePlanLines(_ text: String, validIDs: Set<String>) -> [String: (group: String, role: CardRole)] {
        var plan: [String: (group: String, role: CardRole)] = [:]
        for line in stripThinking(text).split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 3, validIDs.contains(fields[0]) else { continue }
            guard let role = CardRole(rawValue: fields[1].lowercased()) ?? CardRole(rawValue: fields[2].lowercased()) else { continue }
            let group = CardRole(rawValue: fields[1].lowercased()) != nil ? fields[2] : fields[1]
            plan[fields[0]] = (group: group, role: role)
        }
        return plan
    }

    /// Chat replies may end with a hidden `<<ARRANGE: criterion>>` line (see
    /// `VasaChatPrompt.instructions`) when the user asked the assistant to organize/group the
    /// board. Strips that line from the displayed text and returns the criterion, if present.
    static func extractArrangeDirective(from text: String) -> (clean: String, criterion: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"<<ARRANGE:\s*(.+?)\s*>>"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let fullRange = Range(match.range, in: text),
              let criterionRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let criterion = String(text[criterionRange])
        var clean = text
        clean.removeSubrange(fullRange)
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), criterion)
    }

    /// One entry in a hidden `<<CARDS: [...]>>` directive (see `VasaChatPrompt.instructions`).
    /// `kind` is `"note"`, `"text"`, or `"link"`; the remaining fields are kind-appropriate and
    /// all optional at the decode level — `createCardsFromChat` validates per-kind requirements
    /// and silently skips any spec that doesn't fit, rather than crashing on malformed AI output.
    struct AIChatCardSpec: Decodable {
        var kind: String
        var title: String?
        var body: String?
        var url: String?
        var color: String?
        /// Short cluster label. Specs sharing a non-empty, exact-match `group` are wrapped
        /// together into a group plaque (mirrors manual ⌘G grouping); omitted/empty means
        /// a standalone card.
        var group: String?
    }

    /// Parses a hidden `<<CARDS: [...]>>` directive out of a chat reply (see `VasaChatPrompt`),
    /// mirroring `extractArrangeDirective`'s regex-strip pattern. Returns nil if no directive is
    /// present or its JSON payload fails to decode — never crashes on malformed AI output.
    static func extractCardsDirective(from text: String) -> (clean: String, specs: [AIChatCardSpec])? {
        guard let regex = try? NSRegularExpression(pattern: #"<<CARDS:\s*(\[.+?\])\s*>>"#, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let fullRange = Range(match.range, in: text),
              let jsonRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let json = String(text[jsonRange])
        guard let data = json.data(using: .utf8),
              var specs = try? JSONDecoder().decode([AIChatCardSpec].self, from: data)
        else { return nil }
        // Some gateway/model round-trips mangle non-ASCII text into classic "UTF-8 decoded as
        // Latin-1" mojibake (e.g. "Название" → "Íàçâàíèå") somewhere between the model and us —
        // repair it per-field so created cards show correct Cyrillic/etc. instead of garbage.
        for i in specs.indices {
            specs[i].title = specs[i].title.map(repairMojibake)
            specs[i].body = specs[i].body.map(repairMojibake)
            specs[i].group = specs[i].group.map(repairMojibake)
        }
        var clean = text
        clean.removeSubrange(fullRange)
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), specs)
    }

    /// Reverses the classic "UTF-8 bytes mis-decoded as Latin-1/Windows-1252" mojibake pattern
    /// (e.g. Cyrillic "Название" arriving as "Íàçâàíèå") by reinterpreting the string's Latin-1
    /// byte values as UTF-8. Only applied when that round-trip actually yields valid, DIFFERENT
    /// text — normal ASCII/already-correct text simply fails the round-trip and passes through
    /// unchanged, so this can never mangle good text.
    /// A fixed 220×80 box (the old default) overflows/overlaps its neighbors for anything longer
    /// than a couple words — size AI-created "text" cards to their actual content instead, same
    /// idea as the manual text tool auto-growing as you type. Wraps at a compact max width and
    /// grows height to fit, clamped to sane min/max so a one-word card isn't tiny and a long
    /// paragraph (which should really have been a "note", but defend against it anyway) doesn't
    /// become an unreasonably tall sliver.
    private static func measureTextCardSize(_ text: String, fontSize: Double) -> CGSize {
        let maxWidth: CGFloat = 320
        let minWidth: CGFloat = 120
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let fit = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = max(minWidth, min(maxWidth, ceil(fit.width) + 24))
        let height = max(48, min(320, ceil(fit.height) + 24))
        return CGSize(width: width, height: height)
    }

    private static func repairMojibake(_ s: String) -> String {
        guard let latin1 = s.data(using: .isoLatin1),
              let repaired = String(data: latin1, encoding: .utf8),
              repaired != s
        else { return s }
        return repaired
    }

    /// Best-effort, silent background pass: finds cards in `lessonId` with no `tags` yet,
    /// batches up to 40 of them, and asks the active AI provider for a compact
    /// theme/subject/colorTag classification in one request. Failures (no API key, network,
    /// malformed JSON) are swallowed — this is enrichment, not a user-initiated action.
    func autoTagUntaggedCards(in lessonId: String) {
        guard let lesson = library.lessons.first(where: { $0.id == lessonId }) else { return }
        let untagged = Array(lesson.cards.filter { $0.tags == nil }.prefix(40))
        guard !untagged.isEmpty else { return }

        // Image cards go through the GigaChat vision path (no vision support on the "giga"
        // DeepSeek route); everything else keeps the existing text classification, unchanged.
        let imageCards = Array(untagged.filter { $0.kind == .image }.prefix(20))
        let textCards = untagged.filter { $0.kind != .image }

        let config = activeAIConfig
        let apiKey = ChatKeychain.load(config.id)
        let lessonIdCaptured = lessonId

        let classifyPrompt = """
        Classify each card below with a short theme, subject, and dominant color tone. \
        Respond with ONLY a JSON array, no prose, no code fences, shaped exactly like:
        [{"id": "<card id>", "theme": "<1-3 word topic>", "subject": "<1-2 word coarse bucket, e.g. school/personal/reference>", "colorTag": "<1-2 word dominant visual tone, e.g. warm/blue/monochrome>"}]
        """

        Task { [weak self] in
            guard let self else { return }
            var entries: [[String: Any]] = []

            if !textCards.isEmpty, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cardsPayload = textCards.map { "{\"id\": \"\($0.id)\", \"summary\": \"\(self.cardSummary($0).replacingOccurrences(of: "\"", with: "'"))\"}" }
                    .joined(separator: ",\n")
                let prompt = classifyPrompt + "\n\nCards:\n[\(cardsPayload)]"
                let handler = APIServiceFactory.handler(for: config)
                let settingsGen = GenerationSettings(model: config.defaultModel)
                var accumulated = ""
                do {
                    let stream = handler.sendMessageStream(
                        history: [RequestMessage(role: .user, content: prompt)],
                        systemPrompt: "You are a silent classification service. Output only valid JSON, nothing else.",
                        settings: settingsGen,
                        apiKey: apiKey
                    )
                    for try await delta in stream {
                        guard !Task.isCancelled else { return }
                        if let text = delta.text { accumulated += text }
                    }
                    if !Task.isCancelled {
                        let cleaned = Self.stripThinking(accumulated)
                        entries += Self.extractJSONArray(cleaned) ?? []
                    }
                } catch {
                    // Text classification failure — best-effort, keep going with images if any.
                }
            }

            guard !Task.isCancelled else { return }

            if !imageCards.isEmpty {
                let visionInstructions = classifyPrompt + "\n\nEach image is one card to classify from its visual content."
                entries += await self.classifyImagesWithVision(imageCards, instructionsPrefix: visionInstructions)
            }

            guard !Task.isCancelled, !entries.isEmpty else { return }
            await MainActor.run {
                guard self.activeLesson?.id == lessonIdCaptured || self.library.lessons.contains(where: { $0.id == lessonIdCaptured }) else { return }
                let now = Date().timeIntervalSince1970 * 1000
                for entry in entries {
                    guard let id = entry["id"] as? String else { continue }
                    let theme = entry["theme"] as? String
                    let subject = entry["subject"] as? String
                    let colorTag = entry["colorTag"] as? String
                    guard theme != nil || subject != nil || colorTag != nil else { continue }
                    self.setCardTags(id, in: lessonIdCaptured, theme: theme, subject: subject, colorTag: colorTag, updatedAt: now)
                }
            }
        }
    }

    /// Applies AI-derived tags to a card in `lessonId` without requiring it to be the active
    /// lesson (auto-tagging can complete after the user has switched lessons).
    private func setCardTags(_ id: String, in lessonId: String, theme: String?, subject: String?, colorTag: String?, updatedAt: Double) {
        guard let lessonIdx = library.lessons.firstIndex(where: { $0.id == lessonId }),
              let cardIdx = library.lessons[lessonIdx].cards.firstIndex(where: { $0.id == id })
        else { return }
        library.lessons[lessonIdx].cards[cardIdx].tags = CardTags(theme: theme, subject: subject, colorTag: colorTag, updatedAt: updatedAt)
        library.lessons[lessonIdx].updatedAt = updatedAt
        dirtyLessonIDs.insert(lessonId)
        persistSoon()
    }

    /// Prompt-driven semantic clustering: asks the active AI provider to group the current
    /// selection/group by a user-typed criterion (theme, color, subject, or anything else),
    /// then packs the resulting clusters the same way "Organize by types" does.
    /// Every top-level (non-group-child) card in a lesson — the fallback target for a chat-driven
    /// "arrange"/"organize" request when the user has nothing selected on the canvas.
    func allArrangeableCardIDs(in lesson: Lesson) -> [String] {
        lesson.cards.filter { $0.groupId == nil }.map(\.id)
    }

    @MainActor
    func arrangeWithAI(criterion: String, targetOverride: (memberIDs: [String], groupID: String?)? = nil) async {
        let trimmedCriterion = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCriterion.isEmpty else {
            aiArrangeError = "Type a criterion to organize by."
            return
        }
        guard let (memberIDs, groupID) = targetOverride ?? arrangeTargetInfo(), let lesson = activeLesson else {
            aiArrangePromptOpen = false
            return
        }
        autoTagUntaggedCards(in: lesson.id)
        let items = lesson.cards.filter { memberIDs.contains($0.id) }
        guard items.count >= 2 else {
            aiArrangePromptOpen = false
            return
        }

        let config = activeAIConfig
        let apiKey = ChatKeychain.load(config.id)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiArrangeError = APIError.missingToken.localizedDescription
            return
        }

        aiArrangeInFlight = true
        aiArrangeError = nil
        aiArrangeCriterion = criterion

        // Image cards go through the GigaChat vision path (no vision support on the "giga"
        // DeepSeek route); everything else keeps the existing text clustering, unchanged.
        let imageItems = items.filter { $0.kind == .image }
        let textItems = items.filter { $0.kind != .image }

        var plan: [String: (group: String, role: CardRole)] = [:]

        // Plain `id|group|role` lines instead of JSON — no braces/quotes/keys repeated per card,
        // so the same context budget covers a much bigger selection, and role lets the layout be
        // a real composition (one hero anchoring each cluster) instead of a uniform grid.
        let clusterPrompt = """
        Cluster these cards by the following criterion: "\(trimmedCriterion)", then give each one \
        a compositional role.

        Respond with ONLY plain lines, one per card, no prose, no code fences, no JSON — exactly:
        id|group|role

        Rules:
        - group: a short cluster label (1-3 words) matching the criterion.
        - role: exactly one of hero, caption, meta, accent.
          hero = the card that most anchors its cluster (the main subject, image, or link).
          caption = short text naming/describing the hero.
          meta = secondary small text (numbers, handles, tags).
          accent = a related but independent card that isn't the hero.
          Every group needs exactly one hero; a lone card in its own group is that card's own hero.
        - Cards already carrying `tags` (theme/subject/colorTag) are strong hints for their cluster.
        - Every card id must appear exactly once.
        """

        if !textItems.isEmpty {
            let cardLines = textItems.map { "\($0.id)|\($0.kind.rawValue)|\(cardSummary($0).replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " "))" }
                .joined(separator: "\n")
            let prompt = clusterPrompt + "\n\nCards, one per line as `id|kind|summary`:\n\(cardLines)"
            let handler = APIServiceFactory.handler(for: config)
            let settingsGen = GenerationSettings(model: config.defaultModel)

            var accumulated = ""
            do {
                let stream = handler.sendMessageStream(
                    history: [RequestMessage(role: .user, content: prompt)],
                    systemPrompt: "You are a silent layout-planning service. Output only the requested plain-line commands, nothing else.",
                    settings: settingsGen,
                    apiKey: apiKey
                )
                for try await delta in stream {
                    if let text = delta.text { accumulated += text }
                }
                let ids = Set(textItems.map(\.id))
                plan.merge(Self.parsePlanLines(accumulated, validIDs: ids)) { current, _ in current }
            } catch {
                aiArrangeInFlight = false
                aiArrangeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppSounds.play(.caution)
                return
            }
        }

        if !imageItems.isEmpty {
            let visionInstructions = """
            Cluster these images by the following criterion: "\(trimmedCriterion)".

            Respond with ONLY a JSON array, no prose, no code fences, shaped exactly like:
            [{"id": "<card id>", "group": "<short cluster label, 1-3 words>"}]

            Every card id must appear exactly once.
            """
            let capped = Array(imageItems.prefix(20))
            let visionEntries = await classifyImagesWithVision(capped, instructionsPrefix: visionInstructions)
            if visionEntries.isEmpty, textItems.isEmpty {
                // Images were the whole batch and vision classification produced nothing usable
                // (missing giga token, network failure, or bad JSON) — surface the same
                // user-facing error the text path uses for a decode failure.
                aiArrangeInFlight = false
                aiArrangeError = ChatKeychain.hasToken("giga-vision")
                    ? APIError.decode.localizedDescription
                    : APIError.missingToken.localizedDescription
                AppSounds.play(.caution)
                return
            }
            // Vision doesn't reason about composition roles — an image is naturally what a
            // cluster anchors around, so it defaults to hero.
            for entry in visionEntries {
                guard let id = entry["id"] as? String, let group = entry["group"] as? String else { continue }
                plan[id] = (group: group, role: .hero)
            }
        }

        guard !plan.isEmpty else {
            aiArrangeInFlight = false
            aiArrangeError = APIError.decode.localizedDescription
            AppSounds.play(.caution)
            return
        }

        guard performArrangeByPlan(memberIDs: memberIDs, plan: plan) else {
            aiArrangeInFlight = false
            aiArrangeError = "Couldn't lay out the result."
            AppSounds.play(.caution)
            return
        }
        if let groupID { fitGroup(groupID, mode: .grow) }

        aiArrangeInFlight = false
        aiArrangePromptOpen = false
        AppSounds.play(.celebration)
    }

    /// Computes new origins for `memberIDs` grouped by kind and applies them as position deltas.
    /// Cards not in `memberIDs` but whose group is (i.e. children riding with a selected group
    /// block) follow their parent's delta.
    @discardableResult
    private func performArrange(memberIDs: [String]) -> Bool {
        performArrangeByGroups(
            memberIDs: memberIDs,
            groupKey: { $0.kind.rawValue },
            orderedKeys: { keys in
                Self.arrangeKindOrder.map(\.rawValue).filter { keys.contains($0) }
                    + keys.filter { key in !Self.arrangeKindOrder.map(\.rawValue).contains(key) }.sorted()
            }
        )
    }

    /// Shared core of "Organize by types" and "Organize with AI": clusters `memberIDs` by
    /// `groupKey`, orders the clusters with `orderedKeys` (given the set of keys present),
    /// compactly packs each cluster (potpack) and lines the clusters up left to right, then
    /// applies the resulting positions as deltas. Cards keep their own size — only position
    /// changes. Cards not in `memberIDs` but whose group is (children riding with a selected
    /// group block) follow their parent's delta.
    @discardableResult
    private func performArrangeByGroups<Key: Hashable>(
        memberIDs: [String],
        groupKey: (Card) -> Key,
        orderedKeys: ([Key]) -> [Key]
    ) -> Bool {
        guard let lesson = activeLesson else { return false }
        let items = lesson.cards.filter { memberIDs.contains($0.id) }
        guard items.count >= 2 else { return false }

        let anchor = CGPoint(x: items.map(\.x).min() ?? 0, y: items.map(\.y).min() ?? 0)
        let gap = ArrangeEngine.autoGap(frames: items.map(\.frame))
        let clusterGap = gap * 2

        let groups = Dictionary(grouping: items, by: groupKey)
        var newOrigins: [String: CGPoint] = [:]
        var cursorX = anchor.x
        for key in orderedKeys(Array(groups.keys)) {
            guard let cluster = groups[key], !cluster.isEmpty else { continue }
            let clusterAnchor = CGPoint(x: cursorX, y: anchor.y)
            let packItems = cluster.map { (id: $0.id, size: CGSize(width: $0.previewWidth, height: $0.previewHeight)) }
            let origins = ArrangeEngine.packLayout(items: packItems, gap: gap, anchor: clusterAnchor)
            newOrigins.merge(origins) { current, _ in current }
            let clusterMaxX = cluster.reduce(clusterAnchor.x) { maxX, card in
                guard let origin = origins[card.id] else { return maxX }
                return max(maxX, origin.x + card.previewWidth)
            }
            cursorX = clusterMaxX + clusterGap
        }

        var deltas: [String: CGVector] = [:]
        for card in items {
            guard let origin = newOrigins[card.id] else { continue }
            deltas[card.id] = CGVector(dx: origin.x - card.x, dy: origin.y - card.y)
        }
        guard !deltas.isEmpty else { return false }

        pushUndo()
        patchLesson { lesson in
            var cards = lesson.cards
            for i in cards.indices {
                if let delta = deltas[cards[i].id] {
                    cards[i].x += delta.dx
                    cards[i].y += delta.dy
                } else if let gid = cards[i].groupId, let delta = deltas[gid] {
                    cards[i].x += delta.dx
                    cards[i].y += delta.dy
                }
            }
            lesson.cards = cards
        }
        persistSoon()
        AppSounds.playSwipe()
        return true
    }

    /// Composition variant of the old label-only arrange: instead of packing each cluster into a
    /// uniform potpack grid, a cluster whose cards all carry an AI-assigned `CardRole` is laid
    /// out by `ComposeEngine` — one hero anchors it, caption/meta text racks beside it at
    /// rule-of-thirds/golden-ratio points, accents sit off to the side — same as `smartPaste`'s
    /// composition, applied to an existing selection instead of freshly-pasted cards. No
    /// frame/plaque is created; proximity alone signals the group, matching `smartPaste` — the
    /// user wraps a cluster themselves (⌘G) if they want that. A cluster missing full role
    /// coverage falls back to a top-to-bottom stack (≤4 cards) or potpack grid, same as
    /// `smartPaste`'s heuristic path. Everything lands in one undo step / one `patchLesson` batch.
    @discardableResult
    private func performArrangeByPlan(memberIDs: [String], plan: [String: (group: String, role: CardRole)]) -> Bool {
        guard let lesson = activeLesson else { return false }
        let items = lesson.cards.filter { memberIDs.contains($0.id) }
        guard items.count >= 2 else { return false }

        var clusterOrder: [String] = []
        var groups: [String: [Card]] = [:]
        for card in items {
            let label = plan[card.id]?.group.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (label?.isEmpty == false ? label! : "Other")
            if groups[key] == nil { clusterOrder.append(key) }
            groups[key, default: []].append(card)
        }
        clusterOrder.sort { a, b in
            let ca = groups[a]?.count ?? 0, cb = groups[b]?.count ?? 0
            if ca != cb { return ca > cb }
            if a == "Other" { return false }
            if b == "Other" { return true }
            return a < b
        }

        let anchor = CGPoint(x: items.map(\.x).min() ?? 0, y: items.map(\.y).min() ?? 0)
        let gap = ArrangeEngine.autoGap(frames: items.map(\.frame))
        // Intra-cluster spacing stays tight (independent of the canvas-wide median `gap`, which
        // can run up to 48pt) — only the gap *between* clusters should read as a visible break.
        let intraGap = min(gap, 16)
        let interClusterGap = gap * 2
        var cursorX = anchor.x
        var updated: [String: CGPoint] = [:]

        for label in clusterOrder {
            guard var members = groups[label], !members.isEmpty else { continue }
            let clusterAnchor = CGPoint(x: cursorX, y: anchor.y)
            var origins: [String: CGPoint]
            if members.allSatisfy({ plan[$0.id] != nil }) {
                let composeItems = members.map { (id: $0.id, role: plan[$0.id]!.role, size: CGSize(width: $0.previewWidth, height: $0.previewHeight)) }
                origins = ComposeEngine.compose(items: composeItems, anchor: clusterAnchor, gap: intraGap)
            } else {
                let packItems = members.map { (id: $0.id, size: CGSize(width: $0.previewWidth, height: $0.previewHeight)) }
                origins = members.count <= 4
                    ? ArrangeEngine.stackLayout(items: packItems, gap: intraGap, anchor: clusterAnchor)
                    : ArrangeEngine.packLayout(items: packItems, gap: intraGap, anchor: clusterAnchor)
            }
            if let minX = origins.values.map(\.x).min(), minX != cursorX {
                let dx = cursorX - minX
                origins = origins.mapValues { CGPoint(x: $0.x + dx, y: $0.y) }
            }
            for i in members.indices {
                if let origin = origins[members[i].id] {
                    members[i].x = origin.x
                    members[i].y = origin.y
                }
            }
            // Proximity alone signals the group — no auto-created plaque; wrapping a cluster is
            // a deliberate user action (⌘G) afterward.
            let clusterBounds = members.reduce(CGRect(origin: clusterAnchor, size: .zero)) { $0.union($1.frame) }
            cursorX = clusterBounds.maxX + interClusterGap
            for card in members { updated[card.id] = CGPoint(x: card.x, y: card.y) }
        }
        guard !updated.isEmpty else { return false }

        pushUndo()
        patchLesson { lesson in
            for i in lesson.cards.indices {
                guard let origin = updated[lesson.cards[i].id] else { continue }
                lesson.cards[i].x = origin.x
                lesson.cards[i].y = origin.y
            }
        }
        selectedIDs = Array(updated.keys)
        persistSoon()
        AppSounds.playSwipe()
        return true
    }

    func nudge(_ dx: Double, _ dy: Double) {
        guard !selectedIDs.isEmpty else { return }
        pushUndo()
        moveCards(selectedIDs, dx: dx, dy: dy)
        persistSoon()
    }

    func duplicateSelected() {
        guard let lesson = activeLesson else { return }
        pushUndo()
        let moving = idsMoving(with: selectedIDs)
        let source = lesson.cards.filter { moving.contains($0.id) }
        let copies = remappedCopies(source, dx: 24, dy: 24)
        patchLesson { $0.cards.append(contentsOf: copies.cards) }
        selectedIDs = copies.selected
        persistSoon()
    }

    func copySelected() {
        let moving = idsMoving(with: selectedIDs)
        let cards = activeLesson?.cards.filter { moving.contains($0.id) } ?? []
        clipboard = cards

        let pb = NSPasteboard.general
        pb.clearContents()
        let fileURLs: [URL] = cards.compactMap { card in
            guard let src = card.src, let url = Self.mediaURL(from: src), url.isFileURL else { return nil }
            return url
        }
        if !fileURLs.isEmpty {
            pb.writeObjects(fileURLs as [NSPasteboardWriting])
        }
        clipboardChangeCount = pb.changeCount
    }

    func paste(at point: CGPoint) {
        if !clipboard.isEmpty, NSPasteboard.general.changeCount == clipboardChangeCount {
            pushUndo()
            let minX = clipboard.map(\.x).min() ?? 0
            let minY = clipboard.map(\.y).min() ?? 0
            let copies = remappedCopies(clipboard, dx: point.x - minX, dy: point.y - minY)
            patchLesson { lesson in
                var z = (lesson.cards.map(\.z).max() ?? 0)
                var cards = copies.cards
                for i in cards.indices {
                    z += 1
                    cards[i].z = z
                }
                lesson.cards.append(contentsOf: cards)
            }
            selectedIDs = copies.selected
            persistSoon()
            return
        }
        Task { await pasteFromPasteboard(at: point) }
    }

    private func remappedCopies(_ source: [Card], dx: Double, dy: Double) -> (cards: [Card], selected: [String]) {
        let idMap = Dictionary(uniqueKeysWithValues: source.map { ($0.id, VasaID.make("c")) })
        let selectedSet = Set(selectedIDs)
        var selected: [String] = []
        let cards = source.map { card -> Card in
            var c = card
            c.id = idMap[card.id] ?? VasaID.make("c")
            c.x += dx
            c.y += dy
            if let gid = c.groupId {
                c.groupId = idMap[gid]
            }
            if selectedSet.contains(card.id) { selected.append(c.id) }
            return c
        }
        if selected.isEmpty { selected = cards.map(\.id) }
        return (cards, selected)
    }

    func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        Task { await confirmDelete() }
    }

    func confirmDelete() async {
        let cards = activeLesson?.cards.filter { selectedIDs.contains($0.id) } ?? []
        let prompt: (String, String) = {
            if cards.count != 1 {
                return ("Delete these objects?", "This will permanently delete the selected objects.")
            }
            switch cards.first?.kind {
            case .note: return ("Delete this note?", "This will permanently delete the note content.")
            case .image: return ("Delete this image?", "This will permanently delete the image from the board.")
            case .audio: return ("Delete this sound?", "This will permanently delete the sound from the board.")
            case .video, .youtube: return ("Delete this video?", "This will permanently delete the video from the board.")
            case .link: return ("Delete this link?", "This will permanently delete the link from the board.")
            case .group: return ("Delete this group?", "Objects inside the group will also be deleted.")
            default: return ("Delete this?", "This will permanently delete the object from the board.")
            }
        }()
        let alert = NSAlert()
        alert.messageText = prompt.0
        alert.informativeText = prompt.1
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        AppSounds.play(.caution)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pushUndo()
        var doomed = cards
        if let lesson = activeLesson {
            let groupIDs = Set(cards.filter { $0.kind == .group }.map(\.id))
            if !groupIDs.isEmpty {
                let extras = lesson.cards.filter { card in
                    guard let gid = card.groupId else { return false }
                    return groupIDs.contains(gid) && !doomed.contains(where: { $0.id == card.id })
                }
                doomed.append(contentsOf: extras)
            }
        }
        let ids = Set(doomed.map(\.id))
        if let playingID, ids.contains(playingID) {
            Playback.shared.stop()
            self.playingID = nil
            playbackPaused = false
        }
        let base = (deleteWaves.map(\.id).max() ?? 0)
        let stamp = Date.now
        let bursts: [DeleteWaveEvent] = doomed.enumerated().map { offset, card in
            DeleteWaveEvent(
                id: base + offset + 1,
                x: card.x + card.previewWidth / 2,
                y: card.y + card.previewHeight / 2,
                width: card.previewWidth,
                height: card.previewHeight,
                cornerRadius: card.dissolveCornerRadius,
                startedAt: stamp
            )
        }
        patchLesson { lesson in
            // Deleting the card the sidebar cover was derived from would otherwise leave
            // `thumb` pointing at a file that no longer exists — fall back to the next
            // available media card instead of showing a blank/missing cover.
            let removedCoverSource = lesson.thumb != nil && doomed.contains { card in
                (card.kind == .image && card.src == lesson.thumb)
                    || (card.kind == .video && card.poster == lesson.thumb)
            }
            lesson.cards.removeAll { ids.contains($0.id) }
            if removedCoverSource {
                lesson.thumb = lesson.cards.first(where: { $0.kind == .image })?.src
                    ?? lesson.cards.first(where: { $0.kind == .video })?.poster
            }
        }
        selectedIDs = []
        noteOpenID = nil
        menu = nil
        editingID = nil
        deleteWaves.append(contentsOf: bursts)
        persistSoon()
        AppSounds.play(.button)
    }

    func finishDeleteWave(_ id: Int) {
        deleteWaves.removeAll { $0.id == id }
    }

    func pushUndo() {
        guard let lesson = activeLesson else { return }
        past.append((lesson.id, lesson.cards))
        if past.count > 40 { past.removeFirst() }
        future = []
    }

    func undo() {
        guard let snap = past.popLast(), snap.lessonID == library.activeLessonId, let lesson = activeLesson else { return }
        future.append((lesson.id, lesson.cards))
        patchLesson { $0.cards = snap.cards }
        selectedIDs = []
        persistSoon()
    }

    func redo() {
        guard let snap = future.popLast(), snap.lessonID == library.activeLessonId, let lesson = activeLesson else { return }
        past.append((lesson.id, lesson.cards))
        patchLesson { $0.cards = snap.cards }
        selectedIDs = []
        persistSoon()
    }

    func setPlaying(_ id: String?) {
        if id == nil {
            Playback.shared.stop()
            playingID = nil
            playbackPaused = false
            return
        }
        guard let card = card(id!) else { return }
        playbackPaused = false
        if card.kind == .audio, let src = card.src, !src.isEmpty {
            guard let url = Self.mediaURL(from: src) else {
                playingID = nil
                return
            }
            Playback.shared.playAudio(url: url, durationHint: Format.parseDuration(card.duration))
            playingID = id
        } else if card.kind == .video, let src = card.src, !src.isEmpty {
            guard let url = Self.mediaURL(from: src) else {
                playingID = nil
                return
            }
            guard Playback.shared.playVideo(url: url) != nil else {
                playingID = nil
                return
            }
            if let duration = card.duration {
                let hint = Format.parseDuration(duration)
                if hint > 0 { Playback.shared.durationSeconds = hint }
            }
            playingID = id
        } else if card.kind == .youtube {
            Playback.shared.stop()
            playingID = id
        } else if card.kind == .audio {
            Playback.shared.durationSeconds = Format.parseDuration(card.duration)
            playingID = id
        } else {
            Playback.shared.stop()
            playingID = nil
        }
    }

    /// Resolve stored media `src` (file URL, absolute path, or http) to a playable URL.
    static func mediaURL(from src: String) -> URL? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file:") {
            return URL(string: trimmed)
        }
        return URL(fileURLWithPath: trimmed)
    }

    func togglePlay(_ id: String) {
        if playingID == id {
            if playbackPaused {
                Playback.shared.resume()
                playbackPaused = false
            } else {
                Playback.shared.pause()
                playbackPaused = true
            }
            return
        }
        setPlaying(id)
    }

    func seekPlay(_ id: String, fraction: Double) {
        if playingID != id {
            setPlaying(id)
        }
        if card(id)?.src == nil || card(id)?.src?.isEmpty == true {
            Playback.shared.durationSeconds = max(Playback.shared.durationSeconds, Format.parseDuration(card(id)?.duration))
        }
        Playback.shared.seek(fraction: fraction)
    }

    /// Gestures shorter than this that somehow crossed the drag threshold still count as taps.
    private static let textToolTapMaxDuration: TimeInterval = 0.15

    func dispatchTextTool(_ action: TextToolAction, threshold: CGFloat? = nil) {
        switch action {
        case .pointerDown(let point):
            textToolPointerDownAt = Date()
            textToolOrigin = point
            if let threshold { textToolThreshold = threshold }
        default:
            break
        }

        let (next, effect) = TextToolReducer.reduce(
            state: textToolState,
            action: action,
            makeID: { VasaID.make("c") },
            threshold: textToolThreshold
        )

        // Fast click that jittered past the distance threshold → still a tap.
        let resolved: TextToolEffect
        if case .commitSized(let id, _) = effect,
           let downAt = textToolPointerDownAt,
           Date().timeIntervalSince(downAt) < Self.textToolTapMaxDuration,
           let origin = textToolOrigin
        {
            resolved = .createBlank(at: origin, id: id)
        } else {
            resolved = effect
        }

        textToolState = next
        applyTextToolEffect(resolved)

        switch action {
        case .pointerUp, .escape, .toolSwitched:
            textToolPointerDownAt = nil
            textToolOrigin = nil
        default:
            break
        }
    }

    /// Escape while armed/creating cancels the gesture; while editing, fall through.
    @discardableResult
    func handleTextToolEscape() -> Bool {
        switch textToolState {
        case .armed, .creating:
            dispatchTextTool(.escape)
            return true
        case .idle, .editing:
            return false
        }
    }

    /// Called when a text card resigns editing — one rule for empty discard.
    func finishTextEditing(cardID: String) {
        guard let card = card(cardID), card.kind == .text else {
            if case .editing(let id) = textToolState, id == cardID {
                textToolState = .idle
            }
            return
        }
        let plain = (card.body ?? CanvasTextEditor.plainText(html: card.html, fallback: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.isEmpty {
            dispatchTextTool(.blurEmpty(cardID))
        } else {
            dispatchTextTool(.blurNonEmpty(cardID))
            saveNow()
        }
    }

    func insertBlankText(at point: CGPoint? = nil) {
        let point = point ?? lastWorld
        let size = TextToolReducer.defaultSize
        let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        let id = VasaID.make("c")
        placeTextCard(id: id, at: origin, size: size)
        textToolState = .editing(cardID: id)
        textCreatePreview = nil
    }

    private func applyTextToolEffect(_ effect: TextToolEffect) {
        switch effect {
        case .none:
            break
        case .clearPreview:
            textCreatePreview = nil
        case .resizePreview(let rect):
            textCreatePreview = rect
        case .createBlank(let point, let id):
            textCreatePreview = nil
            // Center the square on the click — top-left anchoring puts the burst beside the cursor.
            let size = TextToolReducer.defaultSize
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            placeTextCard(id: id, at: origin, size: size)
        case .commitSized(let id, let rect):
            textCreatePreview = nil
            let sized = TextToolReducer.clampedSizedRect(rect)
            placeTextCard(
                id: id,
                at: CGPoint(x: sized.minX, y: sized.minY),
                size: CGSize(width: sized.width, height: sized.height)
            )
        case .discard(let id):
            textCreatePreview = nil
            silentlyRemoveCard(id)
        }
    }

    private func placeTextCard(id: String, at origin: CGPoint, size: CGSize) {
        // Commit/discard any prior text edit before opening the new blank
        // (avoids orphan empty cards on rapid re-clicks).
        if let prev = editingID, prev != id {
            let plain = (card(prev)?.body ?? CanvasTextEditor.plainText(html: card(prev)?.html, fallback: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            editingID = nil
            activeCanvasTextView = nil
            if plain.isEmpty {
                patchLesson { $0.cards.removeAll { $0.id == prev } }
                selectedIDs.removeAll { $0 == prev }
            } else {
                saveNow()
            }
        }

        lastWorld = origin
        var card = DemoLibrary.base(id, .text, origin.x, origin.y, size.width, size.height, 1)
        card.html = ""
        card.body = ""
        card.fontSize = 16
        addCard(card)
        AppSounds.play(.pasteBlock)
        editingID = id
        clearTextSelection()
        tool = .select
        selectedIDs = [id]
        let waveID = (textWave?.id ?? 0) + 1
        textWave = TextWaveEvent(
            id: waveID,
            x: origin.x + size.width / 2,
            y: origin.y + size.height / 2,
            width: size.width,
            height: size.height,
            startedAt: .now
        )
    }

    private func silentlyRemoveCard(_ id: String) {
        guard activeLesson?.cards.contains(where: { $0.id == id }) == true else { return }
        if editingID == id {
            editingID = nil
            activeCanvasTextView = nil
        }
        selectedIDs.removeAll { $0 == id }
        // A blank text block that's created and immediately discarded (blur-empty) should
        // leave no trace — including in the undo stack. `addCard` already pushed a "before
        // this card existed" snapshot; if nothing else has pushed since, that snapshot is
        // now a phantom entry that would burn a ⌘Z on a no-op instead of undoing whatever
        // the user actually did before it.
        if let top = past.last, top.lessonID == library.activeLessonId, !top.cards.contains(where: { $0.id == id }) {
            past.removeLast()
        }
        patchLesson { $0.cards.removeAll { $0.id == id } }
        persistSoon()
    }

    func insertBlankNote() {
        let size = Format.notePreview
        let origin = freeOrigin(near: CGPoint(x: lastWorld.x, y: lastWorld.y), size: size)
        var card = DemoLibrary.base(VasaID.make("c"), .note, origin.x, origin.y, size.width, size.height, 1)
        card.title = "Note"
        card.body = ""
        addCard(card)
        AppSounds.play(.pasteBlock)
        openNoteEditor(card.id)
        select([card.id])
    }

    /// Nudges a placement point diagonally, cascade-style, until the resulting frame
    /// clears every existing card — so a note/paste dropped at a stale `lastWorld`
    /// (e.g. still sitting over the last-clicked card) doesn't silently stack on top of it.
    func freeOrigin(near point: CGPoint, size: CGSize, step: CGFloat = 24, maxTries: Int = 24) -> CGPoint {
        guard let cards = activeLesson?.cards, !cards.isEmpty else { return point }
        var candidate = point
        for _ in 0..<maxTries {
            let frame = CGRect(x: candidate.x, y: candidate.y, width: size.width, height: size.height)
            if !cards.contains(where: { $0.frame.intersects(frame) }) { return candidate }
            candidate.x += step
            candidate.y += step
        }
        return candidate
    }

    func openContextMenu(at point: CGPoint, in size: CGSize) -> Bool {
        if library.sidebarOpen, point.x < 272 { return false }
        if noteOpenID != nil, point.x > size.width - 400 { return false }
        if askAICardID != nil, point.x > size.width - 360 { return false }
        let cam = activeLesson?.camera ?? Camera(x: 40, y: 36, zoom: 1)
        let world = CGPoint(
            x: (point.x - cam.x) / cam.zoom,
            y: (point.y - cam.y) / cam.zoom
        )
        lastWorld = world
        if let hit = cardAt(world) {
            if !selectedIDs.contains(hit.id) {
                selectedIDs = [hit.id]
                if editingID != hit.id { stopEditingText() }
            }
            menu = MenuAnchor(x: point.x, y: point.y, cardID: hit.id, containerSize: size)
        } else {
            stopEditingText()
            menu = MenuAnchor(x: point.x, y: point.y, cardID: nil, containerSize: size)
        }
        return true
    }

    func turnIntoNote(_ id: String) {
        updateCard(id) { card in
            let body: String = {
                switch card.kind {
                case .text:
                    return CanvasTextEditor.plainText(html: card.html, fallback: card.body)
                case .note:
                    return CanvasTextEditor.plainText(html: card.html, fallback: card.body)
                case .link:
                    return card.title ?? card.url ?? ""
                default:
                    return card.title ?? card.kind.rawValue
                }
            }()
            card.kind = .note
            card.title = "Note"
            card.body = body
            card.html = nil
            card.width = Format.notePreview.width
            card.height = Format.notePreview.height
        }
        openNoteEditor(id)
        menu = nil
    }

    func insertURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let href = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        if let yt = Format.youtubeID(trimmed) {
            let size = CGSize(width: 420, height: 236)
            let origin = placementOrigin(for: size)
            addCard(DemoLibrary.youtube(VasaID.make("c"), origin.x, origin.y, yt, "YouTube"))
            AppSounds.play(.pasteBlock)
            return
        }
        if trimmed.range(of: #"\.(png|jpe?g|gif|webp|heic|avif|bmp)(\?|$)"#, options: .regularExpression) != nil {
            let origin = placementOrigin(for: CGSize(width: 280, height: 200))
            addImageCard(src: trimmed, alt: trimmed, x: origin.x, y: origin.y)
            return
        }
        let lower = trimmed.lowercased()
        let pathExt = URL(string: trimmed)?.pathExtension.lowercased() ?? ""
        if FileKind.audio.contains(pathExt) || FileKind.audio.contains(where: { lower.contains(".\($0)") && !lower.contains(" ") }) {
            let origin = placementOrigin(for: CGSize(width: 196, height: 196))
            var card = DemoLibrary.audio(VasaID.make("c"), origin.x, origin.y, 196, 196, 1, "#34C759", URL(string: trimmed)?.deletingPathExtension().lastPathComponent ?? "Audio", "0:00")
            card.src = trimmed
            addCard(card)
            AppSounds.play(.pasteBlock)
            return
        }
        if FileKind.video.contains(pathExt) {
            let origin = placementOrigin(for: CGSize(width: 320, height: 200))
            var card = DemoLibrary.video(VasaID.make("c"), origin.x, origin.y, 320, 200, 1, trimmed, URL(string: trimmed)?.deletingPathExtension().lastPathComponent ?? "Video")
            card.src = trimmed
            addCard(card)
            AppSounds.play(.pasteBlock)
            return
        }

        // Place rich shell immediately (gray image stub + URL), then fill Open Graph.
        let size = Format.linkRichSize
        let origin = placementOrigin(for: size)
        let id = VasaID.make("c")
        let host = URL(string: href)?.host() ?? href
        let previewTitle = host
        addCard(DemoLibrary.linkRich(id, origin.x, origin.y, previewTitle, host, href, ""))
        AppSounds.play(.pasteBlock)
        Task {
            let meta = await OpenGraph.fetch(trimmed)
            guard card(id) != nil else { return }
            if let image = meta.image, !image.isEmpty {
                updateCard(id) { c in
                    c.title = meta.title
                    c.hostname = meta.host
                    c.url = meta.url
                    c.image = image
                    c.hideVisual = false
                    c.style = .rich
                    if c.color == nil { c.color = "#FF3B30" }
                    c.width = max(c.width, Format.linkRichSize.width)
                    c.height = Format.linkRichSize.height
                }
            } else {
                updateCard(id) { c in
                    c.title = meta.title
                    c.hostname = meta.host
                    c.url = meta.url
                    c.image = nil
                    c.style = .chip
                    if c.color == nil { c.color = "#FFCC00" }
                    c.width = Format.linkChipSize.width
                    c.height = Format.linkChipSize.height
                }
            }
        }
    }

    /// Smart paste: segments a raw multi-link/prose paste into atomic link/text cards, groups
    /// them by topic, and composes each group like a human would — one item (`hero`) anchors the
    /// cluster, name/detail text racks beside it at rule-of-thirds/golden-ratio points,
    /// related-but-separate items sit as accents (see `ComposeEngine`). No frame/plaque is
    /// created — proximity alone signals the group, same as the earlier "no wrapper for a single
    /// element" rule; wrapping a cluster is a deliberate user action (⌘G) afterward. Clusters
    /// line up left to right with a gap wider than the intra-cluster spacing. Everything lands in
    /// one undo step / one `patchLesson` batch, mirroring `createCardsFromChat`. AI clustering
    /// (`smartPasteAIPlan`) is tried first — a plain-line command protocol, not JSON, keeps
    /// per-card cost low enough to plan a large paste in one call — and falls back silently to
    /// the keyword/host heuristic plus a top-to-bottom stack (no AI-assigned roles to compose
    /// from) on any failure.
    func smartPaste(rawText: String, at dropPoint: CGPoint) async {
        guard activeLesson != nil else { return }
        let chunks = SmartPasteParser.segment(rawText)
        guard !chunks.isEmpty else { return }

        var cards: [Card] = []
        var chunkIDs: [String] = []
        var linkFetches: [(id: String, url: String)] = []
        for chunk in chunks {
            let id = VasaID.make("c")
            let card = chunk.materialize(id: id, x: 0, y: 0)
            cards.append(card)
            chunkIDs.append(id)
            if case .url(let url, _) = chunk { linkFetches.append((id, url.absoluteString)) }
        }

        var labels: [String: String] = [:]
        var roles: [String: CardRole] = [:]
        if let plan = await smartPasteAIPlan(chunks: chunks, ids: chunkIDs) {
            for (id, entry) in plan {
                labels[id] = entry.group
                roles[id] = entry.role
            }
        } else {
            let clusters = ClusterEngine.clusterHeuristic(chunks)
            for (clusterIndex, members) in clusters.enumerated() {
                let title = Self.clusterTitle(members.map { chunks[$0] }) ?? "Group \(clusterIndex + 1)"
                for chunkIndex in members { labels[chunkIDs[chunkIndex]] = title }
            }
        }

        var clusterOrder: [String] = []
        var groups: [String: [Card]] = [:]
        for card in cards {
            let label = labels[card.id] ?? "Group"
            if groups[label] == nil { clusterOrder.append(label) }
            groups[label, default: []].append(card)
        }

        let anchor = dropPoint
        let gap = ArrangeEngine.autoGap(frames: cards.map(\.frame))
        // Intra-cluster spacing stays tight (independent of the canvas-wide median `gap`, which
        // can run up to 48pt) — only the gap *between* clusters should read as a visible break.
        let intraGap = min(gap, 16)
        let interClusterGap = gap * 2
        var cursorX = anchor.x
        var placedCards: [Card] = []
        for label in clusterOrder {
            guard var members = groups[label], !members.isEmpty else { continue }
            let clusterAnchor = CGPoint(x: cursorX, y: anchor.y)
            var origins: [String: CGPoint]
            if !roles.isEmpty, members.allSatisfy({ roles[$0.id] != nil }) {
                let composeItems = members.map { (id: $0.id, role: roles[$0.id]!, size: CGSize(width: $0.previewWidth, height: $0.previewHeight)) }
                origins = ComposeEngine.compose(items: composeItems, anchor: clusterAnchor, gap: intraGap)
            } else {
                let packItems = members.map { (id: $0.id, size: CGSize(width: $0.previewWidth, height: $0.previewHeight)) }
                // Small clusters read top-to-bottom (note above the link it refers to) rather
                // than potpack's tallest-first shelf grid, which only kicks in once a column
                // would get unreasonably tall.
                origins = members.count <= 4
                    ? ArrangeEngine.stackLayout(items: packItems, gap: intraGap, anchor: clusterAnchor)
                    : ArrangeEngine.packLayout(items: packItems, gap: intraGap, anchor: clusterAnchor)
            }
            // Compose can stagger captions to the left of its anchor — normalize so the
            // cluster's leftmost edge lands exactly at cursorX, never backing into the previous
            // cluster's plaque.
            if let minX = origins.values.map(\.x).min(), minX != cursorX {
                let dx = cursorX - minX
                origins = origins.mapValues { CGPoint(x: $0.x + dx, y: $0.y) }
            }
            for i in members.indices {
                if let origin = origins[members[i].id] {
                    members[i].x = origin.x
                    members[i].y = origin.y
                }
            }
            // Proximity alone signals the group — no auto-created plaque. A well-composed
            // cluster reads as one unit from spacing; wrapping it is a deliberate user action
            // (⌘G) afterward, not something arrange should decide for them.
            let clusterBounds = members.reduce(CGRect(origin: clusterAnchor, size: .zero)) { $0.union($1.frame) }
            placedCards.append(contentsOf: members)
            cursorX = clusterBounds.maxX + interClusterGap
        }
        guard !placedCards.isEmpty else { return }

        pushUndo()
        patchLesson { lesson in
            var maxZ = lesson.cards.map(\.z).max() ?? 0
            for var card in placedCards {
                maxZ += 1
                card.z = maxZ
                lesson.cards.append(card)
            }
        }
        selectedIDs = placedCards.map(\.id)
        persistSoon()
        AppSounds.play(.pasteBlock)

        for (id, url) in linkFetches {
            Task {
                let meta = await OpenGraph.fetch(url)
                guard card(id) != nil else { return }
                if let image = meta.image, !image.isEmpty {
                    updateCard(id) { c in
                        c.title = meta.title
                        c.hostname = meta.host
                        c.url = meta.url
                        c.image = image
                        c.hideVisual = false
                        c.style = .rich
                        if c.color == nil { c.color = "#FF3B30" }
                        c.width = max(c.width, Format.linkRichSize.width)
                        c.height = Format.linkRichSize.height
                    }
                } else if !meta.title.isEmpty || !meta.host.isEmpty {
                    updateCard(id) { c in
                        if !meta.title.isEmpty { c.title = meta.title }
                        if !meta.host.isEmpty { c.hostname = meta.host }
                    }
                }
            }
        }
    }

    /// AI clustering + composition pass for `smartPaste` — silent, returns `nil` (never surfaces
    /// `aiArrangeError`) on missing token, network, or parse failure so the caller falls back to
    /// the heuristic. Uses a plain-line command protocol instead of JSON: `id|group|role`, one
    /// per item, no braces/quotes/keys to repeat per card. That keeps per-item overhead to a
    /// handful of tokens instead of a JSON object's worth, so the same context budget covers a
    /// much larger paste — the model reads and writes commands, not structured records.
    private func smartPasteAIPlan(chunks: [PasteChunk], ids: [String]) async -> [String: (group: String, role: CardRole)]? {
        let config = activeAIConfig
        let apiKey = ChatKeychain.load(config.id)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let itemLines = zip(ids, chunks).map { id, chunk -> String in
            let kind: String = { if case .url = chunk { return "link" } else { return "text" } }()
            let text = chunk.summaryText.prefix(160).replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
            return "\(id)|\(kind)|\(text)"
        }.joined(separator: "\n")
        let prompt = """
        Cluster these pasted items by topic, then give each one a compositional role.

        Input, one item per line as `id|kind|text`:
        \(itemLines)

        Respond with ONLY plain lines, one per item, no prose, no code fences, no JSON — exactly:
        id|group|role

        Rules:
        - group: a short cluster label (1-3 words) shared by every item on the same topic.
        - role: exactly one of hero, caption, meta, accent.
          hero = the one item in its group that most anchors the topic (a link, an image, the main subject).
          caption = short text naming/describing the hero (e.g. a title, a name).
          meta = secondary small text (numbers, handles, tags).
          accent = a related but separate item (another link, audio) that isn't the hero.
          Every group needs exactly one hero; a group with only one item is that item's own hero.
        - Every input id must appear exactly once, in any order.
        """
        let handler = APIServiceFactory.handler(for: config)
        let settingsGen = GenerationSettings(model: config.defaultModel)

        var accumulated = ""
        do {
            let stream = handler.sendMessageStream(
                history: [RequestMessage(role: .user, content: prompt)],
                systemPrompt: "You are a silent layout-planning service. Output only the requested plain-line commands, nothing else.",
                settings: settingsGen,
                apiKey: apiKey
            )
            for try await delta in stream {
                if let text = delta.text { accumulated += text }
            }
        } catch {
            return nil
        }

        // Partial coverage is fine — `smartPaste` falls back to the keyword heuristic per
        // cluster for any id the model dropped, rather than discarding an otherwise-good plan.
        let plan = Self.parsePlanLines(accumulated, validIDs: Set(ids))
        return plan.isEmpty ? nil : plan
    }

    /// Top-left for a new card: last click (if in view), else camera center; avoid overlaps; soft-snap.
    func placementOrigin(for size: CGSize, preferred: CGPoint? = nil) -> CGPoint {
        let click = preferred ?? lastWorld
        let cam = activeLesson?.camera
        let zoom = max(cam?.zoom ?? 1, 0.01)
        let cx = cam?.x ?? 0
        let cy = cam?.y ?? 0
        let view = CGRect(
            x: (0 - cx) / zoom,
            y: (0 - cy) / zoom,
            width: max(1, viewport.width) / zoom,
            height: max(1, viewport.height) / zoom
        )
        let anchor: CGPoint = view.insetBy(dx: 40 / zoom, dy: 40 / zoom).contains(click)
            ? click
            : CGPoint(x: view.midX, y: view.midY)
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        origin = avoidCardOverlap(origin: origin, size: size)
        if settings.snapping, let lesson = activeLesson, !lesson.cards.isEmpty {
            var probe = DemoLibrary.base("place", .link, origin.x, origin.y, size.width, size.height, 0)
            probe.width = size.width
            probe.height = size.height
            let result = Self.alignmentSnap(
                moving: [probe],
                against: lesson.cards,
                threshold: Self.snapThreshold(zoom: zoom)
            )
            origin.x += result.dx
            origin.y += result.dy
        }
        return origin
    }

    private func avoidCardOverlap(origin: CGPoint, size: CGSize) -> CGPoint {
        guard let cards = activeLesson?.cards, !cards.isEmpty else { return origin }
        let gap = 28.0
        var o = origin
        for _ in 0..<14 {
            let frame = CGRect(x: o.x, y: o.y, width: size.width, height: size.height)
            guard let hit = cards.first(where: {
                $0.frame.insetBy(dx: -gap * 0.35, dy: -gap * 0.35).intersects(frame)
            }) else {
                return o
            }
            let toRight = CGPoint(x: hit.frame.maxX + gap, y: hit.frame.minY)
            let rightFrame = CGRect(x: toRight.x, y: toRight.y, width: size.width, height: size.height)
            if !cards.contains(where: { $0.frame.insetBy(dx: -gap * 0.35, dy: -gap * 0.35).intersects(rightFrame) }) {
                return toRight
            }
            o = CGPoint(x: hit.frame.minX, y: hit.frame.maxY + gap)
        }
        return o
    }

    /// Show / hide Open Graph image on a link card; resizes to chip vs rich frame.
    func toggleLinkVisual(_ id: String) {
        guard let card = card(id), card.kind == .link, card.image != nil else { return }
        updateCard(id) { c in
            let hide = !(c.hideVisual ?? false)
            c.hideVisual = hide
            if c.color == nil { c.color = "#FF3B30" }
            if hide {
                c.style = .chip
                c.height = Format.linkChipSize.height
                c.width = max(Format.linkChipSize.width, min(c.width, Format.linkRichSize.width))
            } else {
                c.style = .rich
                c.width = max(c.width, Format.linkRichSize.width)
                c.height = Format.linkRichSize.height
            }
        }
    }

    /// Re-fetch Open Graph for a chip link that has no preview image yet.
    func fetchLinkVisual(_ id: String) {
        guard let card = card(id), card.kind == .link, let url = card.url, !url.isEmpty else { return }
        Task {
            let meta = await OpenGraph.fetch(url)
            guard let image = meta.image, !image.isEmpty else { return }
            updateCard(id) { c in
                c.image = image
                c.hideVisual = false
                c.style = .rich
                c.title = meta.title
                c.hostname = meta.host
                if c.color == nil { c.color = "#FF3B30" }
                c.width = max(c.width, Format.linkRichSize.width)
                c.height = Format.linkRichSize.height
            }
            AppSounds.play(.button)
        }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        drop(urls: panel.urls, at: lastWorld)
    }

    func drop(urls: [URL], at point: CGPoint) {
        for (i, url) in urls.enumerated() {
            let ox = point.x + Double(i) * 28
            let oy = point.y + Double(i) * 28
            importURL(url, x: ox, y: oy)
        }
    }

    func importURL(_ url: URL, x: Double, y: Double) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = FileKind.ext(url.path)

        if isDir.boolValue {
            addCard(DemoLibrary.folder(VasaID.make("c"), x, y, url.lastPathComponent, url.path))
            AppSounds.play(.pasteBlock)
            return
        }
        if ext == "txt", let body = try? String(contentsOf: url, encoding: .utf8) {
            var card = DemoLibrary.note(VasaID.make("c"), x, y, body)
            card.title = url.deletingPathExtension().lastPathComponent
            addCard(card)
            AppSounds.play(.pasteBlock)
            openNoteEditor(card.id)
            return
        }
        if FileKind.images.contains(ext) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let dest = importIntoActiveLesson(url) else { return }
            addImageCard(src: dest.absoluteString, alt: url.lastPathComponent, x: x, y: y, fileURL: dest)
            return
        }
        if FileKind.audio.contains(ext) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let dest = importIntoActiveLesson(url) else { return }
            Task {
                var card = DemoLibrary.audio(VasaID.make("c"), x, y, 196, 196, 1, "#34C759", url.deletingPathExtension().lastPathComponent, "0:00")
                card.src = dest.absoluteString
                if let dur = try? await AVURLAsset(url: dest).load(.duration), dur.seconds.isFinite {
                    card.duration = Format.duration(dur.seconds)
                }
                addCard(card)
                AppSounds.play(.pasteBlock)
            }
            return
        }
        if FileKind.video.contains(ext) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let dest = importIntoActiveLesson(url) else { return }
            let title = url.deletingPathExtension().lastPathComponent
            Task {
                // Card defaulted to a fixed 320×200 regardless of the source's real
                // aspect — a square (or portrait) clip then rendered inside a wide
                // rectangle, aspect-filled and cropped down to a sliver. Size the
                // card from the video's actual (rotation-corrected) dimensions instead.
                var pixel = CGSize(width: 320, height: 200)
                if let track = try? await AVURLAsset(url: dest).loadTracks(withMediaType: .video).first,
                   let natural = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform)
                {
                    let oriented = natural.applying(transform)
                    let w = abs(oriented.width), h = abs(oriented.height)
                    if w > 0, h > 0 { pixel = CGSize(width: w, height: h) }
                }
                let fitted = ImageMedia.cardSize(for: pixel, maxSide: 420)
                var card = DemoLibrary.video(VasaID.make("c"), x, y, fitted.width, fitted.height, 1, "", title)
                card.src = dest.absoluteString
                if let poster = await Playback.generatePoster(for: dest) {
                    card.poster = poster.absoluteString
                }
                if let dur = try? await AVURLAsset(url: dest).load(.duration), dur.seconds.isFinite, dur.seconds > 0 {
                    card.duration = Format.duration(dur.seconds)
                }
                addCard(card)
                AppSounds.play(.pasteBlock)
            }
            return
        }
        // PDF, docs, apps, archives, etc. — file shortcut block.
        var card = DemoLibrary.shortcut(VasaID.make("c"), x, y, url.lastPathComponent, url.path)
        card.missing = false
        addCard(card)
        AppSounds.play(.pasteBlock)
    }

    func pasteFromPasteboard(at point: CGPoint) async {
        let pb = NSPasteboard.general

        // File URLs first: a Finder copy of an image also satisfies NSImage.self, but
        // reading it as a raw bitmap loses EXIF orientation (see addImageCard(fromRawImage:)).
        // Importing the file directly preserves orientation via ImageMedia.orientedSize.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for (i, url) in urls.enumerated() {
                let ox = point.x + Double(i % 3) * 28
                let oy = point.y + Double(i) * 28
                if url.isFileURL {
                    importURL(url, x: ox, y: oy)
                } else {
                    lastWorld = CGPoint(x: ox, y: oy)
                    insertURL(url.absoluteString)
                }
            }
            return
        }

        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            for (i, image) in images.enumerated() {
                addImageCard(
                    fromRawImage: image,
                    at: CGPoint(x: point.x + Double(i % 3) * 28, y: point.y + Double(i) * 28),
                    alt: "Pasted image"
                )
            }
            return
        }

        if let html = pb.string(forType: .html)?.trimmingCharacters(in: .whitespacesAndNewlines),
           html.contains("<"), !html.isEmpty
        {
            insertRichTextCard(html: html, plain: pb.string(forType: .string), at: point)
            return
        }
        if let rtf = pb.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
           attributed.length > 0
        {
            let html = CanvasTextEditor.html(from: attributed)
            insertRichTextCard(html: html, plain: attributed.string, at: point)
            return
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // Absolute file path or file:// URL pasted as text.
            if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
                importURL(url, x: point.x, y: point.y)
                return
            }
            if text.hasPrefix("/"), !text.contains("\n"), FileManager.default.fileExists(atPath: text) {
                importURL(URL(fileURLWithPath: text), x: point.x, y: point.y)
                return
            }
            if text.hasPrefix("http"), !text.contains(" ") {
                lastWorld = point
                insertURL(text)
            } else if Self.isMixedProseAndLinks(text) {
                lastWorld = point
                await smartPaste(rawText: text, at: point)
            } else {
                insertRichTextCard(html: nil, plain: String(text.prefix(Format.textLimit)), at: point)
            }
            return
        }

        // Last resort: any remaining pasteboard string type (UTF-16, etc.).
        if let raw = pb.string(forType: .string) ?? pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            insertRichTextCard(html: nil, plain: String(raw.prefix(Format.textLimit)), at: point)
        }
    }

    func insertRichTextCard(html: String?, plain: String?, at point: CGPoint) {
        let body = plain ?? CanvasTextEditor.plainText(html: html, fallback: nil)
        let clipped = String(body.prefix(Format.textLimit))
        var card = DemoLibrary.text(VasaID.make("c"), point.x, point.y, 360, 80, 1, "", 16)
        card.body = clipped
        if let html, html.contains("<") {
            card.html = CanvasTextEditor.htmlFragment(html)
        } else if clipped.range(of: #"https?://\S+"#, options: .regularExpression) != nil {
            card.html = linkifyHTML(clipped)
        } else {
            let escaped = clipped
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
            card.html = escaped
        }
        // Prefer a readable wrap width for long paste; short text hugs content after first layout.
        let wrapCap = Format.textWrapWidth
        let wrap = clipped.count > 48 ? wrapCap : min(wrapCap, max(120, Double(clipped.count) * 8 + 24))
        let lines = max(1, Int(ceil(Double(clipped.count) / max(24, wrap / 8))))
        card.width = wrap
        card.height = max(28, Double(lines) * 22 + 8)
        addCard(card)
        AppSounds.play(.pasteBlock)
        editingID = card.id
        select([card.id])
        let waveID = (textWave?.id ?? 0) + 1
        textWave = TextWaveEvent(
            id: waveID,
            x: point.x + card.width / 2,
            y: point.y + card.height / 2,
            width: card.width,
            height: card.height,
            startedAt: .now
        )
    }

    private func linkifyHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escaped.replacingOccurrences(of: "\n", with: "<br>")
        }
        let ns = escaped as NSString
        let matches = detector.matches(in: escaped, options: [], range: NSRange(location: 0, length: ns.length))
        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let raw = ns.substring(with: match.range)
            let href = match.url?.absoluteString ?? raw
            result += "<a href=\"\(href)\">\(raw)</a>"
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return (result.isEmpty ? escaped : result).replacingOccurrences(of: "\n", with: "<br>")
    }

    func openExternal(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Writes a raw in-memory image (pasteboard or drag payload with no
    /// resolvable file:// URL yet — e.g. a screenshot still mid-write, or a
    /// promised/in-memory bitmap drag) into the lesson's media folder and
    /// inserts it as an image card. Shared by paste (Cmd+V) and canvas drop.
    func addImageCard(fromRawImage image: NSImage, at point: CGPoint, alt: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return }
        let dest: URL = {
            if let lesson = activeLesson {
                let media = Persistence.mediaDirectory(for: lesson, subjects: library.subjects)
                return media.appendingPathComponent("\(VasaID.make("m")).jpg")
            }
            return Persistence.projectsRoot.appendingPathComponent("\(VasaID.make("m")).jpg")
        }()
        try? data.write(to: dest)
        addImageCard(src: dest.absoluteString, alt: alt, x: point.x, y: point.y, image: image)
    }

    func addImageCard(src: String, alt: String, x: Double, y: Double, fileURL: URL? = nil, image: NSImage? = nil) {
        let pixel: CGSize
        if let image, image.size.width > 0, image.size.height > 0 {
            pixel = image.size
        } else if let fileURL, let size = ImageMedia.orientedSize(at: fileURL) {
            pixel = size
        } else if let url = ImageMedia.fileURL(from: src), let size = ImageMedia.orientedSize(at: url) {
            pixel = size
        } else {
            pixel = CGSize(width: 360, height: 240)
        }
        let fitted = ImageMedia.cardSize(for: pixel)
        // Callers pass the pointer/drop point — center the card under it rather
        // than anchoring its top-left corner there.
        let origin = CGPoint(x: x - fitted.width / 2, y: y - fitted.height / 2)
        addCard(DemoLibrary.image(VasaID.make("c"), origin.x, origin.y, fitted.width, fitted.height, 1, src, alt))
        AppSounds.play(.pasteBlock)
    }

    func fitImageCard(_ id: String) async {
        guard let card = card(id), card.kind == .image, let src = card.src else { return }
        guard let url = ImageMedia.fileURL(from: src) else { return }
        let pixel = await Task.detached { ImageMedia.orientedSize(at: url) }.value
        guard let pixel, pixel.width > 0, pixel.height > 0 else { return }
        let imageAspect = pixel.width / pixel.height
        let cardAspect = card.width / max(card.height, 1)
        guard abs(imageAspect - cardAspect) > 0.04 else { return }
        let fitted = ImageMedia.cardSize(for: pixel, maxSide: max(card.width, card.height, 240))
        updateCard(id) {
            $0.width = fitted.width
            $0.height = fitted.height
        }
    }

    func revealInFinder() {
        guard let lesson = activeLesson else {
            NSWorkspace.shared.activateFileViewerSelecting([Persistence.projectsRoot])
            return
        }
        let board = Persistence.boardFile(for: lesson, subjects: library.subjects)
        if FileManager.default.fileExists(atPath: board.path) {
            NSWorkspace.shared.activateFileViewerSelecting([board])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Persistence.lessonDirectory(lesson, subjects: library.subjects)])
        }
    }

    private func importIntoActiveLesson(_ url: URL) -> URL? {
        guard let lesson = activeLesson else { return nil }
        return Persistence.importFile(from: url, lesson: lesson, subjects: library.subjects)
    }

    /// Opens Google Lens in the default browser (new tab).
    /// The image is submitted **by the browser** via a loopback bridge so the
    /// session cookies match — app-side upload caused "Expired visual search".
    func openLens(_ src: String?) {
        guard let src, !src.isEmpty else {
            openBrowserTab(LensUpload.lensHome)
            return
        }
        // Stage the image on the clipboard up front, so every failure path — a
        // changed Lens endpoint, a dead bridge — degrades to "Lens is open, press ⌘V"
        // instead of a dead end. Skipped for a remote image, which needs no bridge.
        if LensUpload.directUploadURL(for: src) == nil { copyImageToPasteboard(src) }
        Task { @MainActor in
            do {
                try await LensUpload.openInBrowser(src: src)
            } catch {
                openBrowserTab(LensUpload.lensHome)
            }
        }
    }

    private func copyImageToPasteboard(_ src: String) {
        guard let fileURL = ImageMedia.fileURL(from: src),
              let image = NSImage(contentsOf: fileURL)
        else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func openBrowserTab(_ url: URL?) {
        guard let url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config)
    }

    /// Opens the AI chat panel directly (⌘J), regardless of selection — unlike `askAbout(_:)`,
    /// which requires a text/note card to seed sources from.
    func openAIChat() {
        closeNoteEditor()
        lightbox = nil
        audioDetailID = nil
        paletteOpen = false
        menu = nil
        askAICardID = selectedTextCardIDs().first ?? "chat"
    }

    func askAbout(_ id: String?) {
        if let id, let card = card(id), card.kind == .image, let src = card.src {
            openLens(src)
            menu = nil
            return
        }
        // Ask AI sources: canvas text + notes.
        let textIDs = selectedTextCardIDs(preferring: id)
        guard !textIDs.isEmpty else {
            menu = nil
            return
        }
        if selectedIDs.isEmpty || Set(selectedIDs).intersection(textIDs).isEmpty {
            selectedIDs = textIDs
        }
        // Note editor sits above Ask in the overlay stack — close it first.
        closeNoteEditor()
        lightbox = nil
        audioDetailID = nil
        paletteOpen = false
        menu = nil
        askAICardID = textIDs.first
    }

    /// Selected `.text` / `.note` cards used as Ask AI sources.
    func selectedTextCardIDs(preferring id: String? = nil) -> [String] {
        func isAskSource(_ kind: CardKind?) -> Bool {
            kind == .text || kind == .note
        }
        var ids = selectedIDs.filter { isAskSource(card($0)?.kind) }
        if ids.isEmpty, let id, isAskSource(card(id)?.kind) {
            ids = [id]
        }
        // If a note is open but not in selection, still allow Ask from its toolbar.
        if ids.isEmpty, let open = noteOpenID, isAskSource(card(open)?.kind) {
            ids = [open]
        }
        return ids
    }

    func textAskSources(preferring id: String? = nil) -> [TextAskSource] {
        selectedTextCardIDs(preferring: id).compactMap { cid in
            guard let card = card(cid) else { return nil }
            let plain = CanvasTextEditor.plainText(html: card.html, fallback: card.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return nil }
            let links = Self.extractURLs(from: plain)
            return TextAskSource(id: cid, snippet: plain, links: links, plain: plain)
        }
    }

    /// Place AI answer as a new note at `lastWorld` (does not edit source text).
    /// Accepts HTML from Ask AI so bold/lists/links land already formatted.
    @discardableResult
    func placeAINote(body: String, open: Bool = true) -> String {
        let raw = VasaAIPrompt.sanitizeNoteHTML(body)
        guard !raw.isEmpty else { return "" }
        var card = DemoLibrary.note(VasaID.make("c"), lastWorld.x, lastWorld.y, "")
        card.title = "Note"
        card.color = nil
        card.fontSize = nil
        if VasaAIPrompt.looksLikeHTML(raw) {
            card.html = raw
            card.body = CanvasTextEditor.plainText(html: raw, fallback: raw)
        } else {
            card.body = raw
            card.html = nil
        }
        addCard(card)
        AppSounds.play(.pasteBlock)
        askAICardID = nil
        if open { openNoteEditor(card.id) }
        return card.id
    }

    /// Creates note/text/link cards on the active board from a decoded `<<CARDS:>>` directive
    /// (see `AppModel.extractCardsDirective`), one `pushUndo()` + one batched mutation for the
    /// whole set — mirrors `addCard`'s save pipeline but without a per-card undo step. Skips any
    /// spec with an unrecognized `kind` or missing required field rather than failing the whole
    /// batch. Returns the number of cards actually created, for a success/failure sound cue.
    @discardableResult
    /// Builds cards from a `<<CARDS:>>` directive and lays them out clustered by `spec.group`,
    /// mirroring exactly how `performArrangeByGroups`/`performArrangeByPlan` cluster and pack
    /// existing cards: each cluster with 2+ members is potpack-packed via `ArrangeEngine`, then
    /// wrapped in a group plaque (same padding math as manual ⌘G, via `groupPlaqueFrame`);
    /// clusters and standalone singleton cards are then placed left-to-right with a cluster gap,
    /// anchored near `lastWorld`. Everything lands in one undo step / one `patchLesson` batch.
    func createCardsFromChat(_ specs: [AIChatCardSpec]) -> Int {
        guard activeLesson != nil, !specs.isEmpty else { return 0 }

        // Build cards at the origin first (placed at 0,0); real positions come from the
        // clustering pass below, same two-phase approach as the arrange-by-* helpers.
        var newCards: [Card] = []
        var groupOf: [String: String] = [:]
        var linkFetches: [(id: String, url: String)] = []
        for spec in specs {
            let id = VasaID.make("c")
            switch spec.kind {
            case "note":
                var card = DemoLibrary.note(id, 0, 0, spec.body ?? "")
                if let title = spec.title, !title.isEmpty { card.title = title }
                if let color = spec.color { card.color = color }
                newCards.append(card)
            case "text":
                guard let body = spec.body, !body.isEmpty else { continue }
                let fontSize: Double = 15
                let size = Self.measureTextCardSize(body, fontSize: fontSize)
                var card = DemoLibrary.text(id, 0, 0, size.width, size.height, 8, body, fontSize)
                if let color = spec.color { card.color = color }
                newCards.append(card)
            case "link":
                guard let url = spec.url, !url.isEmpty else { continue }
                let href = url.hasPrefix("http") ? url : "https://\(url)"
                let host = URL(string: href)?.host ?? href
                let color = spec.color ?? Theme.itemColors[newCards.count % Theme.itemColors.count]
                // Title/hostname start as a placeholder (host) — the AI shouldn't invent a page
                // title, the app fetches the real one via Open Graph right after insertion (see
                // the fetch loop below), same as a normal pasted-link card.
                let card = DemoLibrary.linkChip(id, 0, 0, host, host, href, color)
                newCards.append(card)
                linkFetches.append((id, href))
            case "youtube":
                guard let url = spec.url, !url.isEmpty, let videoId = Format.youtubeID(url) else { continue }
                let card = DemoLibrary.youtube(id, 0, 0, videoId, spec.title ?? "YouTube")
                newCards.append(card)
            default:
                continue
            }
            if let group = spec.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                groupOf[id] = group
            }
        }
        guard !newCards.isEmpty else { return 0 }

        // Cluster by group label, preserving first-appearance order for deterministic layout.
        var clusterOrder: [String] = []
        var clusters: [String: [Card]] = [:]
        var standalone: [Card] = []
        for card in newCards {
            guard let label = groupOf[card.id] else {
                standalone.append(card)
                continue
            }
            if clusters[label] == nil {
                clusterOrder.append(label)
                clusters[label] = []
            }
            clusters[label, default: []].append(card)
        }
        // A 2-card "cluster" reads as visual clutter, not an actual composition (a plaque
        // wrapping just a label + one link, say) — only wrap groups of 3+ in a plaque; smaller
        // groups fall back to standalone cards.
        for label in clusterOrder where (clusters[label]?.count ?? 0) < 3 {
            standalone.append(contentsOf: clusters[label] ?? [])
            clusters[label] = nil
        }
        clusterOrder.removeAll { clusters[$0] == nil }

        let anchor = lastWorld
        let gap = ArrangeEngine.autoGap(frames: newCards.map(\.frame))
        let clusterGap = gap * 2
        var cursorX = anchor.x

        var placedCards: [Card] = []
        var plaques: [Card] = []

        for label in clusterOrder {
            guard let members = clusters[label], !members.isEmpty else { continue }
            let clusterAnchor = CGPoint(x: cursorX, y: anchor.y)
            let packItems = members.map { (id: $0.id, size: CGSize(width: $0.previewWidth, height: $0.previewHeight)) }
            let origins = ArrangeEngine.packLayout(items: packItems, gap: gap, anchor: clusterAnchor)
            var packedMembers: [Card] = []
            for var card in members {
                if let origin = origins[card.id] {
                    card.x = origin.x
                    card.y = origin.y
                }
                packedMembers.append(card)
            }
            let frame = groupPlaqueFrame(for: packedMembers)
            let plaqueId = VasaID.make("c")
            let plaque = DemoLibrary.group(plaqueId, frame.minX, frame.minY, frame.width, frame.height, title: label)
            for i in packedMembers.indices { packedMembers[i].groupId = plaqueId }
            plaques.append(plaque)
            placedCards.append(contentsOf: packedMembers)
            cursorX = frame.maxX + clusterGap
        }

        for var card in standalone {
            card.x = cursorX
            card.y = anchor.y
            placedCards.append(card)
            cursorX += card.previewWidth + clusterGap
        }

        pushUndo()
        patchLesson { lesson in
            var maxZ = lesson.cards.map(\.z).max() ?? 0
            for var card in placedCards {
                maxZ += 1
                card.z = maxZ
                lesson.cards.append(card)
            }
            for var plaque in plaques {
                let memberZ = lesson.cards.filter { $0.groupId == plaque.id }.map(\.z).min() ?? maxZ
                plaque.z = memberZ - 1
                lesson.cards.append(plaque)
            }
        }
        selectedIDs = placedCards.map(\.id) + plaques.map(\.id)
        persistSoon()

        // Fill in the real page title/hostname for each AI-created link card — the model only
        // ever gets a host-name placeholder (see the "link" case above), matching how a normal
        // pasted-URL card (`insertURL`) resolves its title from Open Graph, not from AI guesswork.
        for (id, url) in linkFetches {
            Task {
                let meta = await OpenGraph.fetch(url)
                guard card(id) != nil else { return }
                updateCard(id) { c in
                    if !meta.title.isEmpty { c.title = meta.title }
                    if !meta.host.isEmpty { c.hostname = meta.host }
                }
            }
        }
        return placedCards.count
    }

    private static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            match.url?.absoluteString
        }
    }

    /// Picks a plaque title for a heuristic cluster: the most frequent shared keyword (4+ chars)
    /// across the cluster's chunks, capitalized — falls back to a link's hostname, then `nil`
    /// (caller supplies a "Group N" default) when nothing stands out.
    private static func clusterTitle(_ members: [PasteChunk]) -> String? {
        var counts: [String: Int] = [:]
        for chunk in members {
            let words = chunk.summaryText.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count >= 4 }
            for word in Set(words) { counts[word, default: 0] += 1 }
        }
        if let top = counts.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value })?.key {
            return top.prefix(1).uppercased() + top.dropFirst()
        }
        for case .url(let url, _) in members {
            if let host = url.host() { return host }
        }
        return nil
    }

    /// True when a plain-text paste is prose interleaved with links (the smart-paste case) —
    /// 2+ links, or 1 link plus meaningful surrounding prose. A bare URL or link-free prose
    /// keeps the existing `insertURL`/`insertRichTextCard` fast paths.
    private static func isMixedProseAndLinks(_ text: String) -> Bool {
        let urls = extractURLs(from: text)
        guard !urls.isEmpty else { return false }
        if urls.count >= 2 { return true }
        let urlLength = urls.reduce(0) { $0 + $1.count }
        let proseLength = text.trimmingCharacters(in: .whitespacesAndNewlines).count - urlLength
        return proseLength >= 24
    }

    func dismissOverlays() {
        menu = nil
        boardMenuID = nil
        paletteOpen = false
        askAICardID = nil
        closeNoteEditor()
        lightbox = nil
        audioDetailID = nil
        linkPrompt = false
        settingsOpen = false
        providerSettingsOpen = false
        aiArrangePromptOpen = false
        navigatorOpen = false
        editingGroupID = nil
        clearSnapGuides()
        if !handleTextToolEscape() {
            stopEditingText()
        }
        if tool == .text { tool = .select }
    }
}

enum OpenGraph {
    struct Meta {
        var title: String
        var host: String
        var url: String
        var image: String?
    }

    static func fetch(_ raw: String) async -> Meta {
        let urlString = raw.hasPrefix("http") ? raw : "https://\(raw)"
        guard let url = URL(string: urlString) else {
            return Meta(title: raw, host: raw, url: urlString, image: nil)
        }
        let host = url.host() ?? urlString
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            // Many sites (Pinterest, etc.) serve empty/blocked HTML to the default URLSession UA.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            func meta(_ key: String) -> String? {
                let patterns = [
                    "property=[\"']\(key)[\"'][^>]*content=[\"']([^\"']+)[\"']",
                    "content=[\"']([^\"']+)[\"'][^>]*property=[\"']\(key)[\"']",
                    "name=[\"']\(key)[\"'][^>]*content=[\"']([^\"']+)[\"']",
                    "content=[\"']([^\"']+)[\"'][^>]*name=[\"']\(key)[\"']",
                ]
                for p in patterns {
                    if let r = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                       let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       let range = Range(m.range(at: 1), in: html)
                    {
                        let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty { return value }
                    }
                }
                return nil
            }
            func htmlTitle() -> String? {
                guard let r = try? NSRegularExpression(
                    pattern: "<title[^>]*>([^<]+)</title>",
                    options: .caseInsensitive
                ),
                let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                let range = Range(m.range(at: 1), in: html)
                else { return nil }
                let raw = String(html[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            }
            func linkRelImage() -> String? {
                let patterns = [
                    "<link[^>]+rel=[\"']image_src[\"'][^>]+href=[\"']([^\"']+)[\"']",
                    "<link[^>]+href=[\"']([^\"']+)[\"'][^>]+rel=[\"']image_src[\"']",
                ]
                for p in patterns {
                    if let r = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                       let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       let range = Range(m.range(at: 1), in: html)
                    {
                        return String(html[range])
                    }
                }
                return nil
            }
            let title = decodeHTMLEntities(meta("og:title") ?? meta("twitter:title") ?? htmlTitle() ?? host)
            let rawImage = meta("og:image")
                ?? meta("og:image:secure_url")
                ?? meta("twitter:image")
                ?? meta("twitter:image:src")
                ?? linkRelImage()
            let image = absoluteImageURL(rawImage, base: url)
            return Meta(title: title, host: host, url: urlString, image: image)
        } catch {
            return Meta(title: host, host: host, url: urlString, image: nil)
        }
    }

    /// Decode HTML entities (`&amp;`, `&mdash;`, `&#8217;`, …) that `<title>` and
    /// Open Graph tags frequently carry verbatim in the page source.
    private static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        guard let data = string.data(using: .utf8),
              let decoded = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              )
        else { return string }
        let value = decoded.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? string : value
    }

    private static func absoluteImageURL(_ raw: String?, base: URL) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        if value.hasPrefix("//") {
            value = (base.scheme ?? "https") + ":" + value
        }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute.absoluteString
        }
        return URL(string: value, relativeTo: base)?.absoluteString
    }
}

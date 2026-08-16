import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {
    var library: Library
    var selectedIDs: [String] = []
    var tool: Tool = .select
    var spaceDown = false
    var menu: MenuAnchor?
    var askAICardID: String?
    var paletteOpen = false
    var lightbox: LightboxItem?
    var playingID: String?
    var playbackPaused = false
    var audioDetailID: String?
    var noteOpenID: String?
    var lastWorld = CGPoint(x: 120, y: 120)
    var cameraEase = false
    var editingID: String?
    /// Keeps the live canvas text view while the format bar steals first responder.
    @ObservationIgnored weak var activeCanvasTextView: GrowingTextView?
    var linkPrompt = false
    var renameLessonID: String?
    var settingsOpen = false
    var boardMenuID: String?
    var boardMenuY: CGFloat = 56
    var boardWave = 0
    var textWave: TextWaveEvent?
    var viewport = CGSize(width: 1440, height: 900)
    var settings = AppSettings.load() { didSet { settings.save() } }

    private var past: [(lessonID: String, cards: [Card])] = []
    private var future: [(lessonID: String, cards: [Card])] = []
    private var saveTask: Task<Void, Never>?
    private var dirtyLessonIDs: Set<String> = []
    private var indexDirty = false
    private var clipboard: [Card] = []

    init() {
        if let saved = Persistence.load(), saved.rev == Format.libraryRev, !saved.lessons.isEmpty {
            library = saved
        } else {
            library = DemoLibrary.make()
            markAllLessonsDirty()
            persistSoon(prune: true)
        }
        Playback.shared.onEnded { [weak self] in
            self?.playingID = nil
            self?.playbackPaused = false
            Playback.shared.currentSeconds = 0
        }
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
        saveTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let files = batch.files
            let keeping = batch.pruneKeeping
            await Task.detached(priority: .utility) {
                NexusDisk.write(files)
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
        let files = batch.files
        Task(priority: .utility) {
            await Task.detached(priority: .utility) {
                NexusDisk.write(files)
            }.value
        }
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

    func toggleSidebar() {
        library.sidebarOpen.toggle()
        if !library.sidebarOpen { settingsOpen = false }
        indexDirty = true
        persistSoon()
    }

    func openLesson(_ id: String) {
        Playback.shared.stop()
        playingID = nil
        playbackPaused = false
        audioDetailID = nil
        selectedIDs = []
        menu = nil
        boardMenuID = nil
        library.activeLessonId = id
        if !library.openLessonIds.contains(id) {
            library.openLessonIds.append(id)
        }
        indexDirty = true
        persistSoon()
    }

    func addLesson() {
        guard let subject = library.subjects.first else { return }
        var lesson = Lesson(
            id: NexusID.make("les"),
            subjectId: subject.id,
            title: "Untitled Project",
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
        openLesson(lesson.id)
        boardWave += 1
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
        let newID = NexusID.make("les")
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
    }

    func select(_ ids: [String], additive: Bool = false) {
        let next: [String] = {
            if additive { return Array(Set(selectedIDs + ids)) }
            return ids
        }()
        if next == selectedIDs, menu == nil, boardMenuID == nil,
           editingID == nil || ids.contains(where: { $0 == editingID }) {
            return
        }
        selectedIDs = next
        if editingID != nil, !ids.contains(where: { $0 == editingID }) {
            editingID = nil
            activeCanvasTextView = nil
        }
        if let open = noteOpenID, !ids.contains(open) {
            if let first = ids.first, !additive, card(first)?.kind == .note {
                noteOpenID = first
            } else {
                closeNoteEditor()
            }
        }
        menu = nil
        boardMenuID = nil
    }

    func clearSelection() {
        selectedIDs = []
        editingID = nil
        activeCanvasTextView = nil
        menu = nil
        boardMenuID = nil
    }

    func closeNoteEditor() {
        guard noteOpenID != nil else { return }
        noteOpenID = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
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
        }
        selectedIDs = [card.id]
        persistSoon()
    }

    func moveCards(_ ids: [String], dx: Double, dy: Double) {
        let set = Set(ids)
        patchLesson { lesson in
            for i in lesson.cards.indices where set.contains(lesson.cards[i].id) {
                lesson.cards[i].x += dx
                lesson.cards[i].y += dy
            }
        }
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
        let pad: Double = 420
        let expanded = bounds.insetBy(dx: -pad, dy: -pad)
        let viewW = viewport.width
        let viewH = viewport.height
        var minCamX = viewW - expanded.maxX * zoom
        var maxCamX = -expanded.minX * zoom
        var minCamY = viewH - expanded.maxY * zoom
        var maxCamY = -expanded.minY * zoom
        if minCamX > maxCamX {
            let mid = (minCamX + maxCamX) / 2
            minCamX = mid
            maxCamX = mid
        }
        if minCamY > maxCamY {
            let mid = (minCamY + maxCamY) / 2
            minCamY = mid
            maxCamY = mid
        }
        func rubberClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            if v < lo { return rubber ? lo + (v - lo) * 0.22 : lo }
            if v > hi { return rubber ? hi + (v - hi) * 0.22 : hi }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { self.cameraEase = false }
        } else {
            saveNow()
        }
    }

    func snapSelected() {
        guard settings.snapping else { return }
        let g = 8.0
        let ids = Set(selectedIDs)
        patchLesson { lesson in
            for i in lesson.cards.indices where ids.contains(lesson.cards[i].id) {
                lesson.cards[i].x = (lesson.cards[i].x / g).rounded() * g
                lesson.cards[i].y = (lesson.cards[i].y / g).rounded() * g
            }
        }
    }

    func scaleCard(_ id: String, delta: CGSize) {
        guard let card = card(id) else { return }
        let zoom = max(activeLesson?.camera.zoom ?? 1, 0.01)
        let dx = delta.width / zoom
        let dy = delta.height / zoom
        let minW: Double = card.kind == .note ? 220 : (card.kind == .text ? 64 : 64)
        let minH: Double = card.kind == .note ? 100 : (card.kind == .text ? 28 : 64)
        let maxW: Double = card.kind == .note ? 420 : 2400
        let maxH: Double = card.kind == .note ? 160 : 2400
        let aspect = card.width / max(1, card.height)

        if card.kind == .text {
            // Corner-resize scales type size with the frame (not empty selection chrome).
            updateCard(id, persist: false) {
                let oldW = max($0.width, 1)
                let oldH = max($0.height, 1)
                let tentativeW = min(maxW, max(minW, oldW + dx))
                let tentativeH = min(maxH, max(minH, oldH + dy))
                let scale = max(0.05, hypot(tentativeW, tentativeH) / hypot(oldW, oldH))
                let oldSize = max(8, $0.fontSize ?? 16)
                let nextSize = min(200, max(8, (oldSize * scale * 10).rounded() / 10))
                let fontScale = nextSize / oldSize
                $0.fontSize = nextSize
                $0.width = min(maxW, max(minW, oldW * fontScale))
                $0.height = min(maxH, max(minH, oldH * fontScale))
            }
            return
        }

        let free = NSEvent.modifierFlags.contains(.shift) || card.kind == .note
        updateCard(id, persist: false) {
            if free {
                $0.width = min(maxW, max(minW, $0.width + dx))
                $0.height = min(maxH, max(minH, $0.height + dy))
            } else {
                let scaleX = ($0.width + dx) / max(1, $0.width)
                let scaleY = ($0.height + dy) / max(1, $0.height)
                let scale = max(minW / max($0.width, 1), minH / max($0.height, 1), abs(dx) >= abs(dy) ? scaleX : scaleY)
                let width = min(maxW, max(minW, $0.width * scale))
                $0.width = width
                $0.height = min(maxH, max(minH, width / aspect))
            }
        }
    }

    func exportLesson(_ id: String) {
        guard let lesson = library.lessons.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(lesson.title).json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url, let data = try? JSONEncoder().encode(lesson) {
            try? data.write(to: url)
        }
    }

    func bringToFront(_ id: String) {
        let z = (activeLesson?.cards.map(\.z).max() ?? 0) + 1
        updateCard(id) { $0.z = z }
    }

    func layer(_ dir: Int) {
        let ids = Set(selectedIDs)
        patchLesson { lesson in
            for i in lesson.cards.indices where ids.contains(lesson.cards[i].id) {
                lesson.cards[i].z = dir > 0 ? lesson.cards[i].z + 1 : max(0, lesson.cards[i].z - 1)
            }
        }
        persistSoon()
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
        let copies = lesson.cards.filter { selectedIDs.contains($0.id) }.map { card -> Card in
            var c = card
            c.id = NexusID.make("c")
            c.x += 24
            c.y += 24
            return c
        }
        patchLesson { $0.cards.append(contentsOf: copies) }
        selectedIDs = copies.map(\.id)
        persistSoon()
    }

    func copySelected() {
        clipboard = activeLesson?.cards.filter { selectedIDs.contains($0.id) } ?? []
    }

    func paste(at point: CGPoint) {
        if !clipboard.isEmpty {
            pushUndo()
            let minX = clipboard.map(\.x).min() ?? 0
            let minY = clipboard.map(\.y).min() ?? 0
            var ids: [String] = []
            patchLesson { lesson in
                var z = (lesson.cards.map(\.z).max() ?? 0)
                for c in clipboard {
                    var n = c
                    n.id = NexusID.make("c")
                    n.x = point.x + (c.x - minX)
                    n.y = point.y + (c.y - minY)
                    z += 1
                    n.z = z
                    lesson.cards.append(n)
                    ids.append(n.id)
                }
            }
            selectedIDs = ids
            persistSoon()
            return
        }
        Task { await pasteFromPasteboard(at: point) }
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
            default: return ("Delete this?", "This will permanently delete the object from the board.")
            }
        }()
        let alert = NSAlert()
        alert.messageText = prompt.0
        alert.informativeText = prompt.1
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pushUndo()
        let ids = Set(selectedIDs)
        patchLesson { $0.cards.removeAll { ids.contains($0.id) } }
        selectedIDs = []
        noteOpenID = nil
        menu = nil
        persistSoon()
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
            let url = (src.hasPrefix("http") || src.hasPrefix("file:")) ? URL(string: src) : URL(fileURLWithPath: src)
            if let url {
                Playback.shared.playAudio(url: url, durationHint: Format.parseDuration(card.duration))
            }
        } else if card.kind == .video, let src = card.src, let url = URL(string: src) {
            _ = Playback.shared.playVideo(url: url)
        } else if card.kind == .audio {
            Playback.shared.durationSeconds = Format.parseDuration(card.duration)
        } else {
            Playback.shared.stop()
        }
        playingID = id
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

    func insertBlankText(at point: CGPoint? = nil) {
        let origin = point ?? lastWorld
        let id = NexusID.make("c")
        let width: Double = 140
        let height: Double = 36
        var card = DemoLibrary.base(id, .text, origin.x, origin.y, width, height, 1)
        card.html = ""
        card.body = ""
        card.fontSize = 16
        addCard(card)
        editingID = id
        tool = .select
        selectedIDs = [id]
        let waveID = (textWave?.id ?? 0) + 1
        textWave = TextWaveEvent(id: waveID, x: origin.x + width / 2, y: origin.y + height / 2)
    }

    func insertBlankNote() {
        var card = DemoLibrary.base(NexusID.make("c"), .note, lastWorld.x, lastWorld.y, Format.notePreview.width, Format.notePreview.height, 1)
        card.title = "Note"
        card.body = ""
        addCard(card)
        noteOpenID = card.id
        select([card.id])
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
                if editingID != hit.id { editingID = nil }
            }
            menu = MenuAnchor(x: point.x, y: point.y, cardID: hit.id)
        } else {
            menu = MenuAnchor(x: point.x, y: point.y, cardID: nil)
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
        noteOpenID = id
        menu = nil
    }

    func insertURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let point = lastWorld
        if let yt = Format.youtubeID(trimmed) {
            addCard(DemoLibrary.youtube(NexusID.make("c"), point.x, point.y, yt, "YouTube"))
            return
        }
        if trimmed.range(of: #"\.(png|jpe?g|gif|webp|heic)(\?|$)"#, options: .regularExpression) != nil {
            addImageCard(src: trimmed, alt: trimmed, x: point.x, y: point.y)
            return
        }
        Task {
            let meta = await OpenGraph.fetch(trimmed)
            if let image = meta.image {
                addCard(DemoLibrary.linkRich(NexusID.make("c"), point.x, point.y, meta.title, meta.host, meta.url, image))
            } else {
                addCard(DemoLibrary.linkChip(NexusID.make("c"), point.x, point.y, meta.title, meta.host, meta.url, "#34C759"))
            }
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

        if !isDir.boolValue, ext == "txt", let body = try? String(contentsOf: url, encoding: .utf8) {
            var card = DemoLibrary.note(NexusID.make("c"), x, y, body)
            card.title = url.deletingPathExtension().lastPathComponent
            addCard(card)
            noteOpenID = card.id
            return
        }
        if !isDir.boolValue, FileKind.images.contains(ext), let dest = importIntoActiveLesson(url) {
            addImageCard(src: dest.absoluteString, alt: url.lastPathComponent, x: x, y: y, fileURL: dest)
            return
        }
        if !isDir.boolValue, FileKind.audio.contains(ext), let dest = importIntoActiveLesson(url) {
            Task {
                var card = DemoLibrary.audio(NexusID.make("c"), x, y, 196, 196, 1, "#34C759", url.deletingPathExtension().lastPathComponent, "0:00")
                card.src = dest.absoluteString
                if let dur = try? await AVURLAsset(url: dest).load(.duration) {
                    card.duration = Format.duration(dur.seconds)
                }
                addCard(card)
            }
            return
        }
        if !isDir.boolValue, FileKind.video.contains(ext), let dest = importIntoActiveLesson(url) {
            var card = DemoLibrary.video(NexusID.make("c"), x, y, 200, 280, 1, dest.absoluteString, url.lastPathComponent)
            card.src = dest.absoluteString
            addCard(card)
            return
        }
        var card = DemoLibrary.shortcut(NexusID.make("c"), x, y, url.lastPathComponent, url.path)
        card.missing = false
        addCard(card)
    }

    func pasteFromPasteboard(at point: CGPoint) async {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        {
            let dest: URL = {
                if let lesson = activeLesson {
                    let media = Persistence.mediaDirectory(for: lesson, subjects: library.subjects)
                    return media.appendingPathComponent("\(NexusID.make("m")).jpg")
                }
                return Persistence.projectsRoot.appendingPathComponent("\(NexusID.make("m")).jpg")
            }()
            try? data.write(to: dest)
            addImageCard(src: dest.absoluteString, alt: "Pasted image", x: point.x, y: point.y, image: image)
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            if url.isFileURL {
                importURL(url, x: point.x, y: point.y)
            } else {
                insertURL(url.absoluteString)
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
            if text.hasPrefix("http"), !text.contains(" ") {
                insertURL(text)
            } else {
                insertRichTextCard(html: nil, plain: String(text.prefix(Format.textLimit)), at: point)
            }
        }
    }

    func insertRichTextCard(html: String?, plain: String?, at point: CGPoint) {
        let body = plain ?? CanvasTextEditor.plainText(html: html, fallback: nil)
        let clipped = String(body.prefix(Format.textLimit))
        var card = DemoLibrary.text(NexusID.make("c"), point.x, point.y, 360, 80, 1, "", 16)
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
        let wrap: Double = clipped.count > 80 ? 480 : min(480, max(120, Double(clipped.count) * 8 + 24))
        let lines = max(1, Int(ceil(Double(clipped.count) / max(24, wrap / 8))))
        card.width = wrap
        card.height = max(28, Double(lines) * 22 + 8)
        addCard(card)
        editingID = card.id
        select([card.id])
        let waveID = (textWave?.id ?? 0) + 1
        textWave = TextWaveEvent(id: waveID, x: point.x + card.width / 2, y: point.y + card.height / 2)
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
        addCard(DemoLibrary.image(NexusID.make("c"), x, y, fitted.width, fitted.height, 1, src, alt))
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

    func openLens(_ src: String?) {
        let q = src.flatMap(URL.init(string:))?.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://lens.google.com/uploadbyurl?url=\(q)") {
            NSWorkspace.shared.open(url)
        }
    }

    func askAbout(_ id: String?) {
        if let id, let card = card(id), card.kind == .image, let src = card.src {
            openLens(src)
            menu = nil
            return
        }
        askAICardID = id ?? "board"
        menu = nil
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
        editingID = nil
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
            let (data, _) = try await URLSession.shared.data(from: url)
            let html = String(data: data, encoding: .utf8) ?? ""
            func meta(_ key: String) -> String? {
                let patterns = [
                    "property=\"\(key)\" content=\"([^\"]+)\"",
                    "name=\"\(key)\" content=\"([^\"]+)\"",
                    "content=\"([^\"]+)\" property=\"\(key)\"",
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
            let title = meta("og:title")
                ?? html.range(of: "<title[^>]*>([^<]+)</title>", options: [.regularExpression, .caseInsensitive]).map { String(html[$0]) }
                ?? host
            return Meta(title: title, host: host, url: urlString, image: meta("og:image"))
        } catch {
            return Meta(title: host, host: host, url: urlString, image: nil)
        }
    }
}

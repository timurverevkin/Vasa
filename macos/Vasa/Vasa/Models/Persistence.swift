import Foundation

enum Persistence {
    /// App Support — settings and migration leftovers only.
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vasa", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var legacyLibraryFile: URL {
        folder.appendingPathComponent("library.json")
    }

    static var projectsRoot: URL {
        let path = AppSettings.load().projectsFolder
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var libraryIndexFile: URL {
        projectsRoot.appendingPathComponent("library.json")
    }

    static func lessonDirectory(_ lesson: Lesson, subjects: [Subject]) -> URL {
        if let path = lesson.path, !path.isEmpty {
            return projectsRoot.appendingPathComponent(path, isDirectory: true)
        }
        return defaultDirectory(for: lesson, subjects: subjects)
    }

    static func mediaDirectory(for lesson: Lesson, subjects: [Subject]) -> URL {
        let url = lessonDirectory(lesson, subjects: subjects).appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func boardFile(for lesson: Lesson, subjects: [Subject]) -> URL {
        lessonDirectory(lesson, subjects: subjects).appendingPathComponent("board.json")
    }

    static func load() -> Library? {
        migrateLegacyIfNeeded()
        // Prefer Documents library; drop stale App Support monolith after migration.
        if FileManager.default.fileExists(atPath: libraryIndexFile.path),
           FileManager.default.fileExists(atPath: legacyLibraryFile.path) {
            try? FileManager.default.removeItem(at: legacyLibraryFile)
        }
        guard let index = loadIndex() else { return nil }
        var lessons: [Lesson] = []
        for ref in index.lessons {
            if let lesson = loadBoard(ref: ref) {
                lessons.append(lesson)
            }
        }
        guard !lessons.isEmpty || !index.subjects.isEmpty else { return nil }
        return Library(
            rev: index.rev ?? Format.libraryRev,
            subjects: index.subjects,
            lessons: lessons,
            openLessonIds: index.openLessonIds,
            activeLessonId: index.activeLessonId,
            sidebarOpen: index.sidebarOpen
        )
    }

    /// Encode boards/index on the caller’s actor; returned payloads are safe to write off-main.
    static func prepareWrites(
        _ library: Library,
        dirtyLessonIDs: Set<String>?,
        prune: Bool,
        recomputeBytes: Bool
    ) -> DiskWriteBatch {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        var refs: [LessonRef] = []
        var seenPaths = Set<String>()
        var files: [(URL, Data)] = []
        let writeAll = dirtyLessonIDs == nil
        let dirty = dirtyLessonIDs ?? []
        let encoder = JSONEncoder()

        for var lesson in library.lessons {
            let path = ensurePath(&lesson, subjects: library.subjects, taken: &seenPaths)
            lesson.path = path
            let dir = projectsRoot.appendingPathComponent(path, isDirectory: true)
            let media = dir.appendingPathComponent("media", isDirectory: true)
            let boardURL = dir.appendingPathComponent("board.json")
            let shouldWrite = writeAll || dirty.contains(lesson.id)

            if shouldWrite {
                try? fm.createDirectory(at: media, withIntermediateDirectories: true)
                var stored = lesson
                stored.cards = relativizeMedia(lesson.cards, mediaFolder: media)
                if recomputeBytes {
                    stored.bytes = folderBytes(dir)
                } else {
                    stored.bytes = lesson.bytes
                }
                if let data = try? encoder.encode(stored) {
                    files.append((boardURL, data))
                }
                refs.append(LessonRef(
                    id: lesson.id,
                    subjectId: lesson.subjectId,
                    title: lesson.title,
                    path: path,
                    updatedAt: lesson.updatedAt,
                    pinned: lesson.pinned,
                    bytes: stored.bytes,
                    thumb: lesson.thumb
                ))
            } else {
                refs.append(LessonRef(
                    id: lesson.id,
                    subjectId: lesson.subjectId,
                    title: lesson.title,
                    path: path,
                    updatedAt: lesson.updatedAt,
                    pinned: lesson.pinned,
                    bytes: lesson.bytes,
                    thumb: lesson.thumb
                ))
            }
        }

        let index = LibraryIndex(
            rev: Format.libraryRev,
            subjects: library.subjects,
            lessons: refs,
            openLessonIds: library.openLessonIds,
            activeLessonId: library.activeLessonId,
            sidebarOpen: library.sidebarOpen
        )
        if let data = try? encoder.encode(index) {
            files.append((libraryIndexFile, data))
        }

        return DiskWriteBatch(
            files: files,
            pruneKeeping: prune ? Set(refs.map(\.path)) : nil
        )
    }

    static func commit(_ batch: DiskWriteBatch) {
        VasaDisk.write(batch.files)
        if let keeping = batch.pruneKeeping {
            pruneOrphans(keeping: keeping)
        }
    }

    static func pruneLessonFolders(keeping: Set<String>) {
        pruneOrphans(keeping: keeping)
    }

    static func save(_ library: Library) {
        let batch = prepareWrites(library, dirtyLessonIDs: nil, prune: true, recomputeBytes: true)
        commit(batch)
    }

    static func save(_ library: Library, dirtyLessonIDs: Set<String>?, prune: Bool, recomputeBytes: Bool) {
        let batch = prepareWrites(library, dirtyLessonIDs: dirtyLessonIDs, prune: prune, recomputeBytes: recomputeBytes)
        commit(batch)
    }

    static func saveIndexOnly(_ library: Library) {
        save(library, dirtyLessonIDs: [], prune: false, recomputeBytes: false)
    }

    static func resolvedPath(for lesson: inout Lesson, subjects: [Subject], taken: inout Set<String>) -> String {
        ensurePath(&lesson, subjects: subjects, taken: &taken)
    }

    /// Filesystem-safe, reasonably short stem for an imported media file's name.
    private static func sanitizedMediaName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        let collapsed = cleaned.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let truncated = String(collapsed.prefix(40))
        return truncated.isEmpty ? "media" : truncated
    }

    static func importFile(from source: URL, lesson: Lesson, subjects: [Subject]) -> URL? {
        let media = mediaDirectory(for: lesson, subjects: subjects)
        // Keep the source's own name (sanitized) instead of the bare "m_<hash>" id —
        // legible when browsing the media folder in Finder, and it's what a derived
        // poster's filename (video name + ".poster.jpg") inherits too.
        let base = sanitizedMediaName(source.deletingPathExtension().lastPathComponent)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let name = "\(base)-\(suffix)\(source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")"
        let dest = media.appendingPathComponent(name)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Absolute media URL for in-memory use.
    static func resolveMedia(_ src: String?, lesson: Lesson, subjects: [Subject]) -> String? {
        guard let src, !src.isEmpty else { return nil }
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return src }
        let media = mediaDirectory(for: lesson, subjects: subjects)
        return absolutize(src, mediaFolder: media)
    }

    /// Re-bind local media paths to the lesson's current media folder (fixes rename drift).
    static func healMediaPaths(_ lesson: inout Lesson, subjects: [Subject]) {
        let media = mediaDirectory(for: lesson, subjects: subjects)
        lesson.cards = absolutizeMedia(lesson.cards, mediaFolder: media)
    }

    static func deleteLessonFolder(_ lesson: Lesson, subjects: [Subject]) {
        let dir = lessonDirectory(lesson, subjects: subjects)
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
    }

    static func duplicateLessonFolder(_ lesson: Lesson, subjects: [Subject], newID: String, newTitle: String) -> Lesson? {
        let source = lessonDirectory(lesson, subjects: subjects)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        var copy = lesson
        copy.id = newID
        copy.title = newTitle
        copy.updatedAt = Date().timeIntervalSince1970 * 1000
        copy.path = nil
        var taken = Set<String>()
        let path = ensurePath(&copy, subjects: subjects, taken: &taken)
        copy.path = path
        let dest = projectsRoot.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            let oldMedia = source.appendingPathComponent("media")
            let newMedia = dest.appendingPathComponent("media")
            copy.cards = relativizeMedia(copy.cards, mediaFolder: oldMedia)
            copy.cards = absolutizeMedia(copy.cards, mediaFolder: newMedia)
            writeBoard(copy, to: dest.appendingPathComponent("board.json"))
            copy.bytes = folderBytes(dest)
            return copy
        } catch {
            return nil
        }
    }

    static func renameLessonFolder(_ lesson: inout Lesson, subjects: [Subject], title: String) {
        let old = lessonDirectory(lesson, subjects: subjects)
        let previousPath = lesson.path
        lesson.title = title
        var taken = Set<String>()
        let newPath = uniquePath(
            subjectTitle: subjectTitle(lesson.subjectId, subjects),
            projectTitle: title,
            taken: &taken,
            reusing: previousPath
        )
        let dest = projectsRoot.appendingPathComponent(newPath, isDirectory: true)
        if old.standardizedFileURL.path != dest.standardizedFileURL.path {
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.moveItem(at: old, to: dest)
            } else {
                try? FileManager.default.createDirectory(at: dest.appendingPathComponent("media"), withIntermediateDirectories: true)
            }
        }
        lesson.path = newPath
        lesson.cards = absolutizeMedia(lesson.cards, mediaFolder: dest.appendingPathComponent("media"))
    }

    // MARK: - Private

    private static var fm: FileManager { .default }

    private static func loadIndex() -> LibraryIndex? {
        guard let data = try? Data(contentsOf: libraryIndexFile) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    private static func loadBoard(ref: LessonRef) -> Lesson? {
        let file = projectsRoot.appendingPathComponent(ref.path).appendingPathComponent("board.json")
        guard let data = try? Data(contentsOf: file),
              var lesson = try? JSONDecoder().decode(Lesson.self, from: data)
        else { return nil }
        lesson.id = ref.id
        lesson.subjectId = ref.subjectId
        lesson.title = ref.title
        lesson.path = ref.path
        lesson.updatedAt = ref.updatedAt
        lesson.pinned = ref.pinned
        lesson.bytes = ref.bytes ?? folderBytes(file.deletingLastPathComponent())
        lesson.thumb = ref.thumb
        let media = file.deletingLastPathComponent().appendingPathComponent("media")
        lesson.cards = absolutizeMedia(lesson.cards, mediaFolder: media)
        return lesson
    }

    private static func writeBoard(_ lesson: Lesson, to url: URL) {
        let encoder = JSONEncoder()
        // Compact JSON — pretty print was rewriting every board slowly on the main thread.
        guard let data = try? encoder.encode(lesson) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func defaultDirectory(for lesson: Lesson, subjects: [Subject]) -> URL {
        let path = "\(sanitize(subjectTitle(lesson.subjectId, subjects)))/\(sanitize(lesson.title)).vasa"
        return projectsRoot.appendingPathComponent(path, isDirectory: true)
    }

    private static func ensurePath(_ lesson: inout Lesson, subjects: [Subject], taken: inout Set<String>) -> String {
        if let path = lesson.path, !path.isEmpty {
            taken.insert(path)
            return path
        }
        let path = uniquePath(
            subjectTitle: subjectTitle(lesson.subjectId, subjects),
            projectTitle: lesson.title,
            taken: &taken,
            reusing: nil
        )
        lesson.path = path
        taken.insert(path)
        return path
    }

    /// Each project lives in its own `.vasa` package (a directory Finder/LaunchServices
    /// treat as a single opaque file via the exported `app.vasa.project` UTI — see Info.plist).
    private static func uniquePath(subjectTitle: String, projectTitle: String, taken: inout Set<String>, reusing: String? = nil) -> String {
        let subject = sanitize(subjectTitle)
        let base = sanitize(projectTitle)
        var path = "\(subject)/\(base).vasa"
        if let reusing, reusing == path {
            taken.insert(path)
            return path
        }
        var n = 2
        while true {
            let disk = fm.fileExists(atPath: projectsRoot.appendingPathComponent(path).path)
            let blocked = taken.contains(path) || (disk && path != reusing)
            if !blocked {
                taken.insert(path)
                return path
            }
            path = "\(subject)/\(base) \(n).vasa"
            n += 1
        }
    }

    private static func subjectTitle(_ id: String, _ subjects: [Subject]) -> String {
        subjects.first { $0.id == id }?.title ?? "Projects"
    }

    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private static func relativizeMedia(_ cards: [Card], mediaFolder: URL) -> [Card] {
        let prefix = mediaFolder.standardizedFileURL.path
        return cards.map { card in
            var next = card
            next.src = relativize(next.src, mediaPrefix: prefix, mediaFolder: mediaFolder)
            next.poster = relativize(next.poster, mediaPrefix: prefix, mediaFolder: mediaFolder)
            next.image = relativize(next.image, mediaPrefix: prefix, mediaFolder: mediaFolder)
            return next
        }
    }

    private static func absolutizeMedia(_ cards: [Card], mediaFolder: URL) -> [Card] {
        cards.map { card in
            var next = card
            next.src = absolutize(next.src, mediaFolder: mediaFolder)
            next.poster = absolutize(next.poster, mediaFolder: mediaFolder)
            next.image = absolutize(next.image, mediaFolder: mediaFolder)
            return next
        }
    }

    private static func relativize(_ src: String?, mediaPrefix: String, mediaFolder: URL) -> String? {
        guard let src, !src.isEmpty else { return src }
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return src }
        let path: String
        if src.hasPrefix("file:"), let url = URL(string: src) {
            path = url.standardizedFileURL.path
        } else if src.hasPrefix("/") {
            path = URL(fileURLWithPath: src).standardizedFileURL.path
        } else if src.hasPrefix("media/") {
            return src
        } else {
            return src
        }
        if path.hasPrefix(mediaPrefix) {
            let rel = String(path.dropFirst(mediaPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "media/\(rel)"
        }
        // Foreign local file — copy on next import; keep absolute for now.
        return URL(fileURLWithPath: path).absoluteString
    }

    private static func absolutize(_ src: String?, mediaFolder: URL) -> String? {
        guard let src, !src.isEmpty else { return src }
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return src }

        if src.hasPrefix("file:"), let url = URL(string: src) {
            let path = url.standardizedFileURL.path
            if fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path).absoluteString
            }
            // Stale absolute path after lesson rename/move — recover by filename in current media/.
            let recovered = mediaFolder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: recovered.path) {
                return recovered.absoluteString
            }
            return src
        }
        if src.hasPrefix("media/") {
            return mediaFolder
                .deletingLastPathComponent()
                .appendingPathComponent(src)
                .absoluteString
        }
        if src.hasPrefix("/") {
            let path = URL(fileURLWithPath: src).standardizedFileURL.path
            if fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path).absoluteString
            }
            let recovered = mediaFolder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            if fm.fileExists(atPath: recovered.path) {
                return recovered.absoluteString
            }
            return URL(fileURLWithPath: path).absoluteString
        }
        let local = mediaFolder.appendingPathComponent(src)
        return local.absoluteString
    }

    private static func folderBytes(_ url: URL) -> Double {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Double = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Double(size)
        }
        return total
    }

    private static func pruneOrphans(keeping paths: Set<String>) {
        guard let subjects = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for subjectURL in subjects {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subjectURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if subjectURL.lastPathComponent == "library.json" { continue }
            guard let projects = try? fm.contentsOfDirectory(at: subjectURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for projectURL in projects {
                let rel = "\(subjectURL.lastPathComponent)/\(projectURL.lastPathComponent)"
                let board = projectURL.appendingPathComponent("board.json")
                guard fm.fileExists(atPath: board.path) else { continue }
                if !paths.contains(rel) {
                    try? fm.trashItem(at: projectURL, resultingItemURL: nil)
                }
            }
            if let left = try? fm.contentsOfDirectory(at: subjectURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]), left.isEmpty {
                try? fm.removeItem(at: subjectURL)
            }
        }
    }

    private static func migrateLegacyIfNeeded() {
        if fm.fileExists(atPath: libraryIndexFile.path) { return }
        guard fm.fileExists(atPath: legacyLibraryFile.path),
              let data = try? Data(contentsOf: legacyLibraryFile),
              let legacy = try? JSONDecoder().decode(Library.self, from: data),
              !legacy.lessons.isEmpty
        else { return }

        var library = legacy
        library.rev = Format.libraryRev
        // Copy global media into each lesson folder that references it when saving.
        let oldMedia = folder.appendingPathComponent("media", isDirectory: true)
        for i in library.lessons.indices {
            var taken = Set<String>()
            _ = ensurePath(&library.lessons[i], subjects: library.subjects, taken: &taken)
            let media = mediaDirectory(for: library.lessons[i], subjects: library.subjects)
            library.lessons[i].cards = library.lessons[i].cards.map { card in
                var next = card
                next.src = migrateMediaFile(next.src, oldMedia: oldMedia, newMedia: media)
                next.poster = migrateMediaFile(next.poster, oldMedia: oldMedia, newMedia: media)
                next.image = migrateMediaFile(next.image, oldMedia: oldMedia, newMedia: media)
                return next
            }
        }
        save(library)
    }

    private static func migrateMediaFile(_ src: String?, oldMedia: URL, newMedia: URL) -> String? {
        guard let src else { return nil }
        guard let url = ImageMedia.fileURL(from: src) else { return src }
        let path = url.path
        guard path.hasPrefix(oldMedia.path) else { return src }
        let name = url.lastPathComponent
        let dest = newMedia.appendingPathComponent(name)
        try? fm.createDirectory(at: newMedia, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: dest.path) {
            try? fm.copyItem(at: url, to: dest)
        }
        return dest.absoluteString
    }
}

private struct LibraryIndex: Codable {
    var rev: Int?
    var subjects: [Subject]
    var lessons: [LessonRef]
    var openLessonIds: [String]
    var activeLessonId: String?
    var sidebarOpen: Bool
}

private struct LessonRef: Codable {
    var id: String
    var subjectId: String
    var title: String
    var path: String
    var updatedAt: Double
    var pinned: Bool?
    var bytes: Double?
    var thumb: String?
}

struct DiskWriteBatch: Sendable {
    let files: [(URL, Data)]
    let pruneKeeping: Set<String>?
}

enum VasaDisk {
    nonisolated static func write(_ files: [(URL, Data)]) {
        for (url, data) in files {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

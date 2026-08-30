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

    /// Unpacked working copies, one per project, keyed by lesson id.
    ///
    /// A `.vasa` in the library is a single zip file, which nothing can append to
    /// incrementally — so editing happens here, at plain-filesystem speed, exactly as
    /// it did when projects were packages. The archive is rewritten from this
    /// directory on a pause, on switching away, and on quit (`writeBack`).
    ///
    /// Keyed by id rather than path so renaming a project never has to move it.
    static var workingRoot: URL {
        let url = folder.appendingPathComponent("Working", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func workingDirectory(forLessonID id: String) -> URL {
        workingRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The `.vasa` file in the library that backs this project.
    static func libraryFile(for lesson: Lesson, subjects: [Subject]) -> URL {
        if let path = lesson.path, !path.isEmpty {
            return projectsRoot.appendingPathComponent(path)
        }
        return defaultDirectory(for: lesson, subjects: subjects)
    }

    /// Working copy for a project, unpacked from its archive on first use.
    static func lessonDirectory(_ lesson: Lesson, subjects: [Subject]) -> URL {
        let working = workingDirectory(forLessonID: lesson.id)
        if !FileManager.default.fileExists(atPath: working.appendingPathComponent("board.json").path) {
            let archive = libraryFile(for: lesson, subjects: subjects)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // A project still in the pre-0.2.3 package layout — adopt it as-is.
                    try? FileManager.default.createDirectory(at: workingRoot, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: working)
                    try? FileManager.default.copyItem(at: archive, to: working)
                } else {
                    try? unpackArchive(at: archive, into: working)
                }
            }
        }
        try? FileManager.default.createDirectory(
            at: working.appendingPathComponent("media", isDirectory: true),
            withIntermediateDirectories: true
        )
        return working
    }

    /// Rewrite a project's `.vasa` from its working copy.
    @discardableResult
    static func writeBack(_ lesson: Lesson, subjects: [Subject]) -> Bool {
        let working = workingDirectory(forLessonID: lesson.id)
        guard fm.fileExists(atPath: working.appendingPathComponent("board.json").path) else { return false }
        do {
            try packArchive(from: working, to: libraryFile(for: lesson, subjects: subjects))
            return true
        } catch {
            return false
        }
    }

    static func discardWorkingCopy(forLessonID id: String) {
        try? fm.removeItem(at: workingDirectory(forLessonID: id))
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
        migratePackagesToArchives(lessons, subjects: index.subjects)
        return Library(
            rev: index.rev ?? Format.libraryRev,
            subjects: index.subjects,
            lessons: lessons,
            openLessonIds: index.openLessonIds,
            activeLessonId: index.activeLessonId,
            sidebarOpen: index.sidebarOpen
        )
    }

    /// Fold any project still stored as a pre-0.2.3 package directory into a single
    /// `.vasa` file. Runs once at load: waiting for a project to be edited would leave
    /// untouched ones as directories forever, and they no longer read as packages in
    /// Finder now that the type is plain data.
    ///
    /// Their contents have already been adopted as working copies by `loadBoard`, so
    /// this only has to write the archive over the old directory.
    private static func migratePackagesToArchives(_ lessons: [Lesson], subjects: [Subject]) {
        for lesson in lessons {
            guard let path = lesson.path, !path.isEmpty else { continue }
            let archive = projectsRoot.appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: archive.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let working = workingDirectory(forLessonID: lesson.id)
            guard fm.fileExists(atPath: working.appendingPathComponent("board.json").path) else { continue }
            try? packArchive(from: working, to: archive)
        }
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

        var repack: [(working: URL, archive: URL)] = []

        for var lesson in library.lessons {
            let path = ensurePath(&lesson, subjects: library.subjects, taken: &seenPaths)
            lesson.path = path
            // Board and media live in the working copy; the `.vasa` in the library is
            // rebuilt from it during `commit`.
            let dir = workingDirectory(forLessonID: lesson.id)
            let media = dir.appendingPathComponent("media", isDirectory: true)
            let boardURL = dir.appendingPathComponent("board.json")
            let shouldWrite = writeAll || dirty.contains(lesson.id)

            if shouldWrite {
                try? fm.createDirectory(at: media, withIntermediateDirectories: true)
                repack.append((dir, projectsRoot.appendingPathComponent(path)))
                var stored = lesson
                stored.cards = relativizeMedia(lesson.cards, mediaFolder: media)
                stored.thumb = relativize(
                    lesson.thumb,
                    mediaPrefix: media.standardizedFileURL.path,
                    mediaFolder: media
                )
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
            pruneKeeping: prune ? Set(refs.map(\.path)) : nil,
            repack: repack
        )
    }

    static func commit(_ batch: DiskWriteBatch) {
        VasaDisk.write(batch.files)
        // Board data is now on disk in the working copies — fold each changed one back
        // into its single-file `.vasa`.
        for item in batch.repack {
            try? packArchive(from: item.working, to: item.archive)
        }
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
        // Trash the user-visible archive; the working copy is a cache, so it just goes.
        let archive = libraryFile(for: lesson, subjects: subjects)
        if fm.fileExists(atPath: archive.path) {
            try? fm.trashItem(at: archive, resultingItemURL: nil)
        }
        discardWorkingCopy(forLessonID: lesson.id)
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
        // Duplicate the working copy, then build the new project's archive from it.
        let dest = workingDirectory(forLessonID: newID)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.createDirectory(at: workingRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
            let oldMedia = source.appendingPathComponent("media")
            let newMedia = dest.appendingPathComponent("media")
            copy.cards = relativizeMedia(copy.cards, mediaFolder: oldMedia)
            copy.cards = absolutizeMedia(copy.cards, mediaFolder: newMedia)
            writeBoard(copy, to: dest.appendingPathComponent("board.json"))
            try packArchive(from: dest, to: projectsRoot.appendingPathComponent(path))
            copy.bytes = folderBytes(dest)
            return copy
        } catch {
            return nil
        }
    }

    // MARK: - .vasa archive

    enum ArchiveError: Error {
        case missingSource
        case notAProject
        case failed(Int32)
    }

    /// Media types that are already compressed — storing them verbatim keeps writes at
    /// I/O speed instead of burning CPU re-compressing video. `board.json` still gets
    /// deflated, where it earns roughly an 11× reduction on a large board.
    private static let storedSuffixes = "jpg:jpeg:png:gif:webp:heic:mp4:mov:m4v:avi:mp3:m4a:aac:wav:flac"

    /// Zip a project's working directory into a single `.vasa` file, atomically.
    ///
    /// Written to a sibling temp path and moved into place, so a crash mid-write leaves
    /// the previous file intact rather than a half-flushed archive.
    static func packArchive(from workingDir: URL, to dest: URL) throws {
        guard fm.fileExists(atPath: workingDir.path) else { throw ArchiveError.missingSource }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: staging) }
        // `-r .` from inside the working directory: entries sit at the archive root, so
        // unpacking restores board.json + media/ directly with no wrapper level.
        try run(
            "/usr/bin/zip",
            ["-q", "-r", "-X", "-n", storedSuffixes, staging.path, "."],
            cwd: workingDir
        )
        var destIsDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &destIsDir) {
            if destIsDir.boolValue {
                // Migrating a pre-0.2.3 package: its contents were already adopted as the
                // working copy, so the directory can give way to the archive.
                try fm.removeItem(at: dest)
                try fm.moveItem(at: staging, to: dest)
            } else {
                _ = try fm.replaceItemAt(dest, withItemAt: staging)
            }
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
    }

    /// Unpack a `.vasa` file into `dest`, replacing whatever is there.
    static func unpackArchive(at source: URL, into dest: URL) throws {
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", "-o", source.path, "-d", dest.path], cwd: nil)
        guard fm.fileExists(atPath: dest.appendingPathComponent("board.json").path) else {
            throw ArchiveError.notAProject
        }
    }

    private static func run(_ tool: String, _ arguments: [String], cwd: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiveError.failed(process.terminationStatus)
        }
    }

    /// Take an external `.vasa` into the library and return the lesson it holds, re-homed
    /// onto a fresh id and a free path so importing the same file twice yields two
    /// projects rather than clobbering one.
    ///
    /// Accepts both a single-file archive and a pre-0.2.3 package directory, so files
    /// exported by an older build still open.
    static func importProject(at source: URL, subjectId: String, subjects: [Subject], newID: String) -> Lesson? {
        let working = workingDirectory(forLessonID: newID)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return nil }
        do {
            try? fm.removeItem(at: working)
            try fm.createDirectory(at: workingRoot, withIntermediateDirectories: true)
            if isDir.boolValue {
                try fm.copyItem(at: source, to: working)
            } else {
                try unpackArchive(at: source, into: working)
            }
        } catch {
            return nil
        }

        guard let data = try? Data(contentsOf: working.appendingPathComponent("board.json")),
              var lesson = try? JSONDecoder().decode(Lesson.self, from: data)
        else {
            try? fm.removeItem(at: working)
            return nil
        }

        lesson.id = newID
        lesson.subjectId = subjectId
        lesson.path = nil
        lesson.updatedAt = Date().timeIntervalSince1970 * 1000
        var taken = Set<String>()
        let path = ensurePath(&lesson, subjects: subjects, taken: &taken)
        lesson.path = path

        let importedMedia = working.appendingPathComponent("media")
        lesson.cards = absolutizeMedia(lesson.cards, mediaFolder: importedMedia)
        lesson.thumb = resolvedCover(lesson, mediaFolder: importedMedia)
        writeBoard(lesson, to: working.appendingPathComponent("board.json"))
        do {
            try packArchive(from: working, to: projectsRoot.appendingPathComponent(path))
        } catch {
            try? fm.removeItem(at: working)
            return nil
        }
        lesson.bytes = folderBytes(working)
        return lesson
    }

    /// Renaming only moves the archive — the working copy is keyed by id and stays put,
    /// so media paths held in memory remain valid.
    static func renameLessonFolder(_ lesson: inout Lesson, subjects: [Subject], title: String) {
        let oldArchive = libraryFile(for: lesson, subjects: subjects)
        let previousPath = lesson.path
        lesson.title = title
        var taken = Set<String>()
        let newPath = uniquePath(
            subjectTitle: subjectTitle(lesson.subjectId, subjects),
            projectTitle: title,
            taken: &taken,
            reusing: previousPath
        )
        let dest = projectsRoot.appendingPathComponent(newPath)
        if oldArchive.standardizedFileURL.path != dest.standardizedFileURL.path {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: oldArchive.path) {
                try? fm.moveItem(at: oldArchive, to: dest)
            }
        }
        lesson.path = newPath
        let working = workingDirectory(forLessonID: lesson.id)
        lesson.cards = absolutizeMedia(lesson.cards, mediaFolder: working.appendingPathComponent("media"))
    }

    // MARK: - Private

    private static var fm: FileManager { .default }

    private static func loadIndex() -> LibraryIndex? {
        guard let data = try? Data(contentsOf: libraryIndexFile) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    private static func loadBoard(ref: LessonRef) -> Lesson? {
        // Materialise the working copy from the archive, then read the board out of it.
        let working = workingDirectory(forLessonID: ref.id)
        let file = working.appendingPathComponent("board.json")
        if !fm.fileExists(atPath: file.path) {
            let archive = projectsRoot.appendingPathComponent(ref.path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: archive.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    try? fm.createDirectory(at: workingRoot, withIntermediateDirectories: true)
                    try? fm.removeItem(at: working)
                    try? fm.copyItem(at: archive, to: working)
                } else {
                    try? unpackArchive(at: archive, into: working)
                }
            }
        }
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
        let media = file.deletingLastPathComponent().appendingPathComponent("media")
        lesson.cards = absolutizeMedia(lesson.cards, mediaFolder: media)
        if let refThumb = ref.thumb { lesson.thumb = refThumb }
        lesson.thumb = resolvedCover(lesson, mediaFolder: media)
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

    /// Sidebar cover for a lesson: the stored `thumb` resolved into this machine's media
    /// folder, or — when it is missing or points at a file that didn't survive the trip —
    /// the first media card on the board. Cards must already be absolutized.
    private static func resolvedCover(_ lesson: Lesson, mediaFolder: URL) -> String? {
        if let thumb = lesson.thumb, !thumb.isEmpty,
           let resolved = absolutize(thumb, mediaFolder: mediaFolder) {
            if resolved.hasPrefix("http://") || resolved.hasPrefix("https://") { return resolved }
            if let url = URL(string: resolved), fm.fileExists(atPath: url.path) { return resolved }
        }
        for card in lesson.cards {
            if card.kind == .image, let src = card.src, !src.isEmpty { return src }
            if card.kind == .video, let poster = card.poster, !poster.isEmpty { return poster }
        }
        return nil
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
                // Only ever consider things that look like projects, so an unrelated
                // file a user parked in the library folder is never trashed.
                guard projectURL.pathExtension.lowercased() == "vasa" else { continue }
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
    /// Working copies whose `.vasa` needs rebuilding once `files` have landed.
    var repack: [(working: URL, archive: URL)] = []
}

enum VasaDisk {
    nonisolated static func write(_ files: [(URL, Data)]) {
        for (url, data) in files {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

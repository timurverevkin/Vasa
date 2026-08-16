import Foundation

enum Photos {
    static let landscape = "https://images.unsplash.com/photo-1506905925346-21bda4d32df4?auto=format&fit=crop&w=1400&q=80"
    static let volcano = "https://images.unsplash.com/photo-1542253897-6ef5375aae36?auto=format&fit=crop&w=800&q=80"
    static let art = "https://images.unsplash.com/photo-1579783902614-a3fb3927b6a5?auto=format&fit=crop&w=800&q=80"
    static let japan = "https://images.unsplash.com/photo-1493976040374-85c8e12f0c0e?auto=format&fit=crop&w=800&q=80"
    static let faces = "https://images.unsplash.com/photo-1541963463532-d68292c34b19?auto=format&fit=crop&w=800&q=80"
    static let places = "https://images.unsplash.com/photo-1501785888041-af3ef285b470?auto=format&fit=crop&w=800&q=80"
    static let research = "https://images.unsplash.com/photo-1524995997946-a1c2e315a42f?auto=format&fit=crop&w=800&q=80"
    static let os = "https://images.unsplash.com/photo-1550745165-9bc0b252726f?auto=format&fit=crop&w=800&q=80"
}

enum DemoLibrary {
    static let peaks: [Double] = [
        0.16, 0.34, 0.22, 0.58, 0.4, 0.78, 0.36, 0.92, 0.62, 0.44, 0.7, 0.26, 0.52, 0.88, 0.42, 0.3, 0.64,
        0.2, 0.5, 0.76, 0.34, 0.6, 0.24, 0.82, 0.46, 0.28, 0.68, 0.18, 0.54, 0.4,
    ]

    static func make() -> Library {
        let studio = Subject(id: "sub_studio", title: "Studio", color: "#111111", order: 0)
        let now = Date().timeIntervalSince1970 * 1000
        let pacioli = "The Portrait of Luca Pacioli is a painting attributed to the Italian Renaissance artist Jacopo de' Barbari, dating from around 1495. It shows the mathematician with the tools of geometry — a study in how image, text and diagram share one surface."
        let noteDemo = "Text formatting! WOW\n\nAlso word and character counter\nHello!"

        func board(_ id: String, _ title: String, _ cards: [Card], thumb: String? = nil, camera: Camera = Camera(x: 40, y: 36, zoom: 1), bytes: Double = 12_000_000) -> Lesson {
            Lesson(
                id: id,
                subjectId: studio.id,
                title: title,
                cards: cards,
                camera: camera,
                updatedAt: now,
                pinned: nil,
                bytes: bytes,
                thumb: thumb
            )
        }

        let research = board("les_research", "Visual Research", [
            linkChip("vr_arc", 48, 40, "archive.org/details/usefulnessinsmal0000c…", "archive.org", "https://archive.org", "#FF3B30"),
            image("vr_1", 48, 140, 360, 240, 2, Photos.research, "Library"),
            note("vr_2", 430, 140, pacioli),
            note("vr_note", 430, 280, noteDemo),
            linkRich("vr_3", 48, 400, "Jacopo de' Barbari", "en.wikipedia.org", "https://en.wikipedia.org/wiki/Jacopo_de%27_Barbari", Photos.art),
        ], thumb: Photos.research)

        let audioColors = ["#FFCC00", "#34C759", "#AF52DE", "#FF3B30", "#00C7BE", "#007AFF"]
        let emaAudios: [Card] = audioColors.enumerated().map { i, color in
            let col = i % 3
            let row = i / 3
            return audio(
                "ema_a\(i)",
                80 + Double(col) * 184,
                56 + Double(row) * 184,
                168,
                168,
                i + 1,
                color,
                "SEIKO_3",
                "1:18"
            )
        }
        let emaProject = board("les_ema", "EMA Project", emaAudios + [
            text("ema_set", 80, 440, 180, 40, 10, "Settings", 28),
            text("ema_sup", 80, 484, 120, 32, 11, "Support", 22),
            text("ema_todo", 280, 440, 160, 32, 12, "To-Do:", 20),
        ], thumb: Photos.os)

        let faces = board("les_faces", "I don't See Faces", [
            image("fc_1", 80, 80, 400, 280, 1, Photos.faces, "Portrait"),
            note("fc_2", 500, 80, "Faces dissolve when you stop naming them. Collect the ones that refuse to resolve."),
        ], thumb: Photos.faces)

        let places = board("les_places", "Places & Photos", [
            image("pl_1", 80, 80, 480, 280, 1, Photos.places, "Valley"),
            image("pl_2", 80, 380, 240, 160, 2, Photos.landscape, "Ridge"),
            note("pl_3", 340, 380, "Places hold time the way a photograph holds light."),
        ], thumb: Photos.places)

        let timeResearch = board("les_time", "TIME Research", [
            text("tm_h", 80, 80, 280, 48, 1, "Settings!", 36),
            image("tm_1", 80, 160, 420, 240, 2, Photos.research, "Stacks"),
            note("tm_2", 520, 160, "Time as a material: duration, delay, loop, stretch."),
        ], thumb: Photos.research)

        let stretched = board("les_stretch", "Time Stretched", [
            image("ts_1", 80, 80, 360, 240, 1, Photos.volcano, "Duration"),
            audio("ts_2", 460, 80, 196, 196, 2, "#5856D6", "STRETCH_1", "4:02"),
            text("ts_3", 80, 340, 320, 40, 3, "Hold a moment until it thins.", 18),
        ], thumb: Photos.volcano)

        let japan = board("les_japan", "Japan 2026", [
            image("jp_1", 80, 80, 420, 260, 1, Photos.japan, "Kyoto"),
            note("jp_2", 80, 370, "Collect ukiyo-e references and Kyoto temple photos from the trip."),
        ], thumb: Photos.japan)

        let objects = board("les_objects", "Object types", [
            text("ob_1", 40, 24, 280, 40, 1, "Every object type", 28),
            image("ob_2", 40, 80, 280, 180, 2, Photos.volcano, "Volcano"),
            audio("ob_3", 340, 80, 196, 196, 3, "#34C759", "SEIKO_3", "1:18"),
            note("ob_4", 560, 80, pacioli),
            shortcut("ob_5", 40, 290, "Downloads", NSHomeDirectory() + "/Downloads"),
            youtube("ob_6", 220, 290, "dQw4w9WgXcQ", "YouTube"),
            video("ob_7", 660, 290, 176, 270, 7, Photos.art, "Texture"),
        ], thumb: Photos.volcano)

        let lessons = [research, emaProject, faces, places, timeResearch, stretched, japan, objects]
        return Library(
            rev: Format.libraryRev,
            subjects: [studio],
            lessons: lessons,
            openLessonIds: [research.id],
            activeLessonId: research.id,
            sidebarOpen: true
        )
    }

    static func text(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ z: Int, _ html: String, _ size: Double) -> Card {
        var c = base(id, .text, x, y, w, h, z)
        c.html = html
        c.fontSize = size
        return c
    }

    static func image(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ z: Int, _ src: String, _ alt: String) -> Card {
        var c = base(id, .image, x, y, w, h, z)
        c.src = src
        c.alt = alt
        return c
    }

    static func audio(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ z: Int, _ color: String, _ title: String, _ duration: String) -> Card {
        var c = base(id, .audio, x, y, w, h, z)
        c.color = color
        c.title = title
        c.duration = duration
        c.peaks = peaks
        c.src = ""
        return c
    }

    static func video(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ z: Int, _ poster: String, _ title: String) -> Card {
        var c = base(id, .video, x, y, w, h, z)
        c.poster = poster
        c.title = title
        return c
    }

    static func note(_ id: String, _ x: Double, _ y: Double, _ body: String) -> Card {
        var c = base(id, .note, x, y, Format.notePreview.width, Format.notePreview.height, 8)
        c.title = "Note"
        c.body = body
        if body.hasPrefix("Text formatting") {
            c.color = "#FF3B30"
            c.fontSize = 28
        }
        return c
    }

    static func shortcut(_ id: String, _ x: Double, _ y: Double, _ title: String, _ path: String) -> Card {
        var c = base(id, .shortcut, x, y, 148, 168, 7)
        c.title = title
        c.targetPath = path
        c.color = "#C6FF3A"
        return c
    }

    static func linkChip(_ id: String, _ x: Double, _ y: Double, _ title: String, _ host: String, _ url: String, _ color: String) -> Card {
        var c = base(id, .link, x, y, 268, 78, 2)
        c.title = title
        c.hostname = host
        c.url = url
        c.color = color
        c.style = .chip
        return c
    }

    static func linkRich(_ id: String, _ x: Double, _ y: Double, _ title: String, _ host: String, _ url: String, _ image: String) -> Card {
        var c = base(id, .link, x, y, 280, 220, 3)
        c.title = title
        c.hostname = host
        c.url = url
        c.image = image
        c.style = .rich
        return c
    }

    static func youtube(_ id: String, _ x: Double, _ y: Double, _ videoId: String, _ title: String) -> Card {
        var c = base(id, .youtube, x, y, 420, 236, 6)
        c.videoId = videoId
        c.title = title
        return c
    }

    static func base(_ id: String, _ kind: CardKind, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ z: Int) -> Card {
        Card(
            id: id, kind: kind, x: x, y: y, width: w, height: h, z: z,
            color: nil, hideVisual: nil, html: nil, fontSize: nil, title: nil, body: nil,
            src: nil, alt: nil, url: nil, hostname: nil, image: nil, style: nil,
            duration: nil, peaks: nil, poster: nil, targetPath: nil, icon: nil,
            missing: nil, points: nil, stroke: nil, videoId: nil, italic: nil, bold: nil
        )
    }
}

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
    static let desk = "https://images.unsplash.com/photo-1484480974693-6ca0a78fb36b?auto=format&fit=crop&w=1200&q=80"
    static let ink = "https://images.unsplash.com/photo-1455390582262-044cdead277a?auto=format&fit=crop&w=1000&q=80"
}

enum DemoLibrary {
    static let guideLessonID = "les_guide"

    static let peaks: [Double] = [
        0.16, 0.34, 0.22, 0.58, 0.4, 0.78, 0.36, 0.92, 0.62, 0.44, 0.7, 0.26, 0.52, 0.88, 0.42, 0.3, 0.64,
        0.2, 0.5, 0.76, 0.34, 0.6, 0.24, 0.82, 0.46, 0.28, 0.68, 0.18, 0.54, 0.4,
    ]

    static func make() -> Library {
        let studio = Subject(id: "sub_studio", title: "Studio", color: "#111111", order: 0)
        let now = Date().timeIntervalSince1970 * 1000
        let pacioli = "The Portrait of Luca Pacioli is a painting attributed to the Italian Renaissance artist Jacopo de' Barbari, dating from around 1495. It shows the mathematician with the tools of geometry — a study in how image, text and diagram share one surface."
        let noteDemo = "Text formatting! WOW\n\nAlso word and character counter\nHello!"

        func board(_ id: String, _ title: String, _ cards: [Card], thumb: String? = nil, camera: Camera = Camera(x: 40, y: 36, zoom: 1), bytes: Double = 12_000_000, pinned: Bool? = nil) -> Lesson {
            Lesson(
                id: id,
                subjectId: studio.id,
                title: title,
                cards: cards,
                camera: camera,
                updatedAt: now,
                pinned: pinned,
                bytes: bytes,
                thumb: thumb
            )
        }

        let guide = guideBoard(subjectId: studio.id, now: now)

        let research = board("les_research", "Visual Research", [
            linkChip("vr_arc", 48, 40, "archive.org/details/usefulnessinsmal0000c…", "archive.org", "https://archive.org", "#FF3B30"),
            image("vr_1", 48, 140, 360, 240, 2, Photos.research, "Library"),
            note("vr_2", 430, 140, pacioli),
            note("vr_note", 430, 280, noteDemo),
            linkRich("vr_3", 48, 400, "Jacopo de' Barbari", "en.wikipedia.org", "https://en.wikipedia.org/wiki/Jacopo_de%27_Barbari", Photos.art),
        ], thumb: Photos.research)

        let lessons = [guide, research]
        return Library(
            rev: Format.libraryRev,
            subjects: [studio],
            lessons: lessons,
            openLessonIds: [guide.id],
            activeLessonId: guide.id,
            sidebarOpen: true
        )
    }

    /// First-run board — calm spaced sections, every card kind, plain-language keys.
    static func guideBoard(subjectId: String, now: Double) -> Lesson {
        var z = 1
        func nextZ() -> Int { defer { z += 1 }; return z }

        // Left story column. Gaps ≥ 48 between blocks — nothing overlaps.
        let L: Double = 64
        let R: Double = 1080

        var cards: [Card] = [
            // —— Welcome ——
            text("g_brand", L, 56, 340, 88, nextZ(), "Vasa", 72, bold: true),
            text("g_sub", L, 148, 420, 36, nextZ(), "место для мыслей", 22, color: "#8A8F98"),
            note(
                "g_welcome",
                L,
                220,
                "Привет.\nСюда можно складывать фото, записи и ссылки — как на стол, а не в папку."
            ),

            // —— Photo ——
            text("g_h_photo", L, 400, 200, 32, nextZ(), "Фото", 20, bold: true),
            image("g_hero", L, 452, 480, 300, nextZ(), Photos.landscape, "Горы"),
            text("g_cap_img", L, 772, 400, 28, nextZ(), "Перетащи картинку сюда · или нажми F", 15, color: "#8A8F98"),

            // —— Sound ——
            text("g_h_audio", L, 860, 200, 32, nextZ(), "Звук", 20, bold: true),
            audio("g_a1", L, 912, 168, 168, nextZ(), "#FFCC00", "Утро", "0:42"),
            audio("g_a2", L + 192, 912, 168, 168, nextZ(), "#AF52DE", "Разговор", "2:11"),
            text("g_cap_audio", L, 1100, 360, 28, nextZ(), "Нажми, чтобы послушать", 15, color: "#8A8F98"),

            // —— Links (no overlap with photo) ——
            text("g_h_link", L, 1188, 200, 32, nextZ(), "Ссылки", 20, bold: true),
            linkRich(
                "g_rich",
                L,
                1240,
                "Страница с картинкой",
                "developer.apple.com",
                "https://developer.apple.com/design/",
                Photos.desk,
                "#007AFF"
            ),
            linkChip(
                "g_chip",
                L + 310,
                1240,
                "Просто адрес",
                "example.com",
                "https://example.com",
                "#FF9500"
            ),
            text("g_cap_link", L, 1480, 420, 28, nextZ(), "Вставь адрес — клавиша L", 15, color: "#8A8F98"),

            // —— Keys for making ——
            text("g_h_tools", L, 1568, 280, 32, nextZ(), "Как добавлять", 20, bold: true),
            text("g_t", L, 1628, 48, 40, nextZ(), "T", 28, bold: true),
            text("g_t_lab", L + 56, 1636, 140, 28, nextZ(), "текст", 16, color: "#8A8F98"),
            text("g_n", L + 220, 1628, 48, 40, nextZ(), "N", 28, bold: true),
            text("g_n_lab", L + 276, 1636, 140, 28, nextZ(), "заметка", 16, color: "#8A8F98"),
            text("g_l", L + 440, 1628, 48, 40, nextZ(), "L", 28, bold: true),
            text("g_l_lab", L + 496, 1636, 120, 28, nextZ(), "ссылка", 16, color: "#8A8F98"),
            text("g_p", L, 1696, 48, 40, nextZ(), "P", 28, bold: true),
            text("g_p_lab", L + 56, 1704, 140, 28, nextZ(), "рисунок", 16, color: "#8A8F98"),
            text("g_f", L + 220, 1696, 48, 40, nextZ(), "F", 28, bold: true),
            text("g_f_lab", L + 276, 1704, 160, 28, nextZ(), "файлы с диска", 16, color: "#8A8F98"),

            // —— Video & folders ——
            text("g_h_media", L, 1800, 280, 32, nextZ(), "Видео и папки", 20, bold: true),
            youtube("g_yt", L, 1852, "jNQXAC9IVRw", "Видео"),
            video("g_vid", L + 460, 1852, 220, 236, nextZ(), Photos.art, "Ролик"),
            folder("g_fold", L, 2120, "Документы", NSHomeDirectory() + "/Documents"),
            shortcut("g_short", L + 180, 2120, "Загрузки", NSHomeDirectory() + "/Downloads"),
            draw(
                "g_ink",
                L + 380,
                2140,
                [
                    DrawPoint(x: 12, y: 40),
                    DrawPoint(x: 48, y: 18),
                    DrawPoint(x: 92, y: 56),
                    DrawPoint(x: 140, y: 22),
                    DrawPoint(x: 188, y: 70),
                    DrawPoint(x: 220, y: 36),
                ],
                stroke: "#111318"
            ),
            text("g_cap_draw", L + 380, 2240, 240, 28, nextZ(), "P — просто порисуй", 15, color: "#8A8F98"),

            // —— Notes & writing ——
            text("g_h_write", L, 2340, 280, 32, nextZ(), "Текст и заметки", 20, bold: true),
            note(
                "g_note_fmt",
                L,
                2392,
                "Заметка открывается сбоку.\nМожно менять цвет и считать слова.\nДважды кликни, чтобы открыть."
            ),
            text(
                "g_list",
                L + 300,
                2392,
                340,
                160,
                nextZ(),
                "Выдели слова — появится панель.\nСписки и размер букв — там же.\nA — спросить ИИ про текст.",
                17
            ),
            image("g_ink_img", L + 680, 2392, 240, 160, nextZ(), Photos.ink, "Перо"),
            text("g_cap_lens", L + 680, 2572, 280, 28, nextZ(), "A на фото — поискать похожее", 15, color: "#8A8F98"),

            text(
                "g_close",
                L,
                2660,
                560,
                40,
                nextZ(),
                "Это твой стартовый лист. Меняй как хочешь.",
                18,
                color: "#8A8F98"
            ),

            // —— Keys column (right) ——
            text("g_keys", R, 56, 360, 48, nextZ(), "Клавиши", 36, bold: true),
            text("g_keys_sub", R, 112, 400, 28, nextZ(), "одни и те же на EN и RU", 14, color: "#8A8F98"),
            text("g_nav", R, 180, 220, 28, nextZ(), "ХОЛСТ", 12, bold: true, color: "#AF52DE"),
        ]

        // —— Group — a small moodboard cluster wrapped as one object ——
        let groupZ = nextZ()
        cards.append(text("g_h_group", L, 2740, 240, 32, nextZ(), "Группы", 20, bold: true))
        let moodPhotos = [Photos.faces, Photos.japan, Photos.art]
        let moodIDs = ["g_mood_1", "g_mood_2", "g_mood_3"]
        for (i, (id, src)) in zip(moodIDs, moodPhotos).enumerated() {
            var card = image(id, L + Double(i) * 118, 2792, 110, 190, nextZ(), src, "Кадр \(i + 1)")
            card.groupId = "g_moodgroup"
            cards.append(card)
        }
        var moodGroup = group("g_moodgroup", L - 24, 2736, 430, 310, title: "Настроение")
        moodGroup.z = groupZ
        cards.append(moodGroup)
        cards.append(text(
            "g_cap_group",
            L,
            3062,
            480,
            28,
            nextZ(),
            "⌘G — объединить выделенное в группу · клик берёт всё сразу",
            15,
            color: "#8A8F98"
        ))

        cards += keyRow("g_k_space", R, 220, "Space", "зажми и тяни — двигаешь холст")
        cards += keyRow("g_k_scroll", R, 280, "Scroll", "тоже двигает холст")
        cards += keyRow("g_k_pinch", R, 340, "⌘ + −", "ближе и дальше · ⌘0 сброс")
        cards += keyRow("g_k_nav", R, 400, "`", "маленькая карта")
        cards += keyRow("g_k_tab", R, 460, "Tab", "спрятать панели")
        cards += keyRow("g_k_side", R, 520, "⌘ \\", "боковое меню · ещё ⌘⌥S")
        cards += keyRow("g_k_search", R, 580, "⌘ K", "найти доску")

        cards.append(text("g_edit", R, 680, 220, 28, nextZ(), "ОБЪЕКТЫ", 12, bold: true, color: "#007AFF"))
        cards += keyRow("g_k_all", R, 720, "⌘ A", "выделить всё на доске")
        cards += keyRow("g_k_dup", R, 780, "⌘ D", "сделать копию")
        cards += keyRow("g_k_copy", R, 840, "⌘ C / V", "скопировать · вставить")
        cards += keyRow("g_k_del", R, 900, "Del", "удалить")
        cards += keyRow("g_k_layer", R, 960, "⌘ ] [", "выше · ниже")
        cards += keyRow("g_k_arrows", R, 1020, "← →", "сдвинуть · Shift — дальше")
        cards += keyRow("g_k_esc", R, 1080, "Esc", "закрыть лишнее")
        cards += keyRow("g_k_new", R, 1140, "⌘ ⇧ N", "новая доска")

        cards.append(text("g_set", R, 1240, 220, 28, nextZ(), "НАСТРОЙКИ", 12, bold: true, color: "#34C759"))
        cards += keyRow("g_k_theme", R, 1280, "⌘ T", "светлая / тёмная")
        cards += keyRow("g_k_sound", R, 1340, "⌘ M", "звуки")
        cards += keyRow("g_k_snap", R, 1400, "⌘ S", "прилипание к краям")
        cards += keyRow("g_k_shift", R, 1460, "Shift", "при перетаскивании — ровная линия")
        cards += keyRow("g_k_prev", R, 1520, "Space", "на фото — крупный просмотр")

        if let i = cards.firstIndex(where: { $0.id == "g_welcome" }) {
            cards[i].width = 360
            cards[i].height = 130
        }
        if let i = cards.firstIndex(where: { $0.id == "g_note_fmt" }) {
            cards[i].width = 280
            cards[i].height = 140
        }

        return Lesson(
            id: guideLessonID,
            subjectId: subjectId,
            title: "Старт",
            cards: cards,
            camera: Camera(x: 24, y: 12, zoom: 0.88),
            updatedAt: now,
            pinned: true,
            bytes: 8_500_000,
            thumb: Photos.landscape
        )
    }

    /// Ensure starter board exists; refresh layout/copy when the guide content changes.
    static func ensureGuide(in library: inout Library) -> Bool {
        let subjectId = library.subjects.first?.id
            ?? {
                let s = Subject(id: "sub_studio", title: "Studio", color: "#111111", order: 0)
                library.subjects.insert(s, at: 0)
                return s.id
            }()
        let fresh = guideBoard(subjectId: subjectId, now: Date().timeIntervalSince1970 * 1000)
        if let i = library.lessons.firstIndex(where: { $0.id == guideLessonID }) {
            let old = library.lessons[i]
            let same =
                old.cards.map(\.id) == fresh.cards.map(\.id)
                && old.cards.map(\.x) == fresh.cards.map(\.x)
                && old.cards.map(\.y) == fresh.cards.map(\.y)
            guard !same else { return false }
            var next = fresh
            next.path = old.path
            library.lessons[i] = next
            if !library.openLessonIds.contains(fresh.id) {
                library.openLessonIds.insert(fresh.id, at: 0)
            }
            library.activeLessonId = fresh.id
            return true
        }
        library.lessons.insert(fresh, at: 0)
        if !library.openLessonIds.contains(fresh.id) {
            library.openLessonIds.insert(fresh.id, at: 0)
        }
        library.activeLessonId = fresh.id
        return true
    }

    // MARK: - Factories

    static func text(
        _ id: String,
        _ x: Double,
        _ y: Double,
        _ w: Double,
        _ h: Double,
        _ z: Int,
        _ html: String,
        _ size: Double,
        bold: Bool? = nil,
        color: String? = nil
    ) -> Card {
        var c = base(id, .text, x, y, w, h, z)
        let escaped = html
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // Plain newlines → soft breaks so multi-line demo copy survives HTML import.
        let withBreaks = escaped.replacingOccurrences(of: "\n", with: "<br>")
        c.html = (bold == true) ? "<b>\(withBreaks)</b>" : withBreaks
        c.body = html
        c.fontSize = size
        c.bold = bold
        c.color = color
        return c
    }

    /// Keycap + label as two text cards (wall rhythm).
    private static func keyRow(_ id: String, _ x: Double, _ y: Double, _ key: String, _ label: String) -> [Card] {
        [
            text("\(id)_k", x, y, 118, 36, 20, key, 16, bold: true),
            text("\(id)_l", x + 128, y + 2, 300, 32, 20, label, 15, color: "#8A8F98"),
        ]
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

    static func folder(_ id: String, _ x: Double, _ y: Double, _ title: String, _ path: String) -> Card {
        var c = base(id, .folder, x, y, 148, 168, 7)
        c.title = title
        c.targetPath = path
        c.color = "#A8D8FF"
        return c
    }

    static func linkChip(_ id: String, _ x: Double, _ y: Double, _ title: String, _ host: String, _ url: String, _ color: String) -> Card {
        var c = base(id, .link, x, y, Format.linkChipSize.width, Format.linkChipSize.height, 2)
        c.title = title
        c.hostname = host
        c.url = url
        c.color = color
        c.style = .chip
        return c
    }

    static func linkRich(_ id: String, _ x: Double, _ y: Double, _ title: String, _ host: String, _ url: String, _ image: String, _ color: String = "#FF3B30") -> Card {
        var c = base(id, .link, x, y, Format.linkRichSize.width, Format.linkRichSize.height, 3)
        c.title = title
        c.hostname = host
        c.url = url
        c.image = image
        c.color = color
        c.style = .rich
        return c
    }

    static func youtube(_ id: String, _ x: Double, _ y: Double, _ videoId: String, _ title: String) -> Card {
        var c = base(id, .youtube, x, y, 420, 236, 6)
        c.videoId = videoId
        c.title = title
        return c
    }

    static func group(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, title: String = "Group") -> Card {
        var c = base(id, .group, x, y, w, h, 0)
        c.title = title
        return c
    }

    static func draw(_ id: String, _ x: Double, _ y: Double, _ points: [DrawPoint], stroke: String = "#111318") -> Card {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let maxX = xs.max() ?? 8
        let maxY = ys.max() ?? 8
        // Pad for stroke width so the path isn't clipped.
        let pad: Double = 10
        var c = base(id, .draw, x, y, max(24, maxX - minX + pad * 2), max(24, maxY - minY + pad * 2), 5)
        c.points = points.map { DrawPoint(x: $0.x - minX + pad, y: $0.y - minY + pad) }
        c.stroke = stroke
        c.strokes = [DrawStroke(points: c.points ?? [], color: stroke, width: 3)]
        return c
    }

    static func base(_ id: String, _ kind: CardKind, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ z: Int) -> Card {
        Card(
            id: id, kind: kind, x: x, y: y, width: w, height: h, z: z,
            color: nil, hideVisual: nil, html: nil, fontSize: nil, title: nil, body: nil,
            src: nil, alt: nil, url: nil, hostname: nil, image: nil, style: nil,
            duration: nil, peaks: nil, poster: nil, targetPath: nil, icon: nil,
            missing: nil, points: nil, stroke: nil, strokeWidth: nil, strokes: nil, videoId: nil, italic: nil, bold: nil,
            groupId: nil
        )
    }
}

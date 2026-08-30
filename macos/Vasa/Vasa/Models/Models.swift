import Foundation
import CoreGraphics

enum CardKind: String, Codable, CaseIterable {
    case text, note, image, link, audio, video, folder, shortcut, draw, youtube, group
}

enum Tool: String, Codable {
    case select, draw, link, text
}

enum DrawMode: String, Codable {
    case pen, eraser
}

enum LinkStyle: String, Codable {
    case chip, rich, embed
}

struct Camera: Codable, Hashable {
    var x: Double
    var y: Double
    var zoom: Double
}

struct TextWaveEvent: Equatable {
    var id: Int
    var x: Double
    var y: Double
    var width: Double = 34
    var height: Double = 34
    /// World-space corner radius of the card's real clip shape.
    var cornerRadius: Double = 8
    /// Multiplies how far the crest travels past the contour. Text blocks bloom a
    /// touch wider than ink; 1.0 is the distance measured off the ink reference.
    var spread: Double = 1
    /// Screen-space animation clock — frozen at creation so pan/zoom mid-wave doesn't restart it.
    var startedAt: Date = .now
}

/// Halftone dissolve when a card is deleted (seed → silhouette → SDF ring).
struct DeleteWaveEvent: Identifiable, Equatable {
    var id: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// World-space corner radius of the card’s real clip shape.
    var cornerRadius: Double
    var startedAt: Date = .now
}

/// Live alignment guide while dragging (Figma-style snap to other cards).
struct SnapGuide: Identifiable, Equatable {
    enum Axis: Equatable { case vertical, horizontal }
    /// Edge snaps draw solid; center snaps draw dashed; equal-gap snaps draw
    /// solid with capsule ticks marking each matched gap's boundaries.
    enum Style: Equatable { case solid, dashed, spacing }
    var axis: Axis
    var style: Style
    var position: Double
    var start: Double
    var end: Double
    /// Positions (along the guide's own axis) of the gap-boundary tick marks —
    /// only populated for `.spacing` guides.
    var ticks: [Double] = []

    var id: String { "\(axis)-\(style)-\(position)-\(start)-\(end)-\(ticks)" }
}

/// Live feedback while dragging cards into / out of a group.
struct GroupDragFeedback: Equatable {
    var movingIDs: Set<String>
    /// Card → group at drag start (only members whose parent is not also moving).
    var originGroupByCard: [String: String]
    /// Members currently outside their origin group (will leave on drop).
    var extractingIDs: Set<String> = []
    /// Group that would receive a card that is not already at home.
    var hoverGroupID: String?
}

struct DrawPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// One freehand polyline inside a `.draw` card (local coordinates).
struct DrawStroke: Codable, Hashable {
    var points: [DrawPoint]
    var color: String
    var width: Double
}

/// AI-derived metadata, filled in lazily by a background auto-tagging pass
/// (`AppModel.autoTagUntaggedCards`). Optional/back-compat: absent on cards
/// created before this feature and on any older `board.json`.
struct CardTags: Codable, Hashable, Equatable {
    /// Topic/theme, e.g. "biology", "history essay", "recipe".
    var theme: String?
    /// Coarser bucket, e.g. "school", "personal", "reference".
    var subject: String?
    /// AI-perceived dominant visual tone, e.g. "warm", "blue", "monochrome" —
    /// distinct from `Card.color`, which is a user-chosen accent hex.
    var colorTag: String?
    var updatedAt: Double?
}

struct Card: Identifiable, Codable, Hashable {
    var id: String
    var kind: CardKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var z: Int
    var color: String?
    var hideVisual: Bool?

    var html: String?
    var fontSize: Double?
    var title: String?
    var body: String?
    var src: String?
    var alt: String?
    var url: String?
    var hostname: String?
    var image: String?
    var style: LinkStyle?
    var duration: String?
    var peaks: [Double]?
    var poster: String?
    var targetPath: String?
    var icon: String?
    var missing: Bool?
    /// Legacy single-stroke path — prefer `strokes` for new ink.
    var points: [DrawPoint]?
    var stroke: String?
    /// Pen width in world points for `.draw` cards (default 3).
    var strokeWidth: Double?
    /// Multi-stroke ink (pen lifts / color changes stay on one card).
    var strokes: [DrawStroke]?
    var videoId: String?
    var italic: Bool?
    var bold: Bool?
    /// Parent group card, if this object sits inside a group plaque.
    var groupId: String?
    /// AI-derived theme/subject/color metadata — filled in lazily, see `CardTags`.
    var tags: CardTags?

    var frame: CGRect {
        CGRect(x: x, y: y, width: previewWidth, height: previewHeight)
    }

    /// Extra world-space grab margin for ink cards: a straight stroke's bounds are only
    /// a few points tall, which makes the card near-impossible to hit with the pointer.
    static let inkGrabPad: CGFloat = 10

    /// Frame used for pointer hit-testing — same as `frame` except ink cards, which get
    /// a grab margin so thin strokes stay selectable and draggable.
    var hitFrame: CGRect {
        kind == .draw ? frame.insetBy(dx: -Card.inkGrabPad, dy: -Card.inkGrabPad) : frame
    }

    var displayTitle: String {
        title ?? alt ?? hostname ?? kind.rawValue
    }

    /// Flattened text used by the search palette — title/body/link fields, HTML stripped.
    /// Cheap by design: no HTML parser for note/text bodies, just enough to match a query.
    var searchText: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let alt, !alt.isEmpty { parts.append(alt) }
        if let body, !body.isEmpty { parts.append(body) }
        if let html, !html.isEmpty {
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            if !stripped.isEmpty { parts.append(stripped) }
        }
        if let hostname, !hostname.isEmpty { parts.append(hostname) }
        if let url, !url.isEmpty { parts.append(url) }
        if let targetPath, !targetPath.isEmpty { parts.append(targetPath) }
        return parts.joined(separator: " ")
    }

    var previewWidth: Double {
        kind == .note ? min(420, max(220, width)) : width
    }

    var previewHeight: Double {
        kind == .note ? min(148, max(100, height)) : height
    }

    /// Corner radius of the visible clip shape (matches CardView chrome / content clips).
    var dissolveCornerRadius: Double {
        let w = previewWidth
        let h = previewHeight
        let base: Double = {
            switch kind {
            case .text: return 8
            case .link: return showsRichLink ? Double(Format.cardBorderedRadius) : Double(Format.cardRadius)
            case .draw: return 0
            case .group: return Double(Format.groupRadius)
            default: return Double(Format.cardRadius)
            }
        }()
        // Capsule / near-square circle: radius clamps to half the short side.
        return min(base, min(w, h) / 2)
    }

    /// World-space box used for alignment snap (every card kind).
    var snapFrame: CGRect { frame }

    var showsRichLink: Bool {
        // Empty `image` still counts — optimistic paste shows a gray stub while OG loads.
        kind == .link && image != nil && hideVisual != true && (style == .rich || style == nil)
    }

    /// Compact URL line for link chips / footers (no scheme).
    var linkSubtitle: String {
        if let hostname, !hostname.isEmpty {
            if let url, let path = URL(string: url)?.path, path.count > 1 {
                let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                if !trimmed.isEmpty, trimmed != "/" {
                    return "\(hostname)\(trimmed)"
                }
            }
            return hostname
        }
        guard let url else { return "" }
        return url
            .replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
    }

    /// Resolved ink paths — prefers `strokes`, falls back to legacy `points`.
    var inkStrokes: [DrawStroke] {
        if let strokes, !strokes.isEmpty { return strokes }
        if let points, !points.isEmpty {
            return [DrawStroke(points: points, color: stroke ?? "#111318", width: strokeWidth ?? 3)]
        }
        return []
    }

    /// Write multi-stroke ink and keep legacy fields mirrored for older readers.
    mutating func setInkStrokes(_ strokes: [DrawStroke]) {
        self.strokes = strokes.isEmpty ? nil : strokes
        if let first = strokes.first {
            points = first.points
            stroke = first.color
            strokeWidth = first.width
        } else {
            points = nil
            stroke = nil
            strokeWidth = nil
        }
    }
}

struct Lesson: Identifiable, Codable, Hashable {
    var id: String
    var subjectId: String
    var title: String
    var cards: [Card]
    var camera: Camera
    var updatedAt: Double
    var pinned: Bool?
    var bytes: Double?
    var thumb: String?
    /// Relative folder under the projects library, e.g. `Studio/Visual Research`.
    var path: String? = nil

    /// Image sources on the board, in card order — video cards contribute their poster.
    /// Used by the sidebar cover to step through the board's media.
    var mediaSources: [String] {
        cards.compactMap { card in
            switch card.kind {
            case .image: return card.src.flatMap { $0.isEmpty ? nil : $0 }
            case .video: return card.poster.flatMap { $0.isEmpty ? nil : $0 }
            default: return nil
            }
        }
    }
}

struct Subject: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var color: String
    var order: Int
}

struct Library: Codable, Hashable {
    var rev: Int?
    var subjects: [Subject]
    var lessons: [Lesson]
    var openLessonIds: [String]
    var activeLessonId: String?
    var sidebarOpen: Bool
}

enum VasaID {
    nonisolated static func make(_ prefix: String = "id") -> String {
        let rand = String(UUID().uuidString.prefix(8)).lowercased()
        return "\(prefix)_\(rand)"
    }
}

enum FileKind {
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "bmp"]
    static let audio: Set<String> = ["mp3", "wav", "m4a", "aac", "ogg", "flac", "aiff"]
    static let video: Set<String> = ["mp4", "mov", "webm", "m4v", "avi"]

    static func ext(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}

enum Format {
    static let notePreview = CGSize(width: 248, height: 108)
    static let notePanelWidth: CGFloat = 420
    static let notePanelTrailing: CGFloat = 12
    static let notePanelVertical: CGFloat = 10
    static var notePanelOuterWidth: CGFloat { notePanelWidth + notePanelTrailing }
    static let cardRadius: CGFloat = 16
    static let cardBorderedRadius: CGFloat = 12
    /// Link without preview image (or visual hidden).
    static let linkChipSize = CGSize(width: 268, height: 78)
    /// Link with Open Graph image preview.
    static let linkRichSize = CGSize(width: 280, height: 220)
    static let groupEmptySize = CGSize(width: 440, height: 300)
    static let groupRadius: CGFloat = 22
    static let groupPadX: Double = 48
    static let groupPadTop: Double = 56
    /// Hysteresis margin (world points) beyond a group's frame a member already inside it
    /// may drift before being treated as having left — keeps a brief graze past the edge
    /// (the plaque itself resizing, a jittery drop) from silently detaching it.
    static let groupStayMargin: Double = 24
    static let groupPadBottom: Double = 44
    static let groupMinWrap = CGSize(width: 240, height: 180)
    static let textLimit = 50_000
    /// Readable wrap width for pasted / multi-line canvas text (points).
    static let textWrapWidth: Double = 480
    static let libraryRev = 10

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    static func parseDuration(_ text: String?) -> Double {
        guard let text, !text.isEmpty else { return 0 }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return 0
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func relativeTime(_ ts: Double) -> String {
        let diff = Date().timeIntervalSince1970 * 1000 - ts
        let min = Int((diff / 60_000).rounded())
        if min < 1 { return "just now" }
        if min < 60 { return "\(min) min ago" }
        let h = Int((Double(min) / 60).rounded())
        if h < 24 { return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = Int((Double(h) / 24).rounded())
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    static func bytes(_ n: Double?) -> String {
        guard let n, n > 0 else { return "1 MB" }
        if n < 1_048_576 { return "\(max(1, Int((n / 1024).rounded()))) KB" }
        return "\(Int((n / 1_048_576).rounded())) MB"
    }

    static func youtubeID(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host()?.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "") else {
            return nil
        }
        if host == "youtu.be" {
            return url.path.split(separator: "/").first.map(String.init)
        }
        if host.contains("youtube") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
            {
                return v
            }
            let parts = url.path.split(separator: "/").map(String.init)
            if let first = parts.first, ["shorts", "embed", "live"].contains(first) {
                return parts.dropFirst().first
            }
        }
        return nil
    }

    static func clamp(_ n: Double, _ a: Double, _ b: Double) -> Double {
        min(b, max(a, n))
    }
}

struct MenuAnchor: Equatable {
    var x: Double
    var y: Double
    var cardID: String?
    /// Window content-view size captured at the moment of the click — the
    /// same measurement `x`/`y` are expressed in. `ItemMenuOverlay` clamps
    /// against this directly instead of its own separately-measured
    /// GeometryReader, so the click point and the clamp bounds can never
    /// drift out of sync with each other.
    var containerSize: CGSize
}

struct LightboxItem: Equatable {
    var src: String
    var alt: String?
    var bytes: Double?
    /// Raw `Card.src` for a video — when set, the lightbox plays the video instead of
    /// showing `src` (the poster) as a static image.
    var videoSrc: String?
}

struct TextAskSource: Identifiable, Equatable {
    var id: String
    var snippet: String
    var links: [String]
    var plain: String
}

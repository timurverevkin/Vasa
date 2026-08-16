import Foundation
import CoreGraphics

enum CardKind: String, Codable, CaseIterable {
    case text, note, image, link, audio, video, folder, shortcut, draw, youtube
}

enum Tool: String, Codable {
    case select, draw, link, text
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
}

struct DrawPoint: Codable, Hashable {
    var x: Double
    var y: Double
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
    var points: [DrawPoint]?
    var stroke: String?
    var videoId: String?
    var italic: Bool?
    var bold: Bool?

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var displayTitle: String {
        title ?? alt ?? hostname ?? kind.rawValue
    }

    var previewWidth: Double {
        kind == .note ? min(420, max(220, width)) : width
    }

    var previewHeight: Double {
        kind == .note ? min(148, max(100, height)) : height
    }

    var showsRichLink: Bool {
        kind == .link && style == .rich && image != nil && hideVisual != true
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

enum NexusID {
    static func make(_ prefix: String = "id") -> String {
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
    static let textLimit = 256
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
}

struct LightboxItem: Equatable {
    var src: String
    var alt: String?
    var bytes: Double?
}

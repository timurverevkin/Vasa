import Foundation

/// Small in-memory ring buffer of recent AI-provider network activity (request URL/status, raw
/// SSE events, parse failures), so a request can be diagnosed directly in `ProviderSettingsPanel`
/// without needing Console.app or `log show` access. Also mirrored to the unified log (see
/// `BaseAPIHandler`) for anyone who *does* have log access.
@MainActor
@Observable
final class AIChatDebugLog {
    static let shared = AIChatDebugLog()
    private init() {}

    private(set) var lines: [String] = []
    private let maxLines = 300
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ line: String) {
        lines.append("\(Self.stamp.string(from: Date())) \(line)")
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() {
        lines.removeAll()
    }
}

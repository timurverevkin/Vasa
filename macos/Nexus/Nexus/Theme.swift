import AppKit
import SwiftUI

enum Theme {
    static let canvas = Color(red: 244 / 255, green: 245 / 255, blue: 247 / 255)
    static let dot = Color(red: 213 / 255, green: 215 / 255, blue: 220 / 255)
    static let ink = Color(red: 17 / 255, green: 19 / 255, blue: 24 / 255)
    static let muted = Color(red: 138 / 255, green: 143 / 255, blue: 152 / 255)
    static let line = Color(red: 236 / 255, green: 236 / 255, blue: 238 / 255)
    static let selectStroke = Color(red: 157 / 255, green: 165 / 255, blue: 180 / 255)
    static let hover = Color(red: 232 / 255, green: 232 / 255, blue: 235 / 255)
    static let surface = Color.white
    static let select = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    static let selection = Color(red: 76 / 255, green: 139 / 255, blue: 245 / 255)
    static let lime = Color(red: 198 / 255, green: 255 / 255, blue: 58 / 255)
    static let chromeBorder = Color.black.opacity(0.06)

    static let itemColors: [String] = [
        "#1D1D1F", "#8E8E93", "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#30D158", "#64D2FF", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55",
    ]

    static func color(_ hex: String?) -> Color {
        guard let hex else { return ink }
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return ink }
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    static func onFill(_ hex: String?) -> Color {
        guard let hex else { return ink }
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return ink }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.62 ? ink : .white
    }

    static func canvasColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.145) : canvas
    }

    static func fileBytes(_ src: String) -> Double? {
        let path: String
        if src.hasPrefix("file:"), let url = URL(string: src) {
            path = url.path
        } else if src.hasPrefix("http") {
            return nil
        } else {
            path = src
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else { return nil }
        return size.doubleValue
    }
}

enum FieldEditor {
    static func silenceSystemTextUI() {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.allowsCharacterPickerTouchBarItem = false
        if #available(macOS 15.0, *) {
            view.writingToolsBehavior = .none
        }
        view.menu = nil
    }
}

struct ChromePill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        let fill = scheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.94)
            : Color.white.opacity(0.94)
        let stroke = scheme == .dark ? Color.white.opacity(0.08) : Theme.chromeBorder
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.08), radius: 8, y: 2)
    }
}

extension View {
    func chromePill(_ radius: CGFloat = 10) -> some View {
        modifier(ChromePill(radius: radius))
    }
}

extension Color {
    static let nexusCanvas = Theme.canvas
    static let nexusInk = Theme.ink
    static let nexusMuted = Theme.muted
}

extension NSColor {
    var nexusHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#111318" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

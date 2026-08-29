import AppKit
import SwiftUI

enum Theme {
    static let canvas = Color(red: 244 / 255, green: 245 / 255, blue: 247 / 255)
    static let dot = Color(red: 213 / 255, green: 215 / 255, blue: 220 / 255)
    static let ink = Color(red: 17 / 255, green: 19 / 255, blue: 24 / 255)
    static let muted = Color(red: 138 / 255, green: 143 / 255, blue: 152 / 255)
    static let line = Color(red: 236 / 255, green: 236 / 255, blue: 238 / 255)
    static let selectStroke = Color(red: 157 / 255, green: 165 / 255, blue: 180 / 255)
    /// Darker tick at the selection resize notch (bottom-trailing serif).
    static let selectNotch = Color(red: 88 / 255, green: 94 / 255, blue: 106 / 255)
    static let hover = Color(red: 232 / 255, green: 232 / 255, blue: 235 / 255)
    /// One step darker than `hover` — for a control hovered on top of an already-hovered row,
    /// where `hover`-on-`hover` would read as no hover at all.
    static let strongHover = Color(red: 216 / 255, green: 217 / 255, blue: 221 / 255)
    static let surface = Color.white
    static let select = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    static let selection = Color(red: 76 / 255, green: 139 / 255, blue: 245 / 255)
    static let snapGuide = Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255)
    /// Extract-from-group stroke — same red as destructive menu rows.
    static let extractStroke = Color(red: 1, green: 0.23, blue: 0.19)
    static let lime = Color(red: 198 / 255, green: 255 / 255, blue: 58 / 255)
    static let chromeBorder = Color.black.opacity(0.06)

    static let itemColors: [String] = [
        "#1D1D1F", "#8E8E93", "#FF3B30", "#FF9500", "#FFCC00", "#FF1464",
        "#30D158", "#64D2FF", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55",
    ]

    // MARK: - Appearance-aware tokens (cards, notes, chrome)

    static func cardSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.18, green: 0.18, blue: 0.20) : surface
    }

    static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.93, green: 0.93, blue: 0.95) : ink
    }

    static func secondaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.58, green: 0.59, blue: 0.63) : muted
    }

    /// The "selected/primary" pill fill — `select` sits at ~0.17 luminance, nearly the same
    /// as the dark chrome panel background (~0.16-0.18), so the selected segment of a
    /// picker becomes indistinguishable from its unselected siblings in dark mode unless
    /// this branches to something visibly lighter than the panel.
    static func selectFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.22) : select
    }

    static func elevHover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : hover
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : line
    }

    static func groupFill(_ scheme: ColorScheme, tint hex: String? = nil) -> Color {
        let base = scheme == .dark
            ? Color(red: 0.22, green: 0.22, blue: 0.24)
            : Color(red: 230 / 255, green: 231 / 255, blue: 235 / 255)
        guard let hex else { return base }
        return color(hex)
    }

    static func groupTitle(_ scheme: ColorScheme, tint hex: String? = nil) -> Color {
        guard let hex else { return secondaryInk(scheme) }
        return onFill(hex)
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color(red: 0.90, green: 0.91, blue: 0.92)
    }

    static func selectionStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.58, green: 0.61, blue: 0.68) : selectStroke
    }

    static func selectionNotch(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.78, green: 0.80, blue: 0.86) : selectNotch
    }

    /// Default canvas/note text hex when the card has no custom color.
    static func defaultInkHex(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "#EDEEF0" : "#111318"
    }

    static func defaultInkNSColor(_ scheme: ColorScheme) -> NSColor {
        NSColor.vasa(hex: defaultInkHex(scheme))
    }

    /// True when `color` reads as plain body text — near-black or near-white — rather
    /// than a colour the user deliberately picked, and so must follow the current
    /// appearance instead of being preserved.
    ///
    /// Deliberately measured, not matched against a list of known ink hexes: Cocoa's
    /// HTML serializer converts colour spaces, so text saved as `#111318` comes back
    /// as `#0E0F13` and an exact-match test silently stops firing — which left text
    /// typed in one appearance unreadable in the other.
    ///
    /// The saturation guard keeps genuinely dark *colours* (a navy, say) intact; only
    /// near-neutral extremes adapt. Thresholds verified against `itemColors`: the
    /// darkest saturated swatch sits at luminance 0.14, and mid-grey `#8E8E93` at 0.27.
    static func isAdaptiveInk(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        guard rgb.saturationComponent < 0.45 else { return false }
        return luminance < 0.05 || luminance > 0.75
    }

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
    /// Fully opaque fill instead of the default translucent chrome — for panels that
    /// sit over busy canvas content and need to read as solid, not see-through.
    var opaque: Bool = false
    func body(content: Content) -> some View {
        let opacity: CGFloat = opaque ? 1 : 0.94
        let fill = scheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.18).opacity(opacity)
            : Color.white.opacity(opacity)
        let stroke = scheme == .dark ? Color.white.opacity(0.08) : Theme.chromeBorder
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.08), radius: 8, y: 2)
    }
}

extension View {
    func chromePill(_ radius: CGFloat = 10, opaque: Bool = false) -> some View {
        modifier(ChromePill(radius: radius, opaque: opaque))
    }
}

extension Color {
    static let vasaCanvas = Theme.canvas
    static let vasaInk = Theme.ink
    static let vasaMuted = Theme.muted
}

extension NSColor {
    /// Calibrated sRGB from `#RGB` / `#RRGGBB` (SwiftUI `Color` bridging is unreliable in NSTextView).
    static func vasa(hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6, let v = UInt64(h, radix: 16) else {
            return NSColor.labelColor
        }
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var vasaHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#111318" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

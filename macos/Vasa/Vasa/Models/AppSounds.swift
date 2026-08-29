import AppKit
import Foundation

/// UI sound pack (`Vasa/Sounds/*.wav`). Gated by `AppSettings.sounds`.
@MainActor
enum AppSounds {
    /// Bound from `AppModel` so plays respect the App Sounds toggle.
    static var isEnabled: () -> Bool = { true }

    enum Kind: String {
        case button
        case caution
        case celebration
        case disabled
        case notification
        case select
        case toggleOn = "toggle_on"
        case toggleOff = "toggle_off"
        case transitionUp = "transition_up"
        case transitionDown = "transition_down"
        case pasteBlock = "paste_block"
        case hover
    }

    private static var cache: [String: NSSound] = [:]
    private static var uiTapIndex = 0
    private static var typeIndex = 0
    private static var swipeIndex = 0

    static func play(_ kind: Kind) {
        playFile(kind.rawValue)
    }

    /// Canvas selection — always `tap`.
    static func playCanvasTap() {
        playFile("tap")
    }

    /// Settings, menus, chrome buttons — `tap_01`, `tap_03`…`tap_05`.
    static func playTap() {
        let variants = [1, 3, 4, 5]
        uiTapIndex = (uiTapIndex + 1) % variants.count
        playFile(String(format: "tap_%02d", variants[uiTapIndex]))
    }

    static func playType() {
        typeIndex = (typeIndex + 1) % 5
        playFile(String(format: "type_%02d", typeIndex + 1))
    }

    static func playSwipe() {
        swipeIndex = (swipeIndex + 1) % 5
        playFile(String(format: "swipe_%02d", swipeIndex + 1))
    }

    static func playToggle(_ on: Bool) {
        play(on ? .toggleOn : .toggleOff)
    }

    private static func playFile(_ name: String) {
        guard isEnabled() else { return }
        let sound: NSSound? = {
            if let cached = cache[name] { return cached.copy() as? NSSound ?? cached }
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
                    ?? Bundle.main.url(forResource: name, withExtension: "wav"),
                  let loaded = NSSound(contentsOf: url, byReference: true)
            else { return nil }
            cache[name] = loaded
            return loaded.copy() as? NSSound ?? loaded
        }()
        sound?.play()
    }
}

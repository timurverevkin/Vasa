import AppKit
import Foundation
import SwiftUI

struct AppSettings: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable {
        case light, dark, auto
        var colorScheme: ColorScheme? {
            switch self {
            case .light: .light
            case .dark: .dark
            case .auto: nil
            }
        }
    }

    var appearance: Appearance = .light
    var sounds = true
    var haptics = true
    var showChrome = true
    var showGrid = true
    var snapping = true
    var projectsFolder: String = AppSettings.defaultFolder

    static var defaultFolder: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EMA Library").path
    }

    static var file: URL {
        Persistence.folder.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: AppSettings.file, options: [.atomic])
    }
}

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
    /// GigaTool DeepSeek proxy base, e.g. `https://gw.gigatool.app/deepseek`. Kept for back-compat
    /// migration into `aiProviders`'s deepseek entry — see `AppSettings.load()`.
    var deepseekBaseURL: String = DeepSeekProvider.defaultBaseURL
    var aiProviders: [AIProviderConfig] = ProviderCatalog.defaults
    var activeProviderId: String = "giga"

    enum CodingKeys: String, CodingKey {
        case appearance, sounds, haptics, showChrome, showGrid, snapping, projectsFolder, deepseekBaseURL
        case aiProviders, activeProviderId
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .light
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? true
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        showChrome = try c.decodeIfPresent(Bool.self, forKey: .showChrome) ?? true
        showGrid = try c.decodeIfPresent(Bool.self, forKey: .showGrid) ?? true
        snapping = try c.decodeIfPresent(Bool.self, forKey: .snapping) ?? true
        projectsFolder = try c.decodeIfPresent(String.self, forKey: .projectsFolder) ?? AppSettings.defaultFolder
        deepseekBaseURL = try c.decodeIfPresent(String.self, forKey: .deepseekBaseURL) ?? DeepSeekProvider.defaultBaseURL
        aiProviders = try c.decodeIfPresent([AIProviderConfig].self, forKey: .aiProviders) ?? ProviderCatalog.defaults
        activeProviderId = try c.decodeIfPresent(String.self, forKey: .activeProviderId) ?? "giga"
    }

    static var defaultFolder: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vasa Library").path
    }

    static var file: URL {
        Persistence.folder.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: file),
              var decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        // Migrate a user-customized deepseekBaseURL into the new provider list's "giga" entry
        // (the old single hardcoded provider was the GigaTool gateway), if that entry still
        // holds the default (i.e. the user hasn't already edited it there).
        if decoded.deepseekBaseURL != DeepSeekProvider.defaultBaseURL,
           let idx = decoded.aiProviders.firstIndex(where: { $0.id == "giga" }),
           decoded.aiProviders[idx].baseURL == DeepSeekProvider.defaultBaseURL {
            decoded.aiProviders[idx].baseURL = decoded.deepseekBaseURL
        }
        // Ensure any settings.json written by the old build (before "giga"/new "deepseek"
        // ids existed) picks up the new full catalog rather than a stale 3-entry list.
        for preset in ProviderCatalog.defaults where !decoded.aiProviders.contains(where: { $0.id == preset.id }) {
            decoded.aiProviders.append(preset)
        }
        // An older build's "deepseek" entry WAS the GigaTool gateway. Snap any leftover
        // entry still pointing at that gateway (or still labeled "(gateway)") back to the
        // real DeepSeek API preset — the gateway now lives solely under "giga".
        if let idx = decoded.aiProviders.firstIndex(where: { $0.id == "deepseek" }),
           let deepseekPreset = ProviderCatalog.defaults.first(where: { $0.id == "deepseek" }),
           decoded.aiProviders[idx].baseURL == DeepSeekProvider.defaultBaseURL
            || decoded.aiProviders[idx].displayName.contains("gateway") {
            decoded.aiProviders[idx] = deepseekPreset
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: AppSettings.file, options: [.atomic])
    }
}

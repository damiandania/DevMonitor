import Foundation
import AppKit

/// App-wide settings (the gear at the bottom of the sidebar). Persisted under Application Support.
struct AppSettings: Codable, Sendable, Equatable {
    /// App display name of the browser used by "Open" (e.g. "Google Chrome"); nil = system default.
    var browser: String?
    /// Claude model used for Diagnose, the Resource Advisor, and pressure auto-analysis.
    var analysisModel: String
    /// Auto-close orphaned dev processes when the machine is under pressure.
    var autoCloseOrphans: Bool
    /// Heap (GB) applied to new projects whose framework has no specific default.
    var defaultMemoryGB: Int

    init(browser: String? = nil,
         analysisModel: String = AppSettings.defaultModel,
         autoCloseOrphans: Bool = true,
         defaultMemoryGB: Int = 4) {
        self.browser = browser
        self.analysisModel = analysisModel
        self.autoCloseOrphans = autoCloseOrphans
        self.defaultMemoryGB = defaultMemoryGB
    }

    // Tolerant decode so older settings.json (missing keys) still loads.
    enum CodingKeys: String, CodingKey { case browser, analysisModel, autoCloseOrphans, defaultMemoryGB }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        analysisModel = try c.decodeIfPresent(String.self, forKey: .analysisModel) ?? AppSettings.defaultModel
        autoCloseOrphans = try c.decodeIfPresent(Bool.self, forKey: .autoCloseOrphans) ?? true
        defaultMemoryGB = try c.decodeIfPresent(Int.self, forKey: .defaultMemoryGB) ?? 4
    }

    static let defaultModel = "claude-haiku-4-5"

    /// Models offered for analysis (newest Claude family).
    struct ModelOption: Identifiable, Sendable { let id: String; let label: String }
    static let models: [ModelOption] = [
        .init(id: "claude-haiku-4-5", label: "Haiku 4.5 — fast (default)"),
        .init(id: "claude-sonnet-4-6", label: "Sonnet 4.6 — balanced"),
        .init(id: "claude-opus-4-8", label: "Opus 4.8 — deep"),
    ]
}

/// Loads and saves `AppSettings` as JSON under Application Support.
@MainActor
final class SettingsStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("settings.json")
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Browsers installed on this Mac (apps that can open http), by display name.
enum BrowserList {
    @MainActor static func installed() -> [String] {
        guard let url = URL(string: "https://example.com") else { return [] }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var names: [String] = []
        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: "")
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }
}

import Foundation
import AppKit

/// App-wide settings (the gear at the bottom of the sidebar). Persisted under Application Support.
struct AppSettings: Codable, Sendable, Equatable {
    /// App display name of the browser used by "Open" (e.g. "Google Chrome"); nil = system default.
    var browser: String?
    /// App display name of the editor used by "Code" (e.g. "Cursor"); nil = VS Code / first found.
    var editor: String?
    /// Claude model used for Diagnose, the Resource Advisor, and pressure auto-analysis.
    var analysisModel: String
    /// Auto-close orphaned dev processes when the machine is under pressure.
    var autoCloseOrphans: Bool
    /// Heap (GB) applied to new projects whose framework has no specific default.
    var defaultMemoryGB: Int
    /// Which activity bars to show on the dashboard (ids from `allBars`).
    var bars: [String]
    /// UI appearance: "system" (follow macOS), "light", or "dark".
    var theme: String

    init(browser: String? = nil,
         editor: String? = nil,
         analysisModel: String = AppSettings.defaultModel,
         autoCloseOrphans: Bool = true,
         defaultMemoryGB: Int = 4,
         bars: [String] = AppSettings.defaultBars,
         theme: String = "system") {
        self.browser = browser
        self.editor = editor
        self.analysisModel = analysisModel
        self.autoCloseOrphans = autoCloseOrphans
        self.defaultMemoryGB = defaultMemoryGB
        self.bars = bars
        self.theme = theme
    }

    // Tolerant decode so older settings.json (missing keys) still loads.
    enum CodingKeys: String, CodingKey {
        case browser, editor, analysisModel, autoCloseOrphans, defaultMemoryGB, bars, theme
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
        editor = try c.decodeIfPresent(String.self, forKey: .editor)
        analysisModel = try c.decodeIfPresent(String.self, forKey: .analysisModel) ?? AppSettings.defaultModel
        autoCloseOrphans = try c.decodeIfPresent(Bool.self, forKey: .autoCloseOrphans) ?? true
        defaultMemoryGB = try c.decodeIfPresent(Int.self, forKey: .defaultMemoryGB) ?? 4
        bars = try c.decodeIfPresent([String].self, forKey: .bars) ?? AppSettings.defaultBars
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
    }

    static let defaultModel = "claude-haiku-4-5"

    /// Appearance options for the theme picker.
    struct ThemeOption: Identifiable, Sendable { let id: String; let label: String }
    static let themes: [ThemeOption] = [
        .init(id: "system", label: "System"),
        .init(id: "light", label: "Light"),
        .init(id: "dark", label: "Dark"),
    ]

    /// Apply a theme to the whole app (all windows, modals and the menu-bar panel).
    /// Uses `NSApplication.shared` (never nil) — `NSApp` is still nil during SwiftUI `App.init`.
    @MainActor static func applyAppearance(_ theme: String) {
        let appearance: NSAppearance? = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark":  NSAppearance(named: .darkAqua)
        default:      nil   // follow the system setting
        }
        NSApplication.shared.appearance = appearance
    }

    /// Models offered for analysis (newest Claude family).
    struct ModelOption: Identifiable, Sendable { let id: String; let label: String }
    static let models: [ModelOption] = [
        .init(id: "claude-haiku-4-5", label: "Haiku 4.5 — fast (default)"),
        .init(id: "claude-sonnet-4-6", label: "Sonnet 4.6 — balanced"),
        .init(id: "claude-opus-4-8", label: "Opus 4.8 — deep"),
    ]

    /// Activity bars: CPU/Memory/Swap on by default; the rest are optional.
    static let defaultBars = ["cpu", "memory", "swap"]
    struct Bar: Identifiable, Sendable { let id: String; let label: String }
    static let allBars: [Bar] = [
        .init(id: "cpu", label: "CPU"),
        .init(id: "memory", label: "Memory"),
        .init(id: "swap", label: "Swap"),
        .init(id: "load", label: "Load average"),
        .init(id: "devcpu", label: "Dev server CPU"),
        .init(id: "devmem", label: "Dev server memory"),
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

/// Code editors / IDEs installed on this Mac. Detected dynamically as the apps that register to
/// open a *folder* (editors/IDEs do; Finder and a few system utilities are filtered out), plus a
/// known-name fallback — so new editors (Cursor, Antigravity, Zed, …) appear automatically.
enum EditorList {
    /// Fallback names for editors that may not register folder handling.
    static let known = [
        "Visual Studio Code", "Cursor", "Antigravity", "VSCodium", "Windsurf", "Trae", "PearAI",
        "Void", "Zed", "Sublime Text", "Nova", "Fleet", "WebStorm", "IntelliJ IDEA", "PyCharm",
        "PhpStorm", "GoLand", "RubyMine", "CLion", "Android Studio", "Atom", "BBEdit", "TextMate",
    ]
    /// Apps returned by folder-open that aren't code editors.
    private static let exclude: Set<String> = [
        "Finder", "Dev Monitor", "Archive Utility", "DiskImageMounter", "Installer",
        "Script Editor", "Automator", "Quick Look", "ColorSync Utility",
    ]

    @MainActor static func installed() -> [String] {
        let ws = NSWorkspace.shared
        let fm = FileManager.default
        func names(for url: URL) -> Set<String> {
            Set(ws.urlsForApplications(toOpen: url).map {
                fm.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            })
        }
        // Editors register to open BOTH a folder and source files; Books/QuickTime open folders but
        // not code, browsers open code but not folders — so the intersection is just the editors.
        let folderOpeners = names(for: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        var codeOpeners: Set<String> = []
        // (avoid ".ts" — it's also an MPEG-TS video type, which would pull in media players)
        for ext in ["js", "tsx", "jsx", "py", "swift", "go", "rs", "php", "rb"] {
            let f = URL(fileURLWithPath: NSTemporaryDirectory() + "dm-probe." + ext)
            try? "x".write(to: f, atomically: true, encoding: .utf8)
            codeOpeners.formUnion(names(for: f))
            try? fm.removeItem(at: f)
        }
        var result = folderOpeners.intersection(codeOpeners).subtracting(exclude)
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for name in known where !result.contains(name)
            && dirs.contains(where: { fm.fileExists(atPath: $0 + "/" + name + ".app") }) {
            result.insert(name)
        }
        return result.sorted()
    }
}

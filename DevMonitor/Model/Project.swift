import Foundation

/// JS/TS package manager, detected from the project's lockfile.
enum PackageManager: String, Codable, Sendable, CaseIterable {
    case npm, pnpm, yarn, bun

    /// The run prefix for a script (e.g. `npm run`, `pnpm`).
    var runScriptPrefix: String {
        switch self {
        case .npm: return "npm run"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .bun: return "bun run"
        }
    }
}

/// Detected web framework, drives the default dev command, port and ready-signal.
enum Framework: String, Codable, Sendable, CaseIterable {
    case nuxt, next, astro, vite, express, node, unknown

    var displayName: String {
        switch self {
        case .nuxt: return "Nuxt"
        case .next: return "Next.js"
        case .astro: return "Astro"
        case .vite: return "Vite"
        case .express: return "Express"
        case .node: return "Node"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .nuxt, .next, .astro, .vite: return "globe"
        case .express, .node: return "server.rack"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// A supervised project. Persisted to Application Support.
struct Project: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Absolute path to the project root.
    var path: String
    var packageManager: PackageManager
    var framework: Framework
    /// Optional override for the dev command; `nil` = auto-derived.
    var devCommand: String?
    /// Optional override for the build command; `nil` = auto-derived.
    var buildCommand: String?
    /// Heap size in GB injected as `--max-old-space-size`.
    var memoryGB: Int
    /// Optional port override; `nil` = parse from stdout, fallback 3000.
    var port: Int?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        packageManager: PackageManager = .npm,
        framework: Framework = .unknown,
        devCommand: String? = nil,
        buildCommand: String? = nil,
        memoryGB: Int = 4,
        port: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.packageManager = packageManager
        self.framework = framework
        self.devCommand = devCommand
        self.buildCommand = buildCommand
        self.memoryGB = memoryGB
        self.port = port
    }
}

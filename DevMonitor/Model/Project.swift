import Foundation

/// JS/TS package manager, detected from the project's lockfile.
enum PackageManager: String, Codable, Sendable, CaseIterable {
    case npm, pnpm, yarn, bun, deno

    /// The run prefix for a script (e.g. `npm run`, `pnpm`).
    var runScriptPrefix: String {
        switch self {
        case .npm: return "npm run"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .bun: return "bun run"
        case .deno: return "deno task"
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
    /// Heap size in GB injected as `--max-old-space-size` (used when `memoryAuto` is false).
    var memoryGB: Int
    /// When true, the heap follows the framework default instead of `memoryGB`.
    var memoryAuto: Bool
    /// Optional port override; `nil` = parse from stdout, fallback 3000 (i.e. "auto").
    var port: Int?
    /// When true, the package manager / dev command follow detection instead of `packageManager`.
    var packageManagerAuto: Bool

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        packageManager: PackageManager = .npm,
        framework: Framework = .unknown,
        devCommand: String? = nil,
        buildCommand: String? = nil,
        memoryGB: Int = 4,
        memoryAuto: Bool = true,
        port: Int? = nil,
        packageManagerAuto: Bool = true
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.packageManager = packageManager
        self.framework = framework
        self.devCommand = devCommand
        self.buildCommand = buildCommand
        self.memoryGB = memoryGB
        self.memoryAuto = memoryAuto
        self.port = port
        self.packageManagerAuto = packageManagerAuto
    }

    // Custom decoding so projects.json written before the auto flags still loads (defaults to auto).
    enum CodingKeys: String, CodingKey {
        case id, name, path, packageManager, framework, devCommand, buildCommand
        case memoryGB, memoryAuto, port, packageManagerAuto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        packageManager = try c.decode(PackageManager.self, forKey: .packageManager)
        framework = try c.decode(Framework.self, forKey: .framework)
        devCommand = try c.decodeIfPresent(String.self, forKey: .devCommand)
        buildCommand = try c.decodeIfPresent(String.self, forKey: .buildCommand)
        memoryGB = try c.decode(Int.self, forKey: .memoryGB)
        memoryAuto = try c.decodeIfPresent(Bool.self, forKey: .memoryAuto) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        packageManagerAuto = try c.decodeIfPresent(Bool.self, forKey: .packageManagerAuto) ?? true
    }
}

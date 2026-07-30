import Foundation

/// Read-only discovery for the AI tooling visible in Settings. Values and credentials are never
/// exposed: connector parsers keep only server names and the URL of their configuration file.
enum AgentToolCatalog {
    enum Provider: String, Hashable, Sendable {
        case codex = "Codex"
        case claude = "Claude"
        case project = "Project"
    }

    struct Plugin: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String?
        let description: String?
        let provider: Provider
        let directory: URL
    }

    struct Connector: Identifiable, Hashable {
        let id: String
        let name: String
        let provider: Provider
        let configuration: URL
    }

    struct CommandLineTool: Identifiable, Hashable {
        let id: String
        let name: String
        let origin: String
        let executable: URL
    }

    struct Snapshot {
        var skills: [SkillCatalog.Skill] = []
        var plugins: [Plugin] = []
        var connectors: [Connector] = []
        var commandLineTools: [CommandLineTool] = []
    }

    static func snapshot(at base: URL, global: Bool) -> Snapshot {
        Snapshot(
            skills: SkillCatalog.skills(at: base),
            plugins: global ? globalPlugins() : projectPlugins(at: base),
            connectors: connectors(at: base, global: global),
            commandLineTools: commandLineTools(at: base, global: global)
        )
    }

    // MARK: - Plugins

    private struct PluginManifest: Decodable {
        let name: String
        let version: String?
        let description: String?
    }

    private static func globalPlugins() -> [Plugin] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let codex = pluginsFromManifests(
            under: home.appendingPathComponent(".codex/plugins/cache", isDirectory: true),
            marker: ".codex-plugin", provider: .codex
        )
        return deduplicated(codex + claudeInstalledPlugins(home: home))
    }

    private static func projectPlugins(at base: URL) -> [Plugin] {
        let codex = pluginsFromManifests(
            under: base.appendingPathComponent(".codex/plugins", isDirectory: true),
            marker: ".codex-plugin", provider: .codex
        )
        let claude = pluginsFromManifests(
            under: base.appendingPathComponent(".claude/plugins", isDirectory: true),
            marker: ".claude-plugin", provider: .claude
        )
        return deduplicated(codex + claude)
    }

    private static func pluginsFromManifests(under root: URL, marker: String, provider: Provider) -> [Plugin] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants],
            errorHandler: nil
        ) else {
            // A shallow enumerator cannot find nested version folders. Retry recursively below.
            return recursivePluginsFromManifests(under: root, marker: marker, provider: provider)
        }
        _ = enumerator
        return recursivePluginsFromManifests(under: root, marker: marker, provider: provider)
    }

    private static func recursivePluginsFromManifests(
        under root: URL, marker: String, provider: Provider
    ) -> [Plugin] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants]
        ) else { return [] }
        var result: [Plugin] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "plugin.json",
                  url.deletingLastPathComponent().lastPathComponent == marker,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
            else { continue }
            let directory = url.deletingLastPathComponent().deletingLastPathComponent()
            result.append(Plugin(
                id: "\(provider.rawValue):\(directory.path)", name: manifest.name,
                version: manifest.version, description: manifest.description,
                provider: provider, directory: directory
            ))
        }
        return result
    }

    private static func claudeInstalledPlugins(home: URL) -> [Plugin] {
        let registry = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: registry),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["plugins"] as? [String: Any]
        else { return [] }

        return entries.compactMap { identifier, raw -> Plugin? in
            let records = raw as? [[String: Any]]
            guard let record = records?.last,
                  let path = record["installPath"] as? String
            else { return nil }
            let directory = URL(fileURLWithPath: path)
            let manifestURL = directory.appendingPathComponent(".claude-plugin/plugin.json")
            let manifest = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode(PluginManifest.self, from: $0) }
            let fallbackName = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? identifier
            return Plugin(
                id: "Claude:\(identifier)", name: manifest?.name ?? fallbackName,
                version: manifest?.version ?? record["version"] as? String,
                description: manifest?.description, provider: .claude, directory: directory
            )
        }
    }

    private static func deduplicated(_ plugins: [Plugin]) -> [Plugin] {
        var unique: [String: Plugin] = [:]
        for plugin in plugins where unique["\(plugin.provider.rawValue):\(plugin.name)"] == nil {
            unique["\(plugin.provider.rawValue):\(plugin.name)"] = plugin
        }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Connectors / MCP

    private static func connectors(at base: URL, global: Bool) -> [Connector] {
        var found: [Connector] = []
        if global {
            found += tomlConnectors(
                at: base.appendingPathComponent(".codex/config.toml"), provider: .codex
            )
            found += jsonConnectors(
                at: base.appendingPathComponent(".claude.json"), provider: .claude
            )
            found += jsonConnectors(
                at: base.appendingPathComponent(".mcp.json"), provider: .project
            )
        } else {
            found += tomlConnectors(
                at: base.appendingPathComponent(".codex/config.toml"), provider: .codex
            )
            found += jsonConnectors(
                at: base.appendingPathComponent(".claude/settings.json"), provider: .claude
            )
            found += jsonConnectors(
                at: base.appendingPathComponent(".mcp.json"), provider: .project
            )
        }
        var unique: [String: Connector] = [:]
        for connector in found {
            unique["\(connector.provider.rawValue):\(connector.name)"] = connector
        }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func jsonConnectors(at url: URL, provider: Provider) -> [Connector] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else { return [] }
        return servers.keys.map {
            Connector(id: "\(provider.rawValue):\(url.path):\($0)", name: $0,
                      provider: provider, configuration: url)
        }
    }

    private static func tomlConnectors(at url: URL, provider: Provider) -> [Connector] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let prefix = "[mcp_servers."
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine -> Connector? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix("]") else { return nil }
            let name = String(line.dropFirst(prefix.count).dropLast())
            guard !name.isEmpty, !name.contains(".") else { return nil } // skip nested `.env` tables
            return Connector(id: "\(provider.rawValue):\(url.path):\(name)", name: name,
                             provider: provider, configuration: url)
        }
    }

    // MARK: - Command-line tools

    /// Discovers executables without launching them. This keeps refreshes fast and avoids running
    /// arbitrary third-party programs just to build the visual inventory.
    private static func commandLineTools(at base: URL, global: Bool) -> [CommandLineTool] {
        let directories = global ? globalExecutableDirectories(home: base) : [
            base.appendingPathComponent("node_modules/.bin", isDirectory: true),
            base.appendingPathComponent(".venv/bin", isDirectory: true),
            base.appendingPathComponent("venv/bin", isDirectory: true),
            base.appendingPathComponent("bin", isDirectory: true)
        ]

        var seenDirectories = Set<String>()
        var unique: [String: CommandLineTool] = [:]
        for directory in directories where seenDirectories.insert(directory.standardizedFileURL.path).inserted {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for executable in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? executable.resourceValues(forKeys: [.isDirectoryKey])
                let name = executable.lastPathComponent
                guard values?.isDirectory != true, !name.isEmpty,
                      FileManager.default.isExecutableFile(atPath: executable.path), unique[name] == nil
                else { continue }
                unique[name] = CommandLineTool(
                    id: executable.standardizedFileURL.path,
                    name: name,
                    origin: global ? executableOrigin(directory) : "Project",
                    executable: executable
                )
            }
        }
        if global {
            for tool in directlyInstalledHomebrewTools() where unique[tool.name] == nil {
                unique[tool.name] = tool
            }
        }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func globalExecutableDirectories(home: URL) -> [URL] {
        let excludedRoots = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin"]
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
            .filter {
                let path = $0.standardizedFileURL.path
                return !excludedRoots.contains(path)
                    && !path.contains("/.codex/tmp/")
                    && !path.contains("/.local/state/fnm_multishells/")
                    && !path.hasPrefix("/private/var/folders/")
                    && !path.hasPrefix("/var/folders/")
            }

        directories += [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent(".bun/bin", isDirectory: true),
            home.appendingPathComponent(".cargo/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ]

        let fnmVersions = home.appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: fnmVersions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            directories += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("installation/bin", isDirectory: true) }
        }
        return directories
    }

    /// Homebrew exposes every dependency and every helper command in its shared bin folder. Keep
    /// one representative CLI per formula the user explicitly installed.
    private static func directlyInstalledHomebrewTools() -> [CommandLineTool] {
        let prefix = URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        let opt = prefix.appendingPathComponent("opt", isDirectory: true)
        guard let formulaLinks = try? FileManager.default.contentsOfDirectory(
            at: opt, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var formulas: [String: (name: String, directory: URL)] = [:]
        for formulaLink in formulaLinks {
            let formulaDirectory = formulaLink.resolvingSymlinksInPath()
            let receipt = formulaDirectory.appendingPathComponent("INSTALL_RECEIPT.json")
            guard let data = try? Data(contentsOf: receipt),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["installed_on_request"] as? Bool == true
            else { continue }

            let fullName = formulaLink.lastPathComponent
            let baseName = fullName.split(separator: "@", maxSplits: 1).first.map(String.init) ?? fullName
            if formulas[baseName] == nil || !fullName.contains("@") {
                formulas[baseName] = (fullName, formulaDirectory)
            }
        }

        return formulas.compactMap { baseName, formula -> CommandLineTool? in
            var executables: [URL] = []
            for folder in ["bin", "sbin"] {
                let directory = formula.directory.appendingPathComponent(folder, isDirectory: true)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                executables += entries.filter {
                    let values = try? $0.resourceValues(forKeys: [.isDirectoryKey])
                    return values?.isDirectory != true
                        && FileManager.default.isExecutableFile(atPath: $0.path)
                }
            }
            guard let executable = representativeExecutable(in: executables, formula: baseName) else {
                return nil
            }
            let publicExecutable = prefix.appendingPathComponent("bin")
                .appendingPathComponent(executable.lastPathComponent)
            let visibleURL = FileManager.default.fileExists(atPath: publicExecutable.path)
                ? publicExecutable : executable
            return CommandLineTool(
                id: "Homebrew:\(baseName)",
                name: executable.lastPathComponent,
                origin: "Homebrew · \(formula.name)",
                executable: visibleURL
            )
        }
    }

    private static func representativeExecutable(in executables: [URL], formula: String) -> URL? {
        let aliases: [String: [String]] = [
            "postgresql": ["psql"],
            "python": ["python3"],
            "switchaudio-osx": ["SwitchAudioSource"]
        ]
        let preferences = [formula] + (aliases[formula] ?? [])
        for preferred in preferences {
            if let exact = executables.first(where: { $0.lastPathComponent == preferred }) {
                return exact
            }
            if let prefixed = executables
                .filter({
                    $0.lastPathComponent.hasPrefix(preferred)
                        && !$0.lastPathComponent.contains("-config")
                })
                .min(by: { $0.lastPathComponent.count < $1.lastPathComponent.count }) {
                return prefixed
            }
        }
        return executables.min {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func executableOrigin(_ directory: URL) -> String {
        let path = directory.path
        if path.contains("/.local/share/fnm/") { return "Node" }
        if path.contains("/.cargo/bin") { return "Cargo" }
        if path.contains("/.bun/bin") { return "Bun" }
        if path.hasPrefix("/opt/homebrew/") { return "Homebrew" }
        if path.hasPrefix("/usr/local/") { return "Local" }
        return "User PATH"
    }

}

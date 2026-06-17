import Foundation

/// Detects package manager, framework, dev command and port from a project folder.
enum Detector {
    struct Result: Sendable {
        var packageManager: PackageManager
        var framework: Framework
        var devCommand: String
        var buildCommand: String?
        var port: Int?
    }

    static func detect(path: String) -> Result {
        let fm = FileManager.default

        // Package manager by lockfile.
        let pm: PackageManager
        if fm.fileExists(atPath: path + "/pnpm-lock.yaml") { pm = .pnpm }
        else if fm.fileExists(atPath: path + "/yarn.lock") { pm = .yarn }
        else if fm.fileExists(atPath: path + "/bun.lockb") { pm = .bun }
        else { pm = .npm }

        // Parse package.json deps + scripts.
        var deps: [String: String] = [:]
        var scripts: [String: String] = [:]
        if let data = fm.contents(atPath: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] {
                if let d = json[key] as? [String: String] { deps.merge(d) { a, _ in a } }
            }
            if let s = json["scripts"] as? [String: String] { scripts = s }
        }

        // Framework by deps.
        let framework: Framework
        if deps.keys.contains(where: { $0 == "nuxt" || $0.hasPrefix("@nuxt/") }) { framework = .nuxt }
        else if deps.keys.contains("next") { framework = .next }
        else if deps.keys.contains("astro") { framework = .astro }
        else if deps.keys.contains("vite") { framework = .vite }
        else if deps.keys.contains("express") { framework = .express }
        else if scripts["dev"] != nil || scripts["start"] != nil { framework = .node }
        else { framework = .unknown }

        // Dev command: prefer a "dev" script, else "start", else a framework default.
        let devCommand: String
        if scripts["dev"] != nil { devCommand = "\(pm.runScriptPrefix) dev" }
        else if scripts["start"] != nil { devCommand = "\(pm.runScriptPrefix) start" }
        else { devCommand = "\(pm.runScriptPrefix) dev" }

        let buildCommand: String? = scripts["build"] != nil ? "\(pm.runScriptPrefix) build" : nil

        return Result(packageManager: pm, framework: framework,
                      devCommand: devCommand, buildCommand: buildCommand, port: nil)
    }

    /// Reasonable default heap (GB) for a framework's dev server.
    static func defaultMemoryGB(for framework: Framework) -> Int {
        switch framework {
        case .nuxt, .next: return 8
        case .astro, .vite: return 4
        case .express, .node, .unknown: return 2
        }
    }
}

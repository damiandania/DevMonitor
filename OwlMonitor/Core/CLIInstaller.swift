import Foundation

/// Installs / removes the `owl-monitor` command-line tool by symlinking `~/.local/bin/owl-monitor` at
/// the CLI EMBEDDED in this app bundle (Contents/MacOS/owl-monitor). A symlink — not a copy — so the
/// CLI always matches the running app: they share `IPCProtocol`, and a stale copied CLI would
/// mis-decode `status`/`build` responses. Mirrors `ClaudeHookInstaller`'s install/uninstall/isInstalled
/// shape so the Settings UI reads the same.
enum CLIInstaller {
    /// The CLI shipped inside this app bundle, or nil if this build didn't embed it (e.g. a bare
    /// `xcodebuild` of just the app target without regenerating the project).
    static var embeddedCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/owl-monitor")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// `~/.local/bin` — the conventional user-local bin the Claude hook already expects on PATH.
    /// Overridable in tests so they never touch the real `~/.local/bin`.
    nonisolated(unsafe) static var installDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/bin", isDirectory: true)
    static var linkURL: URL { installDir.appendingPathComponent("owl-monitor") }

    /// True when `~/.local/bin/owl-monitor` is our symlink pointing at the embedded CLI. A hand-copied
    /// binary or a symlink to some other owl-monitor reads as NOT installed (so the button offers to
    /// convert it to the managed symlink).
    static var isInstalled: Bool {
        guard let embedded = embeddedCLI,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        else { return false }
        let resolved = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                                           : installDir.appendingPathComponent(dest)
        return resolved.standardizedFileURL == embedded.standardizedFileURL
    }

    /// Whether `~/.local/bin` is on the current PATH, so the UI can warn that the symlink won't be
    /// found until the user adds it. Best-effort (reads the app process's PATH).
    static var isOnPATH: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").contains { $0 == Substring(installDir.path) }
    }

    static func install() throws {
        guard let embedded = embeddedCLI else {
            throw NSError(domain: "CLIInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The owl-monitor CLI isn't bundled in this build of the app."])
        }
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: linkURL)   // replace a stale link / copy
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: embedded)
    }

    static func uninstall() throws {
        if isInstalled { try FileManager.default.removeItem(at: linkURL) }
    }
}

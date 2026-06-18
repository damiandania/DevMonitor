import Foundation

/// Parsed result of a `dev-monitor` subcommand's arguments.
struct DMArgs {
    var positionals: [String] = []
    var gb: Int?
    var flags: Set<String> = []
    /// First parse error (unknown flag, malformed `--gb` value, …). When non-nil the caller fails.
    var error: String?
}

/// A small, deterministic argument parser shared by the CLI (kept pure so it can be unit-tested).
enum DMParse {
    /// Parse the tokens that follow a subcommand.
    /// - `boolFlags`: the value-less flags this command accepts (e.g. `--all`, `-f`).
    /// - `allowGB`: enables the `--gb <int>` / `--gb=<int>` value flag, which consumes its value in
    ///   any position and must be a positive integer.
    ///
    /// Anything not recognised — an unknown flag, a missing/invalid `--gb` value — is reported via
    /// `error` rather than being silently ignored, so bad input fails loudly.
    static func parse(_ tokens: [String], boolFlags: Set<String>, allowGB: Bool) -> DMArgs {
        var out = DMArgs()
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--gb" {
                guard allowGB else { out.error = "unknown option '--gb'"; return out }
                guard i + 1 < tokens.count else { out.error = "--gb requires a value"; return out }
                guard let n = Int(tokens[i + 1]), n > 0 else {
                    out.error = "--gb requires a positive integer (got '\(tokens[i + 1])')"; return out
                }
                out.gb = n; i += 2; continue
            }
            if t.hasPrefix("--gb=") {
                guard allowGB else { out.error = "unknown option '--gb'"; return out }
                let v = String(t.dropFirst("--gb=".count))
                guard let n = Int(v), n > 0 else {
                    out.error = "--gb requires a positive integer (got '\(v)')"; return out
                }
                out.gb = n; i += 1; continue
            }
            if t.hasPrefix("-") {
                guard boolFlags.contains(t) else { out.error = "unknown option '\(t)'"; return out }
                out.flags.insert(t); i += 1; continue
            }
            out.positionals.append(t); i += 1
        }
        return out
    }

    /// Resolve a user-supplied path to an absolute, tilde-expanded, normalized path (relative paths
    /// resolve against the current working directory).
    static func absolutePath(_ p: String, cwd: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        let abs = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return (abs as NSString).standardizingPath
    }
}

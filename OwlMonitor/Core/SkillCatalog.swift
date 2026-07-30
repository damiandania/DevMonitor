import Foundation
import AppKit

/// Discovers Claude/Codex skill folders without scanning arbitrary project contents. A skill is a
/// direct child of one of the supported `*/skills` roots and must contain `SKILL.md`.
enum SkillCatalog {
    struct Skill: Identifiable, Hashable {
        let directory: URL
        let root: URL
        let description: String?

        var id: String { directory.path }
        var name: String { directory.lastPathComponent }
        var source: String { root.deletingLastPathComponent().lastPathComponent }
    }

    private static let skillRoots = [".claude/skills", ".agents/skills", ".codex/skills"]

    /// Skills found in all supported roots directly beneath one project or the user's home folder.
    static func skills(at base: URL) -> [Skill] {
        // `.claude` is the canonical location for new skills. Keep its entry when the same skill is
        // mirrored in `.agents` or `.codex`, so Settings never shows duplicate rows.
        var unique: [String: Skill] = [:]
        for root in skillRoots {
            for skill in skills(in: base.appendingPathComponent(root, isDirectory: true)) {
                if unique[skill.name] == nil { unique[skill.name] = skill }
            }
        }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func skills(in root: URL) -> [Skill] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { child in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fm.fileExists(atPath: child.appendingPathComponent("SKILL.md").path)
            else { return nil }
            let skillFile = child.appendingPathComponent("SKILL.md")
            return Skill(directory: child, root: root, description: description(in: skillFile))
        }
    }

    /// A concise skill summary: explicit YAML `description:` wins, otherwise use the first prose line.
    private static func description(in skillFile: URL) -> String? {
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var frontMatter = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---"

        for raw in lines.prefix(80) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if frontMatter {
                if line == "---" && raw != lines.first { frontMatter = false; continue }
                if line.lowercased().hasPrefix("description:") {
                    let value = line.dropFirst("description:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return value.isEmpty ? nil : String(value)
                }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```"), !line.hasPrefix("---") else { continue }
            return line.count > 180 ? String(line.prefix(177)) + "…" : line
        }
        return nil
    }

    /// Removes every mirrored copy of one skill inside this scope. Only folders that actually contain
    /// `SKILL.md` are eligible, so similarly named non-skill folders are left untouched.
    static func removeAllCopies(named name: String, at base: URL) throws {
        let copies = skillRoots.flatMap { root in
            skills(in: base.appendingPathComponent(root, isDirectory: true)).filter { $0.name == name }
        }
        for copy in copies {
            try FileManager.default.removeItem(at: copy.directory)
        }
    }

    /// Moves a skill to the destination's canonical `.claude/skills` root. When the source contains
    /// mirrored copies, the preferred `.claude` copy moves and the other mirrors are removed.
    static func moveAllCopies(named name: String, from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else { return }
        let copies = skillRoots.flatMap { root in
            skills(in: source.appendingPathComponent(root, isDirectory: true)).filter { $0.name == name }
        }
        guard let preferred = copies.first else { return }

        let destinationRoot = destination.appendingPathComponent(".claude/skills", isDirectory: true)
        let destinationSkill = destinationRoot.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destinationSkill.path) else {
            throw TransferError.destinationAlreadyHasSkill(name)
        }
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: preferred.directory, to: destinationSkill)
        for copy in copies where copy.directory != preferred.directory {
            try FileManager.default.removeItem(at: copy.directory)
        }
    }

    private enum TransferError: LocalizedError {
        case destinationAlreadyHasSkill(String)

        var errorDescription: String? {
            switch self {
            case .destinationAlreadyHasSkill(let name):
                return "The destination already has a skill named \(name)."
            }
        }
    }

    /// Opens an interactive Claude Code session in Terminal. Claude is asked to clarify the desired
    /// skill before changing files, then creates it in the standard `.claude/skills` location.
    @discardableResult
    static func askClaudeToAddSkill(in base: URL) -> String? {
        let prompt = """
        Quiero añadir una nueva skill a este espacio. Pregunta primero qué skill desea agregar y no crees ni modifiques archivos hasta recibir la respuesta. Después, crea la skill dentro de .claude/skills siguiendo la estructura estándar de Claude Code.
        """
        let command = "cd \(shellQuote(base.path)); claude \(shellQuote(prompt))"
        let source = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(command))
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error?[NSAppleScript.errorMessage] as? String
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

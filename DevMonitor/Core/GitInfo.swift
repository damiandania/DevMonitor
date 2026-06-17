import Foundation

enum GitInfo {
    /// Current branch from `.git/HEAD` (or a short SHA if detached). nil if not a git repo.
    static func branch(for projectPath: String) -> String? {
        let headPath = projectPath + "/.git/HEAD"
        guard let content = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))  // detached HEAD
    }
}

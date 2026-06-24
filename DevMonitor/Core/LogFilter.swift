import Foundation

/// Pure log-search policy for the terminal pane: a case-insensitive substring match against the
/// ANSI-stripped text (so a query never has to account for colour escape codes). Kept framework-free
/// so it's unit-testable headless.
enum LogFilter {
    /// Whether `line` matches `query`. An empty / whitespace-only query matches everything.
    static func matches(_ line: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return line.strippedANSI.range(of: q, options: .caseInsensitive) != nil
    }

    /// The lines that match `query`, preserving order. Returns all lines for an empty query.
    static func filter(_ lines: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return lines }
        return lines.filter { matches($0, query: q) }
    }
}

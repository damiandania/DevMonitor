import Foundation

/// Accumulates raw process output and yields complete (`\n`-terminated) lines, holding any trailing
/// partial line until more bytes arrive. Decodes UTF-8; a chunk that isn't valid UTF-8 is dropped
/// (mirrors the prior inline behavior in `DevSession`/`BuildRunner`, which both did exactly this).
struct LineBuffer {
    private var partial = ""

    /// Append `data` and return every complete line it completed (without the trailing newline).
    mutating func ingest(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        partial += text
        var lines: [String] = []
        while let nl = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<nl]))
            partial.removeSubrange(...nl)
        }
        return lines
    }

    /// Discard any buffered partial line (used when a session is restarted).
    mutating func reset() { partial = "" }
}

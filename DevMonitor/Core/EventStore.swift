import Foundation

/// Append-only JSONL history of supervision / pressure events under Application Support, so a record
/// of crashes / recycles / builds / pressure survives an app restart (the in-app feed only keeps the
/// last few in memory). One compact JSON object per line; rolled to `events.jsonl.1` past a size cap
/// so it can't grow without bound. History is non-critical, so every operation is best-effort.
@MainActor
final class EventStore {
    /// Exposed for tests + diagnostics.
    let fileURL: URL
    private let maxBytes: Int

    /// `directory` defaults to `~/Library/Application Support/DevMonitor`; tests pass a temp dir.
    init(directory: URL? = nil, maxBytes: Int = 2_000_000) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("events.jsonl")
        self.maxBytes = maxBytes
    }

    /// Append one event as a JSON line (rotating first if the file is large).
    func append(_ event: PersistedEvent) {
        rotateIfNeeded()
        guard let data = try? JSONEncoder().encode(event) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(data)
        h.write(Data([0x0A]))   // newline-delimited
    }

    /// Load persisted events, newest first. Reads the rolled file too so history spans a rotation.
    /// Skips any unparseable line (so a future schema change never breaks the reader).
    func load(limit: Int = 1000) -> [PersistedEvent] {
        let decoder = JSONDecoder()
        func read(_ url: URL) -> [PersistedEvent] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                line.data(using: .utf8).flatMap { try? decoder.decode(PersistedEvent.self, from: $0) }
            }
        }
        let rolled = URL(fileURLWithPath: fileURL.path + ".1")
        let all = read(rolled) + read(fileURL)   // chronological across the rotation boundary
        return Array(all.suffix(limit).reversed())
    }

    /// Roll the file to `events.jsonl.1` once it exceeds the cap, keeping exactly one previous file.
    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let rolled = URL(fileURLWithPath: fileURL.path + ".1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: fileURL, to: rolled)
    }
}

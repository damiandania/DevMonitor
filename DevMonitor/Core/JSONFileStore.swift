import Foundation

/// Versioned JSON persistence under Application Support — the shared engine behind `ProjectStore`
/// and `SettingsStore` (which used to duplicate this load/save dance).
///
/// The key property is that it **never silently loses data**. It distinguishes an *absent* file
/// (first run → caller falls back to defaults, no fuss) from a file that is *present but unreadable*
/// (corruption → the bad file is moved aside to `<name>.corrupt-<unixtime>` and the corruption is
/// reported, instead of being overwritten by the next save and lost forever). Payloads are written
/// as a `{ "version": N, "data": … }` envelope so future schema changes have a migration hook;
/// legacy un-enveloped files (a bare array / object) still load and are upgraded on the next save.
@MainActor
final class JSONFileStore<Payload: Codable> {
    /// Result of a load — lets the caller tell "first run" (use defaults quietly) from
    /// "your data was corrupt and reset" (worth surfacing to the user).
    enum LoadOutcome {
        case missing
        case loaded(Payload)
        case corrupt(backup: URL?)
    }

    private struct Envelope: Codable { var version: Int; var data: Payload }

    /// The file this store reads/writes (exposed for tests + diagnostics).
    let fileURL: URL
    private let version: Int
    private let label: String

    /// `directory` defaults to `~/Library/Application Support/DevMonitor` (created if needed);
    /// tests pass a temp directory.
    init(filename: String, version: Int, directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(filename)
        self.version = version
        self.label = filename
    }

    func load() -> LoadOutcome {
        // No file yet → genuine first run, not corruption.
        guard let data = try? Data(contentsOf: fileURL) else { return .missing }
        let decoder = JSONDecoder()
        // Current format: the versioned envelope (tried first, so a real envelope never falls through
        // to the lenient legacy path below — AppSettings's tolerant decoder would otherwise accept it).
        if let env = try? decoder.decode(Envelope.self, from: data) { return .loaded(env.data) }
        // Legacy format: the bare payload written before versioning. Valid — upgraded on next save.
        if let legacy = try? decoder.decode(Payload.self, from: data) {
            AppLog.shared.event("\(label): migrated a legacy unversioned file to schema v\(version)")
            return .loaded(legacy)
        }
        // Present but undecodable → corruption. Preserve it, never overwrite silently.
        let backup = backUpCorruptFile()
        AppLog.shared.event("\(label): unreadable (corrupt) — backed up to "
            + "\(backup?.lastPathComponent ?? "<backup failed>") and continuing with defaults")
        return .corrupt(backup: backup)
    }

    func save(_ payload: Payload) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: version, data: payload)) else { return }
        do { try data.write(to: fileURL, options: .atomic) }
        catch { AppLog.shared.event("\(label): failed to save — \(error.localizedDescription)") }
    }

    /// Move the corrupt file aside to `<name>.corrupt-<unixtime>` so it's preserved for recovery and
    /// can't be clobbered by the next save. Returns the backup URL (nil if the move itself failed).
    private func backUpCorruptFile() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = URL(fileURLWithPath: fileURL.path + ".corrupt-\(stamp)")
        do { try FileManager.default.moveItem(at: fileURL, to: dest); return dest }
        catch { return nil }
    }
}

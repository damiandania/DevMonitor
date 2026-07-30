import Foundation

/// Loads and saves the project list as versioned JSON under Application Support, on top of the
/// corruption-safe `JSONFileStore` (an unreadable file is backed up, never silently wiped).
@MainActor
final class ProjectStore {
    private let store = JSONFileStore<[Project]>(filename: "projects.json", version: 1)

    /// Load the persisted projects. `corruptBackup` is non-nil only when the file existed but was
    /// unreadable — the list was reset to empty and the bad file preserved at that path, so the
    /// caller can tell the user instead of losing every project without a trace.
    func load() -> (projects: [Project], corruptBackup: URL?) {
        switch store.load() {
        case .missing:             return ([], nil)
        case .loaded(let p):       return (p, nil)
        case .corrupt(let backup): return ([], backup)
        }
    }

    func save(_ projects: [Project]) { store.save(projects) }
}

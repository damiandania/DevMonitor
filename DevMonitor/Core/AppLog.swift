import Foundation
import Observation

/// Captures Dev Monitor's OWN internal events/errors (not the supervised dev server's), so
/// Claude can produce a read-only diagnostic report about the app itself.
@MainActor
@Observable
final class AppLog {
    static let shared = AppLog()
    private(set) var entries: [String] = []
    private let maxEntries = 500

    private init() {
        entries.append("Dev Monitor started")
    }

    func event(_ message: String) {
        entries.append(message)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    func recent(_ count: Int = 120) -> String {
        entries.suffix(count).joined(separator: "\n")
    }
}

// Sparkle auto-update integration. Inert until the Sparkle SPM package is added (see
// docs/DISTRIBUTION.md) — `#if canImport(Sparkle)` compiles to nothing without it, so the app
// keeps building unsigned/unconfigured. Once Sparkle is linked and the Info.plist keys
// (SUFeedURL, SUPublicEDKey) are set, the "Check for Updates…" menu item lights up automatically.
#if canImport(Sparkle)
import SwiftUI
import Sparkle

/// Owns the Sparkle updater so it lives for the app's lifetime.
@MainActor
final class UpdaterController {
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    func checkForUpdates() { controller.updater.checkForUpdates() }
}

/// A `.commands` group exposing "Check for Updates…" under the app menu. Add to
/// `DevMonitorApp.body`'s `.commands { }` once Sparkle is linked:
///   `UpdaterCommands(updater: updater)`
struct UpdaterCommands: Commands {
    let updater: UpdaterController
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
    }
}
#endif

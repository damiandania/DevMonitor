import SwiftUI

@main
struct DevMonitorApp: App {
    @State private var appState = AppState()

    init() {
        Notifier.shared.requestAuthorization()
    }

    var body: some Scene {
        // Single main window (not a WindowGroup): "Open Window" focuses the existing one
        // instead of spawning duplicates.
        Window("Dev Monitor", id: "main") {
            RootSplitView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Dev Monitor", systemImage: "waveform.path.ecg") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        // Settings and Doctor are real windows (native title bar + traffic-light close button).
        Window("Settings", id: "settings") {
            AppSettingsView().environment(appState)
        }
        .windowResizability(.contentSize)

        Window("Doctor", id: "doctor") {
            DoctorSheet().environment(appState)
        }
        .windowResizability(.contentSize)
    }
}

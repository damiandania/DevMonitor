import SwiftUI

@main
struct DevMonitorApp: App {
    @State private var appState = AppState()

    init() {
        Notifier.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
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
    }
}

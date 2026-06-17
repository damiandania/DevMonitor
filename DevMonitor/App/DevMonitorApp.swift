import SwiftUI

@main
struct DevMonitorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

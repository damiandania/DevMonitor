import SwiftUI

struct RootSplitView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let project = app.selectedProject {
                DashboardView(project: project)
            } else {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "square.dashed",
                    description: Text("Add a project and select it to supervise its dev server.")
                )
            }
        }
        .navigationTitle("Dev Monitor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "settings") } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("App settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "doctor") } label: {
                    Label("Doctor", systemImage: "stethoscope")
                }
                .help("Read-only AI: heavy processes, Dev Monitor diagnosis, and how to free RAM")
            }
        }
    }
}

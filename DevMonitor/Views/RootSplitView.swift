import SwiftUI

struct RootSplitView: View {
    @Environment(AppState.self) private var app

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
                Button { app.generateReport() } label: {
                    Label("Diagnose", systemImage: "stethoscope")
                }
                .help("Ask Claude to diagnose Dev Monitor itself (read-only)")
            }
        }
        .sheet(isPresented: $app.showReport) {
            ReportSheet().environment(app)
        }
    }
}

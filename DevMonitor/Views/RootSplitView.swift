import SwiftUI

struct RootSplitView: View {
    @Environment(AppState.self) private var app

    var body: some View {
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
    }
}

import SwiftUI

struct RootSplitView: View {
    @Environment(AppState.self) private var app
    @State private var showSettings = false
    @State private var showDoctor = false

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
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("App settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showDoctor = true } label: {
                    Label("Doctor", systemImage: "stethoscope")
                }
                .help("Read-only AI: heavy processes, Dev Monitor diagnosis, and how to free RAM")
            }
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView().environment(app).interactiveDismissDisabled()
        }
        .sheet(isPresented: $showDoctor) {
            DoctorSheet().environment(app).interactiveDismissDisabled()
        }
    }
}

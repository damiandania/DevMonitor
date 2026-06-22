import SwiftUI
import AppKit

struct RootSplitView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailTop
        }
        .navigationTitle("Dev Monitor")
        .toolbar {
            // Build sits at the left of the trailing toolbar group (before Open), separated from
            // the open/settings/doctor cluster.
            ToolbarItem(placement: .primaryAction) {
                ProjectBuildButton()
            }
            ToolbarItem(placement: .primaryAction) {
                ProjectOpenGroup()
            }
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
                .help("Doctor Claude")
            }
        }
    }

    /// The detail stack: the selected project's header card (or a placeholder), the GLOBAL Activity
    /// card, and — while something is running — the GLOBAL terminal as another card below, filling
    /// the remaining height. All sit on the window-tinted base.
    @ViewBuilder private var detailTop: some View {
        VStack(spacing: 14) {
            if let project = app.selectedProject {
                DashboardView(project: project)
            } else {
                Label("No project selected — add one with + and pick it in the sidebar.",
                      systemImage: "square.dashed")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dmCard()
            }
            ActivityView()
            if !(app.sessions.isEmpty && app.builds.isEmpty) {
                GlobalTerminalView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

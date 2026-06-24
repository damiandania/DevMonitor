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
                // Toolbar lives on the detail content (not the split-view root) so ToolbarSpacer
                // actually splits the trailing items into separate Liquid Glass groups:
                // 1) Build · 2) Open · 3) Settings + Doctor.
                .toolbar {
                    ToolbarSpacer(.flexible)
                    // Build/worker/dev controls live in the dashboard card now (see RunControlRow).
                    ToolbarItem {
                        ProjectOpenGroup()
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItemGroup {
                        Button { openWindow(id: "settings") } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("App settings")
                        Button { openWindow(id: "doctor") } label: {
                            Label("Doctor", systemImage: "stethoscope")
                        }
                        .help("Doctor Claude")
                        Button { openWindow(id: "history") } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .help("Event history (crashes, recycles, builds, pressure)")
                    }
                }
        }
        .navigationTitle("Dev Monitor")
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
            if !app.sessions.isEmpty || !app.builds.isEmpty || !app.workers.isEmpty
                || !app.previews.isEmpty || app.systemUnderPressure {
                GlobalTerminalView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

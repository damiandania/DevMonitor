import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebar: View {
    @Environment(AppState.self) private var app
    @State private var importing = false

    var body: some View {
        @Bindable var app = app

        List(selection: $app.selectedProjectID) {
            Section("Projects") {
                ForEach(app.projects) { project in
                    HStack(spacing: 8) {
                        ProjectIconView(project: project, size: 16)
                        Text(project.name).lineLimit(1)
                        if let st = app.session(for: project)?.state, st.isActive {
                            Spacer(minLength: 4)
                            // Running indicator: status tint (green = running, orange = launching, …).
                            // `.drawingGroup()` rasterises the dot into an opaque Metal bitmap so the
                            // macOS selection *vibrancy* can't darken it — a plain Circle/SF Symbol on
                            // the selected (blue) row gets blended down (green 20,174,60 → 0,113,58).
                            Circle()
                                .fill(st.tint)
                                .frame(width: 9, height: 9)
                                .drawingGroup()
                                .help("Server: \(st.label)")
                        }
                    }
                    .tag(project.id)
                    .contextMenu {
                        Button("Remove", role: .destructive) { app.removeProject(project.id) }
                    }
                }
            }
        }
        .overlay {
            if app.projects.isEmpty {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder.badge.plus",
                    description: Text("Click + to add a project folder. Configure it in Settings.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: {
                    Label("Add Project", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                app.addProject(path: url.path)
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
}

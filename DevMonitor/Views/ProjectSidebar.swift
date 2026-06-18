import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebar: View {
    @Environment(AppState.self) private var app
    @State private var importing = false
    @State private var settingsProject: Project?
    @State private var showAppSettings = false

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            List(selection: $app.selectedProjectID) {
                Section("Projects") {
                    ForEach(app.projects) { project in
                        HStack(spacing: 8) {
                            ProjectIconView(project: project, size: 16)
                            Text(project.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { settingsProject = project } label: {
                                Image(systemName: "gearshape")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Project settings")
                        }
                        .tag(project.id)
                        .contextMenu {
                            Button("Settings…") { settingsProject = project }
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
                        description: Text("Click + to add a project folder.")
                    )
                }
            }

            Divider()
            Button { showAppSettings = true } label: {
                Label("App Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
        .sheet(item: $settingsProject) { project in
            ProjectSettingsSheet(project: project).environment(app)
        }
        .sheet(isPresented: $showAppSettings) {
            AppSettingsView().environment(app)
        }
    }
}

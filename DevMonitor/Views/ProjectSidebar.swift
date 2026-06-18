import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebar: View {
    @Environment(AppState.self) private var app
    @State private var importing = false

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            List(selection: $app.selectedProjectID) {
                Section("Projects") {
                    ForEach(app.projects) { project in
                        HStack(spacing: 8) {
                            ProjectIconView(project: project, size: 16)
                            Text(project.name)
                        }
                        .tag(project.id)
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                app.removeProject(project.id)
                            }
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

            if app.systemSampler.pressure == .stuck {
                Divider()
                PressureSuggestionsView()
            }

            if let project = app.selectedProject {
                Divider()
                ServerConfigView(project: project)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    importing = true
                } label: {
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

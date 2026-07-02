import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebar: View {
    @Environment(AppState.self) private var app
    @State private var importing = false
    /// Parent-folder paths the user has collapsed. Empty ⇒ every group expanded (the default).
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var app = app

        List(selection: $app.selectedProjectID) {
            Section("Projects") {
                ForEach(groups, id: \.id) { group in
                    DisclosureGroup(isExpanded: expansion(group.id)) {
                        ForEach(group.projects) { project in
                            projectRow(project)
                        }
                    } label: {
                        Label(group.name, systemImage: "folder")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .help(group.id)
                    }
                }
            }
            // Last 5 notifications as a "Recent" section on the same card surface as Projects.
            NotificationsFeedView()
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    // Adds the folder if it's a project, else every project found inside it.
                    app.addProjects(under: url.path)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    /// One project row: icon · name · running dot. Selectable (tagged) and removable.
    @ViewBuilder private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 8) {
            ProjectIconView(project: project, size: 16)
            Text(project.name).lineLimit(1)
            if let st = app.session(for: project)?.state, st.isActive {
                Spacer(minLength: 4)
                // Running indicator: status tint (green = running, orange = launching, …).
                // drawingGroup so the selected-row vibrancy can't darken it (see StatusDot).
                StatusDot(color: st.tint, size: 9, drawingGroup: true)
                    .help("Server: \(st.label)")
            }
        }
        .tag(project.id)
        .contextMenu {
            Button("Remove", role: .destructive) { app.removeProject(project.id) }
        }
    }

    /// Projects grouped by their parent folder — groups ordered by first appearance, projects kept in
    /// their existing order. The group id is the parent's full path (so same-named folders in
    /// different locations stay distinct); the display name is the folder's last path component.
    private var groups: [(id: String, name: String, projects: [Project])] {
        var order: [String] = []
        var byParent: [String: [Project]] = [:]
        for p in app.projects {
            let parent = URL(fileURLWithPath: p.path).deletingLastPathComponent().path
            if byParent[parent] == nil { order.append(parent) }
            byParent[parent, default: []].append(p)
        }
        return order.map { (id: $0, name: URL(fileURLWithPath: $0).lastPathComponent, projects: byParent[$0]!) }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { expanded in if expanded { collapsed.remove(id) } else { collapsed.insert(id) } })
    }
}

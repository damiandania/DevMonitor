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
                // Flat rows (a folder header + its projects), NOT DisclosureGroups: on macOS a
                // `List(selection:)` mis-lays-out a selected row nested in a DisclosureGroup — it
                // renders it floating outside its group or overlapping another row. Collapsing is done
                // by hand (chevron header + conditional rows), which keeps every selectable row a
                // direct child of the section and sidesteps that bug.
                ForEach(groups, id: \.id) { group in
                    groupHeader(group)
                    if !collapsed.contains(group.id) {
                        ForEach(group.projects) { project in
                            projectRow(project)
                        }
                    }
                }
            }
            // Last 5 notifications as a "Recent" section on the same card surface as Projects.
            NotificationsFeedView()
        }
        // Brand lockup pinned above the list rather than placed inside it, so it stays put while the
        // projects scroll and can't be selected as a row.
        .safeAreaInset(edge: .top) {
            BrandMark(size: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
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
        .padding(.leading, 14)   // indent under the folder header (DisclosureGroup used to do this)
        .tag(project.id)
        .contextMenu {
            Button("Remove", role: .destructive) { app.removeProject(project.id) }
        }
    }

    /// Projects grouped by the folder the user dropped (`groupRoot`), falling back to the immediate
    /// parent for projects added directly. So dropping a parent like `~/Dev/42` keeps every project
    /// found inside it under one "42" group, regardless of how deep each one was nested. Groups are
    /// ordered by first appearance and projects keep their existing order; the group id is the full
    /// path (same-named folders elsewhere stay distinct), the display name its last path component.
    private var groups: [(id: String, name: String, projects: [Project])] {
        var order: [String] = []
        var byGroup: [String: [Project]] = [:]
        for p in app.projects {
            let key = p.groupRoot ?? URL(fileURLWithPath: p.path).deletingLastPathComponent().path
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(p)
        }
        return order.map { (id: $0, name: URL(fileURLWithPath: $0).lastPathComponent, projects: byGroup[$0]!) }
    }

    /// A folder group header row: a chevron + folder label that toggles the group's collapsed state.
    /// Not tagged, so `List(selection:)` never treats it as a selectable project.
    @ViewBuilder private func groupHeader(_ group: (id: String, name: String, projects: [Project])) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
            Label(group.name, systemImage: "folder")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(group.id) }
        .help(group.id)
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

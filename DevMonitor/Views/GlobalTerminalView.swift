import SwiftUI
import AppKit

/// Global terminal panel: one tab per running server and per build, across ALL projects. Each tab
/// is "icon (server/build) + project name + ✕". Launching another project's server adds a tab; a
/// build adds its own tab alongside the server (builds no longer stop servers).
struct GlobalTerminalView: View {
    @Environment(AppState.self) private var app

    private struct Tab: Identifiable {
        let id: String          // "s:<projectID>" (server) | "b:<projectID>" (build)
        let projectID: Project.ID
        let name: String
        let isBuild: Bool
    }

    private var tabs: [Tab] {
        var result: [Tab] = []
        for (pid, s) in app.sessions {
            result.append(Tab(id: "s:\(pid)", projectID: pid, name: s.project.name, isBuild: false))
        }
        for (pid, b) in app.builds {
            result.append(Tab(id: "b:\(pid)", projectID: pid, name: b.project.name, isBuild: true))
        }
        // Stable order: by project name, server before its build.
        return result.sorted { $0.name == $1.name ? (!$0.isBuild && $1.isBuild) : $0.name < $1.name }
    }

    /// The selected tab, falling back to the first when the stored selection is gone (e.g. closed).
    private var selectedID: String? {
        let ids = tabs.map(\.id)
        if let sel = app.selectedTerminalID, ids.contains(sel) { return sel }
        return ids.first
    }

    var body: some View {
        let tabs = tabs
        let sel = selectedID
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in tabPill(tab, selected: tab.id == sel) }
                }
                .padding(.horizontal, 2).padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            if let sel, let tab = tabs.first(where: { $0.id == sel }) {
                logPane(for: tab)
            }
        }
        .dmCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func logPane(for tab: Tab) -> some View {
        if tab.isBuild, let build = app.builds[tab.projectID] {
            LogPaneView(lines: build.logLines, terminalTheme: app.settings.terminalTheme)
        } else if let session = app.sessions[tab.projectID] {
            LogPaneView(lines: session.logLines,
                        inputPlaceholder: "Send input to \(session.project.name) (press Enter)…",
                        onSubmit: { session.sendInput($0) },
                        terminalTheme: app.settings.terminalTheme)
        }
    }

    /// A tab pill: icon + project name (tap to select) + an ✕ that closes it.
    private func tabPill(_ tab: Tab, selected: Bool) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tab.isBuild ? "hammer.fill" : "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                Text(tab.name)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.selectedTerminalID = tab.id }
            .help("\(tab.isBuild ? "Build" : "Server") · \(tab.name)")

            Button {
                if tab.isBuild { app.closeBuild(id: tab.projectID) } else { app.closeServer(id: tab.projectID) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
            .buttonStyle(.plain)
            .help("Close \(tab.isBuild ? "build" : "server") · \(tab.name)")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(Color.accentColor)
                             : AnyShapeStyle(Color(.quaternaryLabelColor)),
                    in: Capsule())
    }
}

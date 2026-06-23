import SwiftUI
import AppKit

/// Global terminal panel: one tab per running server and per build, across ALL projects, plus a
/// yellow "System pressure" tab (when the machine is stuck) that shows the kill suggestions.
/// Each terminal tab is "icon + project name + status dot / ✕ on hover".
struct GlobalTerminalView: View {
    @Environment(AppState.self) private var app

    private struct Tab: Identifiable {
        enum Kind { case server, build, pressure }
        let id: String              // "s:<projectID>" | "b:<projectID>" | "pressure"
        let projectID: Project.ID?  // nil for the pressure tab
        let name: String
        let kind: Kind
        var isBuild: Bool { kind == .build }
        var isPressure: Bool { kind == .pressure }
    }

    private var tabs: [Tab] {
        var result: [Tab] = []
        for (pid, s) in app.sessions {
            result.append(Tab(id: "s:\(pid)", projectID: pid, name: s.project.name, kind: .server))
        }
        for (pid, b) in app.builds {
            result.append(Tab(id: "b:\(pid)", projectID: pid, name: b.project.name, kind: .build))
        }
        // Stable order: by project name, server before its build.
        result.sort { $0.name == $1.name ? ($0.kind == .server && $1.kind == .build) : $0.name < $1.name }
        // The pressure tab is an alert — always first (leftmost).
        if app.systemUnderPressure {
            result.insert(Tab(id: "pressure", projectID: nil, name: "System pressure", kind: .pressure), at: 0)
        }
        return result
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
                    ForEach(tabs) { tab in
                        TabPill(tab: tab,
                                selected: tab.id == sel,
                                tint: statusColor(tab),
                                onSelect: { app.selectedTerminalID = tab.id },
                                onClose: {
                                    switch tab.kind {
                                    case .pressure: app.dismissPressure()
                                    case .build:    tab.projectID.map { app.closeBuild(id: $0) }
                                    case .server:   tab.projectID.map { app.closeServer(id: $0) }
                                    }
                                })
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            if let sel, let tab = tabs.first(where: { $0.id == sel }) {
                pane(for: tab)
            }
        }
        .dmCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func pane(for tab: Tab) -> some View {
        switch tab.kind {
        case .pressure:
            ScrollView { PressureSuggestionsView().frame(maxWidth: .infinity, alignment: .leading) }
        case .build:
            if let id = tab.projectID, let build = app.builds[id] {
                LogPaneView(lines: build.logLines, terminalTheme: app.settings.terminalTheme)
            }
        case .server:
            if let id = tab.projectID, let session = app.sessions[id] {
                LogPaneView(lines: session.logLines,
                            inputPlaceholder: "Send input to \(session.project.name) (press Enter)…",
                            onSubmit: { session.sendInput($0) },
                            terminalTheme: app.settings.terminalTheme)
            }
        }
    }

    /// Status colour for a tab's dot: the pressure alert (yellow), a build's outcome (running orange,
    /// built green, failed red) or the server's live state (running green, launching orange, …).
    private func statusColor(_ tab: Tab) -> Color {
        switch tab.kind {
        case .pressure: return .yellow
        case .build:
            guard let id = tab.projectID, let b = app.builds[id] else { return .secondary }
            if b.isRunning { return .orange }
            switch b.result {
            case .some(0): return .green
            case .some:    return .red
            default:       return .secondary
            }
        case .server:
            guard let id = tab.projectID else { return .secondary }
            return (app.sessions[id]?.state ?? .idle).tint
        }
    }

    /// A tab pill: icon + project name (tap to select). Terminal tabs show a status dot that swaps to
    /// an ✕ on hover; the pressure tab is yellow with a warning glyph (and no close — it self-clears).
    private struct TabPill: View {
        let tab: Tab
        let selected: Bool
        let tint: Color
        let onSelect: () -> Void
        let onClose: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                    Text(tab.name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .help(helpText)

                trailing.frame(width: 14, height: 14)   // fixed slot so dot↔✕ never shifts layout
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(background, in: Capsule())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
        }

        private var icon: String {
            switch tab.kind {
            case .pressure: return "exclamationmark.triangle.fill"
            case .build:    return "hammer.fill"
            case .server:   return "server.rack"
            }
        }

        private var helpText: String {
            switch tab.kind {
            case .pressure: return "System under pressure — suggested processes to free up"
            case .build:    return "Build · \(tab.name)"
            case .server:   return "Server · \(tab.name)"
            }
        }

        private var foreground: Color {
            if tab.isPressure { return selected ? .black : .pressureAmber }
            return selected ? .white : .primary
        }

        private var background: AnyShapeStyle {
            if tab.isPressure {
                return AnyShapeStyle(selected ? Color.yellow.opacity(0.9) : Color.yellow.opacity(0.22))
            }
            return selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.quaternaryLabelColor))
        }

        @ViewBuilder private var trailing: some View {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
                }
                .buttonStyle(.plain)
                .help(tab.isPressure ? "Dismiss pressure suggestions"
                                     : "Close \(tab.isBuild ? "build" : "server") · \(tab.name)")
            } else {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
        }
    }
}

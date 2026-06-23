import SwiftUI
import AppKit

/// Global terminal panel: one tab per live run-control across ALL projects (dev, worker, build,
/// preview, … — straight from `AppState.runControls`, so a new process type appears automatically),
/// plus a yellow "System pressure" tab when the machine is stuck. Each tab is "icon + project name +
/// status dot / ✕ on hover".
struct GlobalTerminalView: View {
    @Environment(AppState.self) private var app

    private enum Tab: Identifiable {
        case control(RunControl)
        case pressure
        var id: String { switch self { case .control(let c): c.tabID; case .pressure: "pressure" } }
    }

    private var tabs: [Tab] {
        var controls = app.projects.flatMap { app.runControls(for: $0) }.filter(\.isLive)
        controls.sort { ($0.projectName, $0.rank) < ($1.projectName, $1.rank) }
        var result: [Tab] = controls.map { .control($0) }
        // The pressure tab is an alert — always first (leftmost).
        if app.systemUnderPressure { result.insert(.pressure, at: 0) }
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
                    ForEach(tabs) { pill(for: $0, selected: $0.id == sel) }
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

    @ViewBuilder private func pill(for tab: Tab, selected: Bool) -> some View {
        switch tab {
        case .control(let c):
            TabPill(icon: c.icon, name: c.projectName, help: "\(c.title) · \(c.projectName)",
                    isPressure: false, selected: selected, tint: c.status.color,
                    onSelect: { app.selectedTerminalID = c.tabID },
                    closeHelp: "Close \(c.title.lowercased()) · \(c.projectName)", onClose: c.onClose)
        case .pressure:
            TabPill(icon: "exclamationmark.triangle.fill", name: "System pressure",
                    help: "System under pressure — suggested processes to free up",
                    isPressure: true, selected: selected, tint: .yellow,
                    onSelect: { app.selectedTerminalID = "pressure" },
                    closeHelp: "Dismiss pressure suggestions", onClose: { app.dismissPressure() })
        }
    }

    @ViewBuilder private func pane(for tab: Tab) -> some View {
        switch tab {
        case .pressure:
            ScrollView { PressureSuggestionsView().frame(maxWidth: .infinity, alignment: .leading) }
        case .control(let c):
            LogPaneView(lines: c.logLines,
                        footer: c.timerMode.map { AnyView(RunTimerBar(mode: $0)) },
                        terminalTheme: app.settings.terminalTheme)
        }
    }

    /// A tab pill: icon + project name (tap to select). Terminal tabs show a status dot that swaps to
    /// an ✕ on hover; the pressure tab is yellow with a warning glyph.
    private struct TabPill: View {
        let icon: String
        let name: String
        let help: String
        let isPressure: Bool
        let selected: Bool
        let tint: Color
        let onSelect: () -> Void
        let closeHelp: String
        let onClose: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                    Text(name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .help(help)

                trailing.frame(width: 14, height: 14)   // fixed slot so dot↔✕ never shifts layout
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(background, in: Capsule())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
        }

        private var foreground: Color {
            if isPressure { return selected ? .black : .pressureAmber }
            return selected ? .white : .primary
        }

        private var background: AnyShapeStyle {
            if isPressure {
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
                .help(closeHelp)
            } else {
                StatusDot(color: tint)
            }
        }
    }
}

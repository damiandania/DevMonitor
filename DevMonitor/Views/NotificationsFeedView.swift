import SwiftUI

/// The last 5 notifications as a "Recent" section inside the project sidebar list (most-recent
/// first), so it shares the same card surface as the Projects section. Tapping a row opens the
/// History window — the full persisted timeline these rows are a live preview of.
struct NotificationsFeedView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if !app.recentNotifications.isEmpty {
            Section("Recent") {
                ForEach(app.recentNotifications) { n in
                    Button {
                        openWindow(id: "history")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: n.icon).foregroundStyle(n.tint).frame(width: 16)
                            Text(n.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(n.date, format: .relative(presentation: .numeric))
                                .font(.caption)
                                .foregroundStyle(controlActiveState == .inactive ? .quaternary : .tertiary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(n.body)
                }
                // These rows aren't projects: without this, the enclosing `List(selection:)` treats
                // a click as selecting the row and writes the notification's UUID into
                // `selectedProjectID` (both are UUIDs) — which matches no project, so the detail pane
                // flips to "No project selected". Disabling selection lets the Button handle the tap.
                .selectionDisabled()
            }
        }
    }
}

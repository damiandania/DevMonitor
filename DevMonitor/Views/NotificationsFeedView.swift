import SwiftUI

/// The last 5 notifications as a "Recent" section inside the project sidebar list (most-recent
/// first), so it shares the same card surface as the Projects section. Tapping a row focuses the
/// related project (or the pressure tab for machine-wide events).
struct NotificationsFeedView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if !app.recentNotifications.isEmpty {
            Section("Recent") {
                ForEach(app.recentNotifications) { n in
                    Button {
                        app.focusFromNotification(projectID: n.projectID, showLogs: false)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: n.icon).foregroundStyle(n.tint).frame(width: 16)
                            Text(n.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(n.date, format: .relative(presentation: .numeric))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(n.body)
                }
            }
        }
    }
}

import SwiftUI

/// The last 5 notifications, pinned at the bottom of the project sidebar (most-recent first).
/// Tapping a row focuses the related project (or the pressure tab for machine-wide events).
struct NotificationsFeedView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if !app.recentNotifications.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text("Recent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                ForEach(app.recentNotifications) { n in
                    Button {
                        app.focusFromNotification(projectID: n.projectID, showLogs: false)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: n.icon).foregroundStyle(n.tint).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.title).font(.caption).lineLimit(1)
                                Text(n.date, format: .relative(presentation: .numeric))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(n.body)
                }
            }
            .padding(.bottom, 6)
            .background(.bar)
        }
    }
}

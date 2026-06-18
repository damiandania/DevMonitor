import SwiftUI

/// Per-project settings modal (opened from the gear on a sidebar project row): the server
/// configuration plus the project's folder and a remove action.
struct ProjectSettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(project.name) — Settings", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(project.path).font(.callout).textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    ServerConfigView(project: project)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button(role: .destructive) {
                        app.removeProject(project.id)
                        dismiss()
                    } label: {
                        Label("Remove project", systemImage: "trash")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 500, minHeight: 440)
    }
}

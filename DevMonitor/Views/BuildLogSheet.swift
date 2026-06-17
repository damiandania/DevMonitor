import SwiftUI

/// Shows a build's live log + result in a sheet.
struct BuildLogSheet: View {
    let build: BuildRunner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(build.buildCommand, systemImage: "hammer.fill")
                    .font(.headline)
                Spacer()
                statusBadge
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(build.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(white: 0.08))
                .onChange(of: build.logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder private var statusBadge: some View {
        if build.isRunning {
            Label("Building…", systemImage: "circle.fill").foregroundStyle(.orange)
        } else if let result = build.result {
            Label(result == 0 ? "Succeeded" : "Failed (\(result))",
                  systemImage: result == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result == 0 ? .green : .red)
        }
    }
}

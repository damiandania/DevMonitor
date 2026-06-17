import SwiftUI

/// P9 — shows Claude's read-only recommendations about heavy processes. Managed dev servers can be
/// stopped with one tap; foreign processes require an explicit confirmation before being closed.
struct AdvisorSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pendingClose: ResourceAdvisor.Recommendation?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Resource Advisor", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                Spacer()
                if !app.isAdvising {
                    Button { app.generateAdvice() } label: {
                        Label("Re-analyze", systemImage: "arrow.clockwise")
                    }
                    .buttonBorderShape(.capsule)
                }
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if app.isAdvising {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Claude is analyzing the machine…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let advice = app.advice {
                content(advice)
            } else {
                ContentUnavailableView("No analysis yet", systemImage: "gauge.with.dots.needle.67percent")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .confirmationDialog(
            pendingClose.map { "Close \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible
        ) {
            if let rec = pendingClose {
                Button("Close \(rec.name) (pid \(rec.id))", role: .destructive) { app.apply(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rec = pendingClose {
                Text("This sends SIGTERM to a process Dev Monitor does not manage.\n\n\(rec.reason)")
            }
        }
    }

    @ViewBuilder private func content(_ advice: ResourceAdvisor.Advice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !advice.summary.isEmpty {
                    Text(advice.summary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if advice.recommendations.isEmpty {
                    Text("No actions recommended — the machine looks healthy.")
                        .foregroundStyle(.secondary)
                }
                ForEach(advice.recommendations) { rec in
                    row(rec)
                }
            }
            .padding()
        }
        if advice.isError || advice.costUSD != nil {
            Divider()
            HStack {
                if advice.isError {
                    Label("claude reported an error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let cost = advice.costUSD {
                    Text(String(format: "claude · $%.4f", cost)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(8)
        }
    }

    @ViewBuilder private func row(_ rec: ResourceAdvisor.Recommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(severityColor(rec.severity))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if rec.managed {
                        Text("managed").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                }
                Text(rec.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actionButton(rec)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func actionButton(_ rec: ResourceAdvisor.Recommendation) -> some View {
        switch rec.action {
        case .stopDevServer:
            Button("Stop", systemImage: "stop.fill") { app.apply(rec) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .closeProcess:
            Button("Close…", systemImage: "xmark.circle") { pendingClose = rec }
                .controlSize(.small).tint(.red)
        case .investigate:
            Text("investigate").font(.caption).foregroundStyle(.orange)
        case .keep:
            Text("keep").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func severityColor(_ s: ResourceAdvisor.Severity) -> Color {
        switch s {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }
}

import SwiftUI

/// Shown above the server config when the machine is detected as stuck: a fast (Haiku) evaluation
/// of which heavy/orphan processes are safe to kill, each with a red skull button that kills it.
struct PressureSuggestionsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("System under pressure")
                Spacer()
                if app.isEvaluatingPressure { ProgressView().controlSize(.mini) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

            Text(app.systemSampler.pressureReason)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if app.killSuggestions.isEmpty {
                Text(app.isEvaluatingPressure ? "Finding processes to free up…"
                                              : "Nothing safe to kill automatically.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(app.killSuggestions) { rec in
                    row(rec)
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.10))
    }

    private func row(_ rec: ResourceAdvisor.Recommendation) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.name).font(.caption.weight(.medium)).lineLimit(1)
                Text(rec.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button {
                app.killSuggestion(rec)
            } label: {
                Image("skull")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .help(rec.action == .stopDevServer
                  ? "Stop the dev server"
                  : "Kill \(rec.name) (pid \(rec.id))")
        }
    }
}

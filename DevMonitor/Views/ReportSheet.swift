import SwiftUI

/// Shows a read-only Claude diagnostic report about Dev Monitor itself.
struct ReportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Diagnostic Report", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                if !app.isGeneratingReport {
                    Button { app.generateReport() } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonBorderShape(.capsule)
                }
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if app.isGeneratingReport {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Asking Claude to diagnose Dev Monitor…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = app.diagnosticReport {
                ScrollView {
                    Text(Self.markdown(report.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                if report.isError || report.costUSD != nil {
                    Divider()
                    HStack {
                        if report.isError {
                            Label("claude reported an error", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if let cost = report.costUSD {
                            Text(String(format: "claude · $%.4f", cost))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .padding(8)
                }
            } else {
                ContentUnavailableView("No report yet", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

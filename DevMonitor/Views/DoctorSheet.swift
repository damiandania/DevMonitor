import SwiftUI

/// The "Doctor" (stethoscope) panel — read-only AI analyses in three sections, each started and
/// stopped manually: Heavy Processes (advisor), Dev Monitor (self-diagnosis), and Memory & RAM.
struct DoctorSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .heavy

    enum Section: String, CaseIterable, Identifiable {
        case heavy = "Heavy Processes"
        case devMonitor = "Dev Monitor"
        case memory = "Memory & RAM"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .heavy: return "gauge.with.dots.needle.67percent"
            case .devMonitor: return "stethoscope"
            case .memory: return "memorychip"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Doctor", systemImage: "stethoscope").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 10)

            Divider()

            switch section {
            case .heavy: HeavyProcessesSection()
            case .devMonitor: DevMonitorSection()
            case .memory: MemorySection()
            }
        }
        .frame(minWidth: 660, minHeight: 520)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Heavy Processes (resource advisor)

private struct HeavyProcessesSection: View {
    @Environment(AppState.self) private var app
    @State private var pendingClose: ResourceAdvisor.Recommendation?

    var body: some View {
        VStack(spacing: 0) {
            SectionToolbar(title: "Heavy processes", busy: app.isAdvising, hasResult: app.advice != nil,
                           start: { app.generateAdvice() }, stop: { app.stopAdvice() })
            if app.isAdvising {
                Loading("Claude is analyzing the machine…")
            } else if let advice = app.advice {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !advice.summary.isEmpty {
                            Text(advice.summary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if advice.recommendations.isEmpty {
                            Text("No actions recommended — the machine looks healthy.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(advice.recommendations) { row($0) }
                    }
                    .padding()
                }
                CostFooter(isError: advice.isError, cost: advice.costUSD)
            } else {
                IdlePrompt("Analyze the machine's heaviest processes.") { app.generateAdvice() }
            }
        }
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

    private func row(_ rec: ResourceAdvisor.Recommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill").font(.system(size: 9))
                .foregroundStyle(color(rec.severity)).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.name).fontWeight(.semibold).lineLimit(1)
                    if rec.managed {
                        Text("managed").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                }
                Text(rec.reason).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action(rec)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func action(_ rec: ResourceAdvisor.Recommendation) -> some View {
        switch rec.action {
        case .stopDevServer:
            Button("Stop", systemImage: "stop.fill") { app.apply(rec) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .closeProcess:
            Button("Close…", systemImage: "xmark.circle") { pendingClose = rec }
                .controlSize(.small).tint(.red)
        case .investigate: Text("investigate").foregroundStyle(.orange)
        case .keep: Text("keep").foregroundStyle(.secondary)
        }
    }

    private func color(_ s: ResourceAdvisor.Severity) -> Color {
        switch s { case .high: return .red; case .medium: return .orange; case .low: return .secondary }
    }
}

// MARK: - Dev Monitor self-diagnosis & Memory report

private struct DevMonitorSection: View {
    @Environment(AppState.self) private var app
    var body: some View {
        ReportView(title: "Diagnose Dev Monitor", prompt: "Diagnose Dev Monitor's own errors.",
                   busy: app.isGeneratingReport, report: app.diagnosticReport,
                   start: { app.generateReport() }, stop: { app.stopReport() })
    }
}

private struct MemorySection: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            MemoryBars()
            Divider()
            ReportView(title: "How to free RAM", prompt: "Analyze how to free RAM (and swap).",
                       busy: app.isGeneratingMemoryReport, report: app.memoryReport,
                       start: { app.generateMemoryReport() }, stop: { app.stopMemoryReport() })
        }
    }
}

private struct MemoryBars: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let s = app.systemSampler
        HStack(spacing: 22) {
            bar("Memory", percent: s.systemMemPercent, color: .purple,
                detail: String(format: "%.1f / %.0f GB", s.systemMemUsed / 1_073_741_824, s.totalMem / 1_073_741_824))
            bar("Swap", percent: s.systemSwapPercent, color: .orange,
                detail: s.systemSwapTotal > 0 ? String(format: "%.1f / %.0f GB", s.systemSwapUsed / 1_073_741_824, s.systemSwapTotal / 1_073_741_824) : "off")
        }
        .padding()
    }
    private func bar(_ t: String, percent: Double, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(t).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            }
            ProgressView(value: min(max(percent / 100, 0), 1)).tint(color)
        }
    }
}

private struct ReportView: View {
    let title: String
    let prompt: String
    let busy: Bool
    let report: ClaudeRunner.Report?
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SectionToolbar(title: title, busy: busy, hasResult: report != nil, start: start, stop: stop)
            if busy {
                Loading("Asking Claude…")
            } else if let report {
                ScrollView {
                    Text(DoctorSheet.markdown(report.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                CostFooter(isError: report.isError, cost: report.costUSD)
            } else {
                IdlePrompt(prompt, start: start)
            }
        }
    }
}

// MARK: - shared pieces

private struct SectionToolbar: View {
    let title: String
    let busy: Bool
    let hasResult: Bool
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if busy {
                Button(role: .destructive) { stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonBorderShape(.capsule).controlSize(.small).tint(.red)
            } else {
                Button { start() } label: {
                    Label(hasResult ? "Re-analyze" : "Analyze",
                          systemImage: hasResult ? "arrow.clockwise" : "play.fill")
                }
                .buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
}

private struct IdlePrompt: View {
    let text: String
    let start: () -> Void
    init(_ text: String, start: @escaping () -> Void) { self.text = text; self.start = start }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
            Button { start() } label: { Label("Analyze", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Loading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(spacing: 12) { ProgressView(); Text(text).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CostFooter: View {
    let isError: Bool
    let cost: Double?
    var body: some View {
        if isError || cost != nil {
            Divider()
            HStack {
                if isError {
                    Label("claude reported an error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let cost { Text(String(format: "claude · $%.4f", cost)).foregroundStyle(.secondary) }
            }
            .font(.caption).padding(8)
        }
    }
}

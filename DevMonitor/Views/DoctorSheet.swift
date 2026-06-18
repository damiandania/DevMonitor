import SwiftUI

/// The "Doctor" window — sidebar with the three analyses; detail with a big circular Analyze button
/// (top-right, switches to Stop while running) and the read-only AI result. Closed by the window's
/// red traffic-light button. Nothing runs until you press Analyze.
struct DoctorSheet: View {
    @Environment(AppState.self) private var app
    @State private var section: Section = .heavy

    enum Section: String, CaseIterable, Identifiable {
        case heavy, devMonitor, memory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .heavy: return "Heavy Processes"
            case .devMonitor: return "Dev Monitor"
            case .memory: return "Memory & RAM"
            }
        }
        var icon: String {
            switch self {
            case .heavy: return "gauge.with.dots.needle.67percent"
            case .devMonitor: return "stethoscope"
            case .memory: return "memorychip"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .navigationTitle("Doctor")
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail.navigationTitle(section.title)
        }
        .frame(minWidth: 800, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .heavy: HeavyDetail()
        case .devMonitor: ReportDetail(kind: .devMonitor)
        case .memory: ReportDetail(kind: .memory)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// The big circular Analyze button (top-right); becomes a red Stop while running.
private struct CircleAction: View {
    let busy: Bool
    let start: () -> Void
    let stop: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button { busy ? stop() : start() } label: {
                Image(systemName: busy ? "stop.fill" : "sparkles")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(busy ? .red : .accentColor)
            .help(busy ? "Stop analysis" : "Analyze")
        }
        .padding([.top, .horizontal])
    }
}

// MARK: - Heavy Processes

private struct HeavyDetail: View {
    @Environment(AppState.self) private var app
    @State private var pendingClose: ResourceAdvisor.Recommendation?

    var body: some View {
        VStack(spacing: 0) {
            CircleAction(busy: app.isAdvising, start: { app.generateAdvice() }, stop: { app.stopAdvice() })
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
                Idle("Analyze the machine's heaviest processes and what's safe to close.")
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

// MARK: - Dev Monitor diagnosis & Memory report

private struct ReportDetail: View {
    enum Kind { case devMonitor, memory }
    @Environment(AppState.self) private var app
    let kind: Kind

    private var busy: Bool { kind == .devMonitor ? app.isGeneratingReport : app.isGeneratingMemoryReport }
    private var report: ClaudeRunner.Report? { kind == .devMonitor ? app.diagnosticReport : app.memoryReport }
    private func start() { if kind == .devMonitor { app.generateReport() } else { app.generateMemoryReport() } }
    private func stop() { if kind == .devMonitor { app.stopReport() } else { app.stopMemoryReport() } }

    var body: some View {
        VStack(spacing: 0) {
            CircleAction(busy: busy, start: start, stop: stop)
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
                Idle(kind == .devMonitor
                     ? "Diagnose Dev Monitor's own internal errors (read-only)."
                     : "Analyze how to free up RAM (and what can be done about swap).")
            }
        }
    }
}

// MARK: - shared

private struct Idle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
            HStack {
                if isError {
                    Label("claude reported an error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let cost { Text(String(format: "claude · $%.4f", cost)).foregroundStyle(.secondary) }
            }
            .font(.caption).padding(.horizontal).padding(.bottom, 8)
        }
    }
}

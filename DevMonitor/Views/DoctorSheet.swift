import SwiftUI

/// The "Doctor" window. Sidebar = the three analyses; detail = an Apple-style list of processes to
/// close (Heavy / Memory) or a text diagnosis (Dev Monitor). The big circular Analyze button sits in
/// the top-right corner and flips to a red Stop while running. Nothing runs until you press it.
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
                    SectionRow(section: s, busy: busy(s), hasResult: hasResult(s),
                               stop: { stop(s) }, reanalyze: { start(s) })
                        .tag(s)
                }
            }
            .navigationTitle("Doctor")
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail.navigationTitle(section.title)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let b = busy(section), r = hasResult(section)
                // The button itself is the coloured circle (prominent + .circle shape) so there's no
                // white toolbar bezel/glass pill around it — drawing our own circle left the system
                // background showing as a white halo.
                Button { b ? stop(section) : start(section) } label: {
                    Image(systemName: b ? "stop.fill" : (r ? "arrow.clockwise" : "play.fill"))
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(b ? .red : .accentColor)
                .help(b ? "Stop analysis" : (r ? "Re-analyze" : "Analyze"))
            }
        }
        .frame(minWidth: 820, minHeight: 580)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .heavy:
            AdviceList(advice: app.advice, busy: app.isAdvising,
                       idle: "Analyze the machine's heaviest processes and what's safe to close.",
                       freeAllTitle: nil)
        case .devMonitor:
            DiagnosisDetail()
        case .memory:
            AdviceList(advice: app.memoryAdvice, busy: app.isGeneratingMemory,
                       idle: "Find the biggest memory hogs and what to close to free RAM.",
                       freeAllTitle: "Free memory")
        }
    }

    // Per-section analyze state/actions (so the sidebar shows each tab's progress, not just the
    // selected one).
    private func busy(_ s: Section) -> Bool {
        switch s {
        case .heavy: return app.isAdvising
        case .devMonitor: return app.isGeneratingReport
        case .memory: return app.isGeneratingMemory
        }
    }
    private func hasResult(_ s: Section) -> Bool {
        switch s {
        case .heavy: return app.advice != nil
        case .devMonitor: return app.diagnosticReport != nil
        case .memory: return app.memoryAdvice != nil
        }
    }
    private func start(_ s: Section) {
        switch s {
        case .heavy: app.generateAdvice()
        case .devMonitor: app.generateReport()
        case .memory: app.generateMemory()
        }
    }
    private func stop(_ s: Section) {
        switch s {
        case .heavy: app.stopAdvice()
        case .devMonitor: app.stopReport()
        case .memory: app.stopMemory()
        }
    }
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// A Doctor sidebar row: title + a status accessory on the right so you can see which tab is
/// working even when it isn't selected — a spinner while analyzing (hover → red Stop), or a green
/// check once done (hover → Reset).
private struct SectionRow: View {
    let section: DoctorSheet.Section
    let busy: Bool
    let hasResult: Bool
    let stop: () -> Void
    let reanalyze: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.icon)
            Spacer()
            status
                .frame(width: 22, height: 22)
                .onHover { hovering = $0 }
        }
    }

    @ViewBuilder private var status: some View {
        if busy {
            if hovering {
                Button(action: stop) { badge("stop.fill", .red) }.buttonStyle(.plain).help("Stop")
            } else {
                ProgressView().controlSize(.small)
            }
        } else if hasResult {
            if hovering {
                Button(action: reanalyze) { badge("arrow.clockwise", .accentColor) }
                    .buttonStyle(.plain).help("Re-analyze")
            } else {
                badge("checkmark", .green)
            }
        }
    }

    /// A small colored circle with a white glyph. `.drawingGroup()` rasterises it into an opaque
    /// bitmap so the macOS selection vibrancy can't darken the colour on the blue selected row —
    /// the same fix as the sidebar's running dot. No white ring/background.
    private func badge(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color))
            .drawingGroup()
    }
}

// MARK: - Advice list (Heavy Processes & Memory) — Apple-style grouped rows

private struct AdviceList: View {
    @Environment(AppState.self) private var app
    let advice: ResourceAdvisor.Advice?
    let busy: Bool
    let idle: String
    /// When set, shows a prominent button that closes every recommended process at once.
    let freeAllTitle: String?

    @State private var pendingClose: ResourceAdvisor.Recommendation?
    @State private var confirmAll = false

    private var closeable: [ResourceAdvisor.Recommendation] {
        (advice?.recommendations ?? []).filter { $0.action == .closeProcess || $0.action == .stopDevServer }
    }

    var body: some View {
        Group {
            if busy {
                Loading("Asking Claude…")
            } else if let advice {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !advice.summary.isEmpty {
                            Text(advice.summary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let freeAllTitle, !closeable.isEmpty {
                            Button { confirmAll = true } label: {
                                Label(freeAllTitle, systemImage: "sparkles").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        if closeable.isEmpty {
                            Text("Nothing recommended to close — looks healthy.").foregroundStyle(.secondary)
                        } else {
                            list
                        }
                    }
                    .padding()
                }
                CostFooter(isError: advice.isError, cost: advice.costUSD)
            } else {
                Idle(idle)
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
            if let rec = pendingClose { Text(rec.reason) }
        }
        .confirmationDialog(
            "Close \(closeable.count) process\(closeable.count == 1 ? "" : "es") to free memory?",
            isPresented: $confirmAll, titleVisibility: .visible
        ) {
            Button("Close \(closeable.count) and free memory", role: .destructive) { app.applyAll(closeable) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(closeable.map(\.name).joined(separator: ", "))
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(closeable.enumerated()), id: \.element.id) { i, rec in
                row(rec)
                if i < closeable.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ rec: ResourceAdvisor.Recommendation) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color(rec.severity)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.name).fontWeight(.medium).lineLimit(1)
                    if rec.managed {
                        Text("managed").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                }
                Text(rec.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                if rec.action == .stopDevServer {
                    Button { app.apply(rec) } label: { Label("Stop dev server", systemImage: "stop.fill") }
                } else {
                    Button(role: .destructive) { pendingClose = rec } label: {
                        Label("Close \(rec.name)", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().strokeBorder(.tertiary))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func color(_ s: ResourceAdvisor.Severity) -> Color {
        switch s { case .high: return .red; case .medium: return .orange; case .low: return .secondary }
    }
}

// MARK: - Dev Monitor diagnosis (text report)

private struct DiagnosisDetail: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if app.isGeneratingReport {
            Loading("Asking Claude…")
        } else if let report = app.diagnosticReport {
            ScrollView {
                Text(DoctorSheet.markdown(report.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            CostFooter(isError: report.isError, cost: report.costUSD)
        } else {
            Idle("Diagnose Dev Monitor's own internal errors (read-only).")
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

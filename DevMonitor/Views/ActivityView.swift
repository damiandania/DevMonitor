import SwiftUI

/// Global activity card: system CPU / Memory / Swap meters + the process table (all processes;
/// each supervised server its own row, external dev servers identified). Not tied to a project.
struct ActivityView: View {
    @Environment(AppState.self) private var app
    @State private var percentOfMachine = false
    /// Collapsed by default: the card shows just the meters until the user expands the process list.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            meterRow
            // Disclosure region: the table is always in the hierarchy but collapses to zero height
            // and is clipped, so expand/collapse is a smooth accordion (height + opacity) driven by
            // a single spring on the card — no content spilling past the card edge mid-animation.
            VStack(spacing: 0) {
                expandButton
                ProcessTableView(sampler: app.systemSampler, percentOfMachine: $percentOfMachine)
                    .frame(height: expanded ? 240 : 0)
                    .padding(.top, expanded ? 10 : 0)
                    .opacity(expanded ? 1 : 0)
                    .clipped()
                    .accessibilityHidden(!expanded)
            }
        }
        .dmCard()
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Activity", systemImage: "cpu").font(.headline)
            Spacer()
            if expanded {
                Toggle(isOn: $percentOfMachine) {
                    Text("% of machine").font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    /// Disclosure control under the meters that opens the process table downward.
    private var expandButton: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(expanded ? "Hide processes" : "Show processes")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Meters

    private struct Meter: Identifiable {
        let id: String
        let title: String
        let percent: Double      // 0…100
        let detail: String
        let color: Color
        let icon: String
    }

    /// The meters to render, in the order the user configured in settings.
    private var meters: [Meter] {
        let s = app.systemSampler
        let gb = 1_073_741_824.0
        func ratio(_ used: Double, _ total: Double) -> String {
            String(format: "%.1f / %.0f GB", used / gb, total / gb)
        }
        return app.settings.bars.compactMap { id in
            switch id {
            case "cpu":
                return Meter(id: id, title: "CPU", percent: s.systemCPU,
                             detail: "\(Int(s.systemCPU))%", color: .blue, icon: "cpu")
            case "memory":
                return Meter(id: id, title: "Memory", percent: s.systemMemPercent,
                             detail: ratio(s.systemMemUsed, s.totalMem), color: .purple, icon: "memorychip")
            case "swap":
                return Meter(id: id, title: "Swap", percent: s.systemSwapPercent,
                             detail: s.systemSwapTotal > 0 ? ratio(s.systemSwapUsed, s.systemSwapTotal) : "off",
                             color: .orange, icon: "arrow.left.arrow.right")
            case "load":
                return Meter(id: id, title: "Load", percent: min(100, s.loadAverage / Double(s.coreCount) * 100),
                             detail: String(format: "%.2f", s.loadAverage), color: .teal, icon: "speedometer")
            case "devcpu":
                return Meter(id: id, title: "Dev CPU", percent: min(100, s.devTreeCPU / Double(s.coreCount)),
                             detail: "\(Int(s.devTreeCPU))%", color: .green, icon: "server.rack")
            case "devmem":
                return Meter(id: id, title: "Dev RAM", percent: s.totalMem > 0 ? s.devTreeMem / s.totalMem * 100 : 0,
                             detail: String(format: "%.0f MB", s.devTreeMem / 1_048_576), color: .green, icon: "server.rack")
            default:
                return nil
            }
        }
    }

    private var meterRow: some View {
        HStack(spacing: 10) {
            ForEach(meters) { meterTile($0) }
        }
    }

    private func meterTile(_ m: Meter) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: m.icon).font(.caption2).foregroundStyle(m.color)
                Text(m.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(m.detail)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(m.color)
            }
            MeterBar(value: min(max(m.percent / 100, 0), 1), color: m.color)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(m.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A rounded capsule meter with a neutral track — replaces the thin gray `ProgressView`.
private struct MeterBar: View {
    let value: Double      // 0…1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: value > 0 ? max(5, geo.size.width * value) : 0)
            }
        }
        .frame(height: 6)
    }
}

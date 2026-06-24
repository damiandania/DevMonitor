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
                .help("Show each process's CPU as a share of the whole machine instead of per-core")
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
        .help(expanded ? "Hide the process list" : "Show the process list")
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
                             detail: ratio(s.systemMemUsed, s.totalMem), color: .indigo, icon: "memorychip")
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

    /// Adaptive grid: tiles keep a comfortable min width and wrap to more rows as the bar count
    /// grows / the window narrows — instead of cramming everything onto one row and wrapping text.
    private var meterRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(meters) { m in
                MeterTile(title: m.title, detail: m.detail,
                          fraction: min(max(m.percent / 100, 0), 1),
                          color: m.color, icon: m.icon, help: meterHelp(m))
            }
        }
    }

    /// Human description + live value for a meter tile, shown on hover.
    private func meterHelp(_ m: Meter) -> String {
        let desc: String
        switch m.id {
        case "cpu":    desc = "System CPU usage across all cores"
        case "memory": desc = "System memory in use / total"
        case "swap":   desc = "Swap space in use / total"
        case "load":   desc = "1-minute load average"
        case "devcpu": desc = "CPU used by the dev-server process tree"
        case "devmem": desc = "Memory used by the dev-server process tree"
        default:       desc = m.title
        }
        return "\(desc) — \(m.detail)"
    }
}

/// One activity meter rendered as a tile (icon + title, the value, a capsule bar). Shared by EVERY
/// meter so they all look identical — fixed type sizes, so a longer value like "12.4 / 14 GB" never
/// renders at a different scale than a shorter one like "5.8 / 8 GB". The adaptive grid keeps each
/// tile wide enough for the longest value, so `lineLimit(1)` alone prevents wrapping (no shrinking).
private struct MeterTile: View {
    let title: String
    let detail: String
    let fraction: Double   // 0…1
    let color: Color
    let icon: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(detail).font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color).lineLimit(1)
            }
            MeterBar(value: fraction, color: color)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
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

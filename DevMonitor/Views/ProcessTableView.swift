import SwiftUI

/// Activity-Monitor-style list of the heaviest system processes. A custom row list (not the
/// native `Table`) so it sits flush on the card with hover highlighting, tinted dev-server rows
/// and right-aligned monospaced metrics.
struct ProcessTableView: View {
    let sampler: SystemSampler
    @Binding var percentOfMachine: Bool

    private let cpuWidth: CGFloat = 60
    private let memWidth: CGFloat = 82

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sampler.processes) { row in
                        ProcessRowView(row: row,
                                       cpuText: cpuText(row.cpuPerCore),
                                       cpuColor: cpuColor(row.cpuPerCore),
                                       memText: memText(row.memBytes),
                                       cpuWidth: cpuWidth, memWidth: memWidth)
                    }
                }
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: cpuWidth, alignment: .trailing)
            Text("Memory").frame(width: memWidth, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func cpuText(_ perCore: Double) -> String {
        if percentOfMachine {
            return String(format: "%.1f%%", perCore / Double(sampler.coreCount))
        }
        return String(format: "%.0f%%", perCore)
    }

    private func memText(_ bytes: Double) -> String {
        if percentOfMachine, sampler.totalMem > 0 {
            return String(format: "%.1f%%", bytes / sampler.totalMem * 100)
        }
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", bytes / 1_073_741_824)
        }
        return "\(Int(bytes / 1_048_576)) MB"
    }

    private func cpuColor(_ perCore: Double) -> Color {
        let normalized = perCore / Double(sampler.coreCount)
        if normalized > 50 || perCore > 90 { return .red }
        if normalized > 15 || perCore > 40 { return .orange }
        return .primary
    }
}

/// A single process row: icon + name on the left, CPU/Memory right-aligned. Supervised servers,
/// external dev servers and builds get a tinted background and a colored name so they stand out.
private struct ProcessRowView: View {
    let row: ProcessRow
    let cpuText: String
    let cpuColor: Color
    let memText: String
    let cpuWidth: CGFloat
    let memWidth: CGFloat

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                icon.frame(width: 15, alignment: .center)
                Text(row.name)
                    .fontWeight(emphasized ? .semibold : .regular)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(cpuText).monospacedDigit().foregroundStyle(cpuColor)
                .frame(width: cpuWidth, alignment: .trailing)
            Text(memText).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: memWidth, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if row.isDevServer {
            Image(systemName: "server.rack").foregroundStyle(.tint)
        } else if row.isExternalDev {
            // Same glyph as a managed server, but purple = running outside the app.
            Image(systemName: "server.rack").foregroundStyle(Color.purple)
        } else if row.isBuild {
            Image(systemName: "hammer.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
        }
    }

    private var emphasized: Bool { row.isDevServer || row.isExternalDev || row.isBuild }

    private var accent: Color {
        if row.isDevServer { return .accentColor }
        if row.isExternalDev { return .purple }
        if row.isBuild { return .orange }
        return .primary
    }

    private var nameColor: Color { emphasized ? accent : .primary }

    private var rowBackground: Color {
        if emphasized { return accent.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}

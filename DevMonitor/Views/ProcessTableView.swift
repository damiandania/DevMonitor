import SwiftUI

/// Activity-Monitor-style table of the heaviest system processes.
struct ProcessTableView: View {
    let sampler: SystemSampler
    @Binding var percentOfMachine: Bool

    var body: some View {
        Table(sampler.processes) {
            TableColumn("Process") { row in
                HStack(spacing: 6) {
                    if row.isDevServer {
                        Image(systemName: "server.rack").foregroundStyle(.tint)
                    } else if row.isExternalDev {
                        // Same format as a managed server, but purple = running outside the app.
                        Image(systemName: "server.rack").foregroundStyle(Color.purple)
                    } else if row.isBuild {
                        Image(systemName: "hammer.fill").foregroundStyle(.orange)
                    }
                    Text(row.name)
                        .fontWeight(row.isDevServer || row.isBuild || row.isExternalDev ? .semibold : .regular)
                        .foregroundStyle(row.isDevServer ? Color.accentColor
                                         : row.isExternalDev ? Color.purple
                                         : (row.isBuild ? Color.orange : .primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("CPU") { row in
                Text(cpuText(row.cpuPerCore))
                    .monospacedDigit()
                    .foregroundStyle(cpuColor(row.cpuPerCore))
            }
            .width(min: 64, ideal: 72)
            TableColumn("Memory") { row in
                Text(memText(row.memBytes)).monospacedDigit()
            }
            .width(min: 80, ideal: 92)
        }
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

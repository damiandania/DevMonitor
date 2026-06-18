import SwiftUI

/// Server configuration: each setting has an **Auto** toggle on the right (on by default); turning
/// it off reveals a manual control between the name and the toggle — a slider for memory, a field
/// for the port, the package-manager picker for the package.
struct ServerConfigView: View {
    @Environment(AppState.self) private var app
    let project: Project

    /// Always read the live project from app state so the toggles/bindings reflect the latest value
    /// (the passed-in `project` is a snapshot — it wouldn't update after a setter runs).
    private var live: Project { app.projects.first { $0.id == project.id } ?? project }
    private var running: Bool { app.session(for: project)?.state.isActive ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Server configuration")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            memoryRow
            portRow
            packageRow

            if running {
                Text("Changes apply on the next launch.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25))
    }

    // MARK: rows

    private var memoryRow: some View {
        let auto = Binding(get: { live.memoryAuto },
                           set: { app.setMemoryAuto($0, for: project.id) })
        return row(icon: "memorychip", name: "Memory", auto: auto,
                   autoValue: "\(Detector.defaultMemoryGB(for: live.framework)) GB") {
            HStack(spacing: 6) {
                Slider(value: Binding(get: { Double(live.memoryGB) },
                                      set: { app.setMemoryGB(Int($0), for: project.id) }),
                       in: 1...16, step: 1)
                    .frame(width: 78)
                Text("\(live.memoryGB) GB")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var portRow: some View {
        let auto = Binding(get: { live.port == nil },
                           set: { isAuto in app.setPort(isAuto ? nil : (live.port ?? 3000), for: project.id) })
        return row(icon: "network", name: "Port", auto: auto, autoValue: "auto") {
            TextField("3000", value: Binding(get: { live.port },
                                             set: { app.setPort($0, for: project.id) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
        }
    }

    private var packageRow: some View {
        let auto = Binding(get: { live.packageManagerAuto },
                           set: { app.setPackageManagerAuto($0, for: project.id) })
        return row(icon: "shippingbox", name: "Package", auto: auto,
                   autoValue: live.packageManager.rawValue) {
            Picker("", selection: Binding(get: { live.packageManager },
                                          set: { app.setPackageManager($0, for: project.id) })) {
                ForEach(PackageManager.allCases, id: \.self) { pm in
                    Text(pm.rawValue).tag(pm)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: row scaffold

    @ViewBuilder private func row<Manual: View>(
        icon: String, name: String, auto: Binding<Bool>, autoValue: String,
        @ViewBuilder manual: () -> Manual
    ) -> some View {
        HStack(spacing: 8) {
            Label(name, systemImage: icon)
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if auto.wrappedValue {
                Text(autoValue).font(.caption).foregroundStyle(.secondary)
            } else {
                manual()
            }
            Toggle("Auto", isOn: auto)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption2)
                .fixedSize()
                .help(auto.wrappedValue ? "Auto — using the detected value" : "Manual")
        }
        .controlSize(.small)
    }
}

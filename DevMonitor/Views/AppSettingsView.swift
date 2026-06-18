import SwiftUI

/// The single Settings modal (toolbar gear), styled like macOS System Settings: a **General**
/// section (browser / analysis model / behavior) followed by one section per project with its
/// server configuration.
struct AppSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            Form {
                Section("General") {
                    Picker("Open servers in", selection: browser) {
                        Text("System default").tag(String?.none)
                        ForEach(app.installedBrowsers, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    Picker("Analysis model", selection: model) {
                        ForEach(AppSettings.models) { m in Text(m.label).tag(m.id) }
                    }
                    Toggle("Auto-close orphaned dev processes under pressure", isOn: autoClose)
                    Stepper("Default heap for new projects: \(app.settings.defaultMemoryGB) GB",
                            value: defaultMem, in: 1...32)
                }

                ForEach(app.projects) { project in
                    Section(project.name) {
                        memoryRow(project)
                        portRow(project)
                        packageRow(project)
                        Button(role: .destructive) { app.removeProject(project.id) } label: {
                            Label("Remove project", systemImage: "trash")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    // MARK: per-project server config rows (label left, control + Auto switch right)

    private func memoryRow(_ p: Project) -> some View {
        let auto = Binding(get: { p.memoryAuto }, set: { app.setMemoryAuto($0, for: p.id) })
        return LabeledContent {
            HStack(spacing: 10) {
                if auto.wrappedValue {
                    Text("\(Detector.defaultMemoryGB(for: p.framework)) GB").foregroundStyle(.secondary)
                } else {
                    Slider(value: Binding(get: { Double(p.memoryGB) },
                                          set: { app.setMemoryGB(Int($0), for: p.id) }),
                           in: 1...16, step: 1).frame(width: 120)
                    Text("\(p.memoryGB) GB").monospacedDigit().frame(width: 46, alignment: .trailing)
                }
                autoToggle(auto)
            }
        } label: { Label("Memory", systemImage: "memorychip") }
    }

    private func portRow(_ p: Project) -> some View {
        let auto = Binding(get: { p.port == nil },
                           set: { isAuto in app.setPort(isAuto ? nil : (p.port ?? 3000), for: p.id) })
        return LabeledContent {
            HStack(spacing: 10) {
                if auto.wrappedValue {
                    Text("auto").foregroundStyle(.secondary)
                } else {
                    TextField("3000", value: Binding(get: { p.port }, set: { app.setPort($0, for: p.id) }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
                autoToggle(auto)
            }
        } label: { Label("Port", systemImage: "network") }
    }

    private func packageRow(_ p: Project) -> some View {
        let auto = Binding(get: { p.packageManagerAuto }, set: { app.setPackageManagerAuto($0, for: p.id) })
        return LabeledContent {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { p.packageManager },
                                              set: { app.setPackageManager($0, for: p.id) })) {
                    ForEach(PackageManager.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize().disabled(auto.wrappedValue)
                autoToggle(auto)
            }
        } label: { Label("Package", systemImage: "shippingbox") }
    }

    private func autoToggle(_ auto: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Text("Auto").font(.caption).foregroundStyle(.secondary)
            Toggle("", isOn: auto).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    // MARK: general bindings that persist on change

    private var browser: Binding<String?> {
        .init(get: { app.settings.browser }, set: { app.settings.browser = $0; app.persistSettings() })
    }
    private var model: Binding<String> {
        .init(get: { app.settings.analysisModel }, set: { app.settings.analysisModel = $0; app.persistSettings() })
    }
    private var autoClose: Binding<Bool> {
        .init(get: { app.settings.autoCloseOrphans }, set: { app.settings.autoCloseOrphans = $0; app.persistSettings() })
    }
    private var defaultMem: Binding<Int> {
        .init(get: { app.settings.defaultMemoryGB }, set: { app.settings.defaultMemoryGB = $0; app.persistSettings() })
    }
}

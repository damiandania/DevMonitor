import SwiftUI

/// Settings modal styled like macOS System Settings: a left sidebar (General + one row per project)
/// and a grouped-form detail pane on the right. Server config defaults to Auto.
struct AppSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Item = .general

    enum Item: Hashable {
        case general
        case project(Project.ID)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(Item.general)
                Section("Projects") {
                    ForEach(app.projects) { p in
                        Label { Text(p.name) } icon: { ProjectIconView(project: p, size: 16) }
                            .tag(Item.project(p.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { Button("Done") { dismiss() } }
                }
        }
        .frame(minWidth: 740, minHeight: 540)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:
            GeneralSettings()
        case .project(let id):
            if let p = app.projects.first(where: { $0.id == id }) {
                ProjectSettings(project: p) { selection = .general }
            } else {
                ContentUnavailableView("Project removed", systemImage: "folder.badge.minus")
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Section("Browser") {
                Picker("Open servers in", selection: browser) {
                    Text("System default").tag(String?.none)
                    ForEach(app.installedBrowsers, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Section("AI analysis") {
                Picker("Model", selection: model) {
                    ForEach(AppSettings.models) { Text($0.label).tag($0.id) }
                }
                LabeledContent("Used for") {
                    Text("Doctor: heavy processes, Dev Monitor diagnosis, memory.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Behavior") {
                Toggle("Auto-close orphaned dev processes under pressure", isOn: autoClose)
                Picker("Default heap for new projects", selection: defaultMem) {
                    ForEach(1...max(systemMaxGB, app.settings.defaultMemoryGB), id: \.self) {
                        Text("\($0) GB").tag($0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    /// Heap options cap at the machine's physical RAM.
    private var systemMaxGB: Int { max(1, Int((app.systemSampler.totalMem / 1_073_741_824).rounded())) }

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

// MARK: - Per-project

private struct ProjectSettings: View {
    @Environment(AppState.self) private var app
    let project: Project
    let onRemoved: () -> Void

    private var live: Project { app.projects.first { $0.id == project.id } ?? project }

    var body: some View {
        Form {
            Section("Server") {
                memoryRow
                portRow
                packageRow
            }
            Section {
                LabeledContent("Folder") {
                    Text(live.path).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button(role: .destructive) {
                    app.removeProject(project.id); onRemoved()
                } label: {
                    Label("Remove project", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
    }

    /// Heap options cap at the machine's physical RAM (always include the current value).
    private var systemMaxGB: Int { max(1, Int((app.systemSampler.totalMem / 1_073_741_824).rounded())) }

    private var memoryRow: some View {
        let auto = Binding(get: { live.memoryAuto }, set: { app.setMemoryAuto($0, for: project.id) })
        return LabeledContent {
            HStack(spacing: 12) {
                if auto.wrappedValue {
                    Text("\(Detector.defaultMemoryGB(for: live.framework)) GB").foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(get: { live.memoryGB },
                                                  set: { app.setMemoryGB($0, for: project.id) })) {
                        ForEach(1...max(systemMaxGB, live.memoryGB), id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                autoToggle(auto)
            }
        } label: { Label("Memory", systemImage: "memorychip") }
    }

    private var portRow: some View {
        let auto = Binding(get: { live.port == nil },
                           set: { isAuto in app.setPort(isAuto ? nil : (live.port ?? 3000), for: project.id) })
        return LabeledContent {
            HStack(spacing: 12) {
                if auto.wrappedValue {
                    Text("auto").foregroundStyle(.secondary)
                } else {
                    TextField("3000", value: Binding(get: { live.port }, set: { app.setPort($0, for: project.id) }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 74)
                }
                autoToggle(auto)
            }
        } label: { Label("Port", systemImage: "network") }
    }

    private var packageRow: some View {
        let auto = Binding(get: { live.packageManagerAuto }, set: { app.setPackageManagerAuto($0, for: project.id) })
        return LabeledContent {
            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { live.packageManager },
                                              set: { app.setPackageManager($0, for: project.id) })) {
                    ForEach(PackageManager.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize().disabled(auto.wrappedValue)
                autoToggle(auto)
            }
        } label: { Label("Package", systemImage: "shippingbox") }
    }

    private func autoToggle(_ auto: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text("Auto").foregroundStyle(.secondary)
            Toggle("", isOn: auto).labelsHidden().toggleStyle(.switch)
        }
    }
}

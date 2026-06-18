import SwiftUI

/// Settings modal styled like macOS System Settings: a left sidebar (General + one row per project)
/// and a grouped-form detail pane on the right. Server config defaults to Auto.
struct AppSettingsView: View {
    @Environment(AppState.self) private var app
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
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
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
            ClaudeHookSection()
            Section("Appearance") {
                Picker("Theme", selection: theme) {
                    ForEach(AppSettings.themes) { t in
                        Label(t.label, systemImage: t.icon).tag(t.id)
                    }
                }
                Picker("Terminal", selection: terminalTheme) {
                    ForEach(AppSettings.terminalThemes) { t in
                        Label(t.label, systemImage: t.icon).tag(t.id)
                    }
                }
            }
            Section("Open in") {
                Picker("Browser (Open)", selection: browser) {
                    Text("System default").tag(String?.none)
                    ForEach(app.installedBrowsers, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Editor (Code)", selection: editor) {
                    ForEach(app.installedEditors, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Activity bars") {
                ForEach(AppSettings.allBars) { bar in
                    Toggle(bar.label, isOn: barBinding(bar.id))
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
    private var editor: Binding<String> {
        .init(get: { app.settings.editor ?? app.installedEditors.first ?? "" },
              set: { app.settings.editor = $0; app.persistSettings() })
    }
    private func barBinding(_ id: String) -> Binding<Bool> {
        .init(get: { app.settings.bars.contains(id) }, set: { on in
            if on {
                if !app.settings.bars.contains(id) { app.settings.bars.append(id) }
            } else {
                app.settings.bars.removeAll { $0 == id }
            }
            app.persistSettings()
        })
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
    private var theme: Binding<String> {
        .init(get: { app.settings.theme }, set: {
            app.settings.theme = $0; app.persistSettings(); AppSettings.applyAppearance($0)
        })
    }
    private var terminalTheme: Binding<String> {
        .init(get: { app.settings.terminalTheme }, set: { app.settings.terminalTheme = $0; app.persistSettings() })
    }
}

// MARK: - Claude Code hook (install / uninstall)

/// Lets the user install (or remove) the global Claude Code hook that makes OTHER Claude sessions
/// route dev servers through this app instead of launching them themselves. Shown first in General.
private struct ClaudeHookSection: View {
    @State private var installed = ClaudeHookInstaller.isInstalled
    @State private var error: String?

    var body: some View {
        Section("Claude Code") {
            LabeledContent("Route dev servers through the app") {
                Label(installed ? "Installed" : "Not installed",
                      systemImage: installed ? "checkmark.seal.fill" : "circle")
                    .foregroundStyle(installed ? Color.green : .secondary)
                    .labelStyle(.titleAndIcon)
            }
            Text("Other Claude Code sessions are blocked from running `npm run dev` / `nuxt dev` / "
                 + "builds directly and told to use `dev-monitor`, so every server is supervised here. "
                 + "Adds a PreToolUse hook to ~/.claude/settings.json.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if installed {
                    Button(role: .destructive) { run(ClaudeHookInstaller.uninstall) } label: {
                        Label("Uninstall hook", systemImage: "trash")
                    }
                } else {
                    Button { run(ClaudeHookInstaller.install) } label: {
                        Label("Install hook", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { installed = ClaudeHookInstaller.isInstalled }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
        installed = ClaudeHookInstaller.isInstalled
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
        return row(icon: "memorychip", name: "Memory", auto: auto) {
            Text("\(live.memoryGB) GB").foregroundStyle(.secondary)
        } manual: {
            Picker("", selection: Binding(get: { live.memoryGB },
                                          set: { app.setMemoryGB($0, for: project.id) })) {
                ForEach(1...max(systemMaxGB, live.memoryGB), id: \.self) { Text("\($0) GB").tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private var portRow: some View {
        let auto = Binding(get: { live.port == nil },
                           set: { isAuto in app.setPort(isAuto ? nil : (live.port ?? 3000), for: project.id) })
        return row(icon: "network", name: "Port", auto: auto) {
            Text("auto").foregroundStyle(.secondary)
        } manual: {
            TextField("3000", value: Binding(get: { live.port }, set: { app.setPort($0, for: project.id) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 74)
        }
    }

    private var packageRow: some View {
        let auto = Binding(get: { live.packageManagerAuto }, set: { app.setPackageManagerAuto($0, for: project.id) })
        return row(icon: "shippingbox", name: "Package", auto: auto) {
            Text(live.packageManager.rawValue).foregroundStyle(.secondary)
        } manual: {
            Picker("", selection: Binding(get: { live.packageManager },
                                          set: { app.setPackageManager($0, for: project.id) })) {
                ForEach(PackageManager.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    /// A settings row: label (left), the auto value or the manual control (right), and the Auto
    /// switch. The switch alone carries the "auto" meaning — the word isn't repeated.
    @ViewBuilder private func row<AutoValue: View, Manual: View>(
        icon: String, name: String, auto: Binding<Bool>,
        @ViewBuilder autoValue: () -> AutoValue, @ViewBuilder manual: () -> Manual
    ) -> some View {
        HStack(spacing: 12) {
            Label(name, systemImage: icon)
            Spacer(minLength: 8)
            if auto.wrappedValue { autoValue() } else { manual() }
            Toggle("", isOn: auto).labelsHidden().toggleStyle(.switch)
        }
    }
}

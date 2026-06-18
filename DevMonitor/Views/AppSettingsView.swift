import SwiftUI

/// App-wide settings modal (opened from the gear at the bottom of the sidebar): which browser to
/// open servers in, which Claude model runs the analyses, and behavior toggles.
struct AppSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("App Settings", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            Form {
                Section("Browser") {
                    Picker("Open servers in", selection: browser) {
                        Text("System default").tag(String?.none)
                        ForEach(app.installedBrowsers, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }

                Section("AI analysis") {
                    Picker("Model", selection: model) {
                        ForEach(AppSettings.models) { m in Text(m.label).tag(m.id) }
                    }
                    Text("Used for Diagnose, the Resource Advisor, and the pressure auto-analysis.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Behavior") {
                    Toggle("Auto-close orphaned dev processes under pressure", isOn: autoClose)
                    Stepper("Default heap for new projects: \(app.settings.defaultMemoryGB) GB",
                            value: defaultMem, in: 1...32)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 480, minHeight: 440)
    }

    // Bindings that persist on change.
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

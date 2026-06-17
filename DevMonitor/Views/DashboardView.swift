import SwiftUI
import AppKit

/// Per-project dashboard: status, launch controls and live log (P1).
/// Charts (P2), health controls (P3) and build runner (P5) extend this.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project
    @State private var showBuildLog = false
    @State private var percentOfMachine = false

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            logArea
        }
        .sheet(isPresented: $showBuildLog) {
            if let build = app.build(for: project) {
                BuildLogSheet(build: build)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProjectIconView(project: project, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(project.name).font(.title2.bold())
                    if let branch = GitInfo.branch(for: project.path) {
                        HStack(spacing: 4) {
                            Image("github")
                                .resizable()
                                .renderingMode(.template)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                            Text(branch)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    }
                }
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            statusPill
        }
        .padding()
    }

    private var statusPill: some View {
        let state = session?.state ?? .idle
        return Label(state.label, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private var controlBar: some View {
        let running = session?.state.isActive ?? false
        return HStack(spacing: 12) {
            Button {
                if running { app.stopActive() } else { app.launch(project) }
            } label: {
                Label(running ? "Stop" : "Launch",
                      systemImage: running ? "stop.fill" : "play.fill")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(running ? "." : "r", modifiers: .command)

            if running {
                Button { session?.recycle() } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            if let port = session?.effectivePort {
                Button { openInBrowser(port: port) } label: {
                    Label {
                        Text("Open")
                    } icon: {
                        Image("chrome")
                            .resizable()
                            .renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    }
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .help("Open http://localhost:\(port) in Chrome")
            }

            Button { openInVSCode() } label: {
                Label {
                    Text("Code")
                } icon: {
                    Image("vscode")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .help("Open the project in VS Code")

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Image(systemName: "memorychip").foregroundStyle(.secondary)
                Stepper("\(project.memoryGB) GB",
                        value: Binding(get: { project.memoryGB },
                                       set: { app.setMemoryGB($0, for: project.id) }),
                        in: 1...32)
                    .fixedSize()
                    .disabled(running)
            }

            HStack(spacing: 5) {
                Image(systemName: "network").foregroundStyle(.secondary)
                TextField("auto", value: Binding(
                    get: { project.port },
                    set: { app.setPort($0, for: project.id) }
                ), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .disabled(running)
                    .help("Port to run on (blank = framework default)")
            }

            Label(project.packageManager.rawValue, systemImage: "shippingbox")
                .foregroundStyle(.secondary)

            Spacer()
            buildControls
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)/") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Google Chrome", url.absoluteString]
        do { try task.run() } catch { NSWorkspace.shared.open(url) }
    }

    private func openInVSCode() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Visual Studio Code", project.path]
        do { try task.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
    }

    @ViewBuilder private var buildControls: some View {
        if project.buildCommand != nil {
            if let build = app.build(for: project), build.isRunning || build.result != nil {
                Button { showBuildLog = true } label: {
                    if build.isRunning {
                        Label("Building…", systemImage: "hammer.fill").foregroundStyle(.orange)
                    } else if let r = build.result {
                        Label(r == 0 ? "Built" : "Build failed", systemImage: "hammer.fill")
                            .foregroundStyle(r == 0 ? .green : .red)
                    }
                }
                .buttonStyle(.plain)
            }
            Button { app.runBuild(project) } label: {
                Label("Build", systemImage: "hammer.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(app.build(for: project)?.isRunning ?? false)
        }
    }

    @ViewBuilder private var logArea: some View {
        HStack {
            Label("Activity", systemImage: "cpu")
                .font(.headline)
            Spacer()
            Toggle("% of machine", isOn: $percentOfMachine)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)

        ProcessTableView(sampler: app.systemSampler, percentOfMachine: $percentOfMachine)
            .frame(minHeight: 180)

        Divider()

        if let session {
            LogPaneView(session: session)
                .frame(minHeight: 160)
                .padding(.horizontal)
                .padding(.bottom, 12)
        } else {
            ContentUnavailableView(
                "Not Running",
                systemImage: "play.circle",
                description: Text("Press Launch (⌘R) to start the dev server and stream its logs.")
            )
            .frame(maxHeight: .infinity)
        }
    }
}

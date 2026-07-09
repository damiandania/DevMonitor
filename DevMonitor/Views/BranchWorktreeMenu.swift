import SwiftUI
import AppKit

/// The git pill in the project header, upgraded to a menu: it shows the current branch and lets you
/// jump between the repo's worktrees — each worktree is its own monitored project, keyed by path —
/// or spin up a new one. Branch display and worktree listing both understand linked worktrees
/// (`.git` as a file). The pill stays a plain label when the folder isn't a git repo.
struct BranchWorktreeMenu: View {
    @Environment(AppState.self) private var app
    let project: Project

    @State private var worktrees: [GitInfo.Worktree] = []
    @State private var branches: [String] = []
    @State private var showNewSheet = false
    @State private var actionError: String?
    @State private var refreshToken = 0   // bumped to force a re-read of the on-disk branch
    @State private var lastListReload = Date.distantPast   // throttles the on-open list refresh

    /// Poll the branch a few times a minute so a `git switch`/`checkout` done OUTSIDE the app (e.g. in
    /// a terminal) is picked up. The read is a cheap `.git/HEAD` file read; the worktree/branch LISTS
    /// reload on project change, an in-app action, and each time the menu is opened (see
    /// `refreshListsOnOpen`) so a branch deleted outside the app drops off next time you look.
    private let poll = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = refreshToken
        if let branch = GitInfo.branch(for: project.path) {
            Menu {
                let _ = refreshListsOnOpen()   // the content closure runs when the menu opens
                branchSection(current: branch)
                worktreeSection()
                Divider()
                Button("New worktree…") { showNewSheet = true }
            } label: {
                pill(branch)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Branch: \(branch) — switch branch / worktree, or create one")
            .task(id: project.path) { await reload() }
            .onReceive(poll) { _ in refreshToken &+= 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshToken &+= 1              // instant catch-up when tabbing back from the terminal
                Task { await reload() }
            }
            .sheet(isPresented: $showNewSheet) {
                NewWorktreeSheet(repoPath: project.path, fromBranch: branch) { createdPath in
                    if let createdPath { app.addProject(path: createdPath) }
                    Task { await reload() }
                }
            }
            .alert("Git", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    /// Local branches as `git switch` targets. The current branch and any branch checked out in
    /// another worktree are disabled — git refuses to check out a branch that's live elsewhere.
    @ViewBuilder private func branchSection(current: String) -> some View {
        if !branches.isEmpty {
            let elsewhere = Set(worktrees.filter { !$0.isCurrent }.compactMap(\.branch))
            Section("Branch") {
                ForEach(visibleBranches(current: current), id: \.self) { b in
                    let inUse = elsewhere.contains(b)
                    Button { switchBranch(to: b) } label: {
                        Text("\(b == current ? "✓ " : "")\(b)\(inUse ? "  — in another worktree" : "")")
                    }
                    .disabled(b == current || inUse)
                }
            }
        }
    }

    /// The 10 most-recently-committed branches (already sorted recent-first), so a repo with a long
    /// tail of stale branches doesn't flood the menu. The current branch is always kept on top.
    private func visibleBranches(current: String, limit: Int = 10) -> [String] {
        var shown = Array(branches.prefix(limit))
        if branches.contains(current), !shown.contains(current) { shown.insert(current, at: 0) }
        return shown
    }

    @ViewBuilder private func worktreeSection() -> some View {
        if !worktrees.isEmpty {
            Section("Worktrees") {
                ForEach(worktrees) { wt in
                    Button { jump(to: wt) } label: { Text(rowTitle(wt)) }
                        .disabled(wt.isCurrent)
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    /// `git switch` in place. On failure (dirty tree, branch live elsewhere) surface git's message;
    /// on success bump the refresh token so the pill and lists re-read.
    private func switchBranch(to branch: String) {
        let repo = project.path
        Task {
            let err = await Task.detached { GitInfo.switchBranch(repoPath: repo, to: branch) }.value
            if let err { actionError = err } else { refreshToken += 1; await reload() }
        }
    }

    private func rowTitle(_ wt: GitInfo.Worktree) -> String {
        let check = wt.isCurrent ? "✓ " : ""
        let branch = wt.branch.map { " — \($0)" } ?? ""
        return "\(check)\(wt.name)\(branch)"
    }

    /// Worktrees are distinct projects keyed by path: select it (adding it first if it's a launchable
    /// folder we don't track yet). A worktree without a package.json simply can't be monitored, so
    /// `addProject` no-ops there.
    private func jump(to wt: GitInfo.Worktree) {
        app.addProject(path: wt.path)
    }

    private func reload() async {
        let path = project.path
        async let wt = Task.detached { GitInfo.worktrees(for: path) }.value
        async let br = Task.detached { GitInfo.localBranches(for: path) }.value
        worktrees = await wt
        branches = await br
    }

    /// Refresh the worktree/branch lists when the menu opens so branches deleted outside the app stop
    /// showing. Deferred to the next runloop tick (never mutate state during a view update) and
    /// throttled: reassigning the lists rebuilds the menu content, which would re-enter here in a loop
    /// while the menu is open — the 1s guard breaks that, while real re-opens are always further apart.
    private func refreshListsOnOpen() {
        Task { @MainActor in
            guard Date().timeIntervalSince(lastListReload) > 1 else { return }
            lastListReload = Date()
            await reload()
        }
    }

    @ViewBuilder private func pill(_ branch: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
            Text(branch).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Sheet for `git worktree add`: a branch (existing, or new from the current HEAD) and a target
/// folder that defaults to a sibling `<repo>-<branch>`. On success the caller adds the new worktree
/// as a project; on failure git's message is shown inline.
struct NewWorktreeSheet: View {
    let repoPath: String
    let fromBranch: String
    /// Called with the created worktree path on success, or `nil` on cancel.
    var onDone: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var branch = ""
    @State private var createBranch = true
    @State private var path = ""
    @State private var busy = false
    @State private var error: String?

    private var repoName: String { URL(fileURLWithPath: repoPath).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New worktree").font(.headline)
            Text("Creates a linked worktree of **\(repoName)** and adds it as a project.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Branch (e.g. feature/login)", text: $branch)
                    .onChange(of: branch) { _, v in path = defaultPath(for: v) }
                Toggle("Create new branch from \(fromBranch)", isOn: $createBranch)
                TextField("Worktree folder", text: $path)
                    .font(.system(.body, design: .monospaced))
            }
            .textFieldStyle(.roundedBorder)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone(nil); dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || branch.trimmed.isEmpty || path.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func defaultPath(for branch: String) -> String {
        let slug = branch.replacingOccurrences(of: "/", with: "-").trimmed
        guard !slug.isEmpty else { return "" }
        let parent = URL(fileURLWithPath: repoPath).deletingLastPathComponent().path
        return "\(parent)/\(repoName)-\(slug)"
    }

    private func create() {
        let b = branch.trimmed, p = path.trimmed, create = createBranch
        busy = true; error = nil
        Task {
            let err = await Task.detached {
                GitInfo.addWorktree(repoPath: repoPath, at: p, branch: b, createBranch: create)
            }.value
            busy = false
            if let err { error = err } else { onDone(p); dismiss() }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

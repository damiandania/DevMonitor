import SwiftUI
import AppKit

extension Color {
    /// Claude's primary "clay" coral — the brand accent used for the quota numbers.
    static let claudeCoral = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

extension NSScreen {
    /// The screen that carries the notch — the bar is pinned here (not to the focus-following `.main`),
    /// so it stays put beside the notch instead of following focus to an external display. Detected via
    /// `safeAreaInsets.top` (the physical notch's inset), which is STABLE — unlike `auxiliaryTopLeftArea`,
    /// which briefly goes nil during Space/display transitions and would otherwise make the bar jump.
    static var notched: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? .main ?? screens.first
    }

    /// True for the built-in notch display even mid-transition (when the auxiliary areas read nil).
    var hasNotch: Bool { safeAreaInsets.top > 0 }
}

enum QuotaSource { case claude, gpt }

/// The always-visible readout on the RIGHT side of the notch bar. Clicking it alternates between
/// Claude's 5-hour / 7-day usage and the signed-in GPT (Codex) quota. The black background itself is
/// drawn by `QuotaHUDController`'s container (one continuous shape from the mascot, across the notch,
/// to here), not by this view.
struct QuotaHUDView: View {
    var claudeQuota: ClaudeQuotaMonitor
    var gptQuota: CodexQuotaMonitor
    var source: QuotaSource
    var appState: AppState
    var barHeight: CGFloat
    var onZoneHover: (Bool) -> Void
    var onContentChange: () -> Void
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch source {
            case .claude:
                if claudeQuota.status == .ok {
                    let numberColor: Color = claudeQuota.isStale ? .white.opacity(0.5) : .claudeCoral
                    if let five = claudeQuota.fiveHour { claudeMetric("clock", five, numberColor) }
                    if let seven = claudeQuota.sevenDay { claudeMetric("calendar", seven, numberColor) }
                } else {
                    statusBadge(claudeQuota.status, cli: "Claude",
                                reauth: "run `claude` in a terminal and sign in")
                }
            case .gpt:
                Image("CodexLogo").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 13, height: 13).foregroundStyle(.white)
                if gptQuota.status == .ok {
                    if let primary = gptQuota.primary { gptMetric(primary) }
                    if let secondary = gptQuota.secondary { gptMetric(secondary) }
                    if !gptQuota.hasData { Text("—").foregroundStyle(.white.opacity(0.6)) }
                } else {
                    statusBadge(gptQuota.status, cli: "Codex", reauth: "run `codex login` in a terminal")
                }
            }
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .imageScale(.medium)
        .padding(.horizontal, 10)
        .frame(height: barHeight)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .onHover { onZoneHover($0) }
        .onTapGesture { onToggle() }
        .onChange(of: claudeQuota.fiveHour == nil) { _, _ in onContentChange() }
        .onChange(of: claudeQuota.sevenDay == nil) { _, _ in onContentChange() }
        .onChange(of: claudeQuota.status) { _, _ in onContentChange() }
        .onChange(of: gptQuota.hasData) { _, _ in onContentChange() }
        .onChange(of: gptQuota.status) { _, _ in onContentChange() }
    }

    /// Shown INSTEAD OF the percentages when a probe can't get a real reading — a frozen old value
    /// would otherwise look like a fresh, reassuring "usage is low" signal. Each failure mode gets
    /// its own glyph + tooltip so the badge tells the user what to DO: `?` = the CLI isn't installed;
    /// a person-with-warning = the login/session expired (re-auth); a triangle = ran but returned
    /// nothing (transient — retrying). `cli` names the tool; `reauth` is the sign-in hint.
    @ViewBuilder private func statusBadge(_ status: QuotaStatus, cli: String, reauth: String) -> some View {
        switch status {
        case .ok:
            EmptyView()
        case .notInstalled:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.white.opacity(0.6))
                .help("\(cli) CLI not found on PATH — install it (or check your PATH) to show usage")
        case .signedOut:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.yellow)
                .help("\(cli) usage unavailable — the session expired. \(reauth.prefix(1).uppercased() + reauth.dropFirst()) to restore it.")
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help("Couldn't read \(cli) usage — no data returned (e.g. several Claude Code sessions competing). Retrying.")
        }
    }

    private func claudeMetric(_ symbol: String, _ pct: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(pct)%")
        }
        .foregroundStyle(color)
        .help(claudeQuota.isStale
              ? "Claude quota — no recent update; run a Claude session to refresh"
              : "Claude usage · clock = 5-hour window · calendar = 7-day window")
    }

    private func gptMetric(_ window: CodexQuotaMonitor.Window) -> some View {
        HStack(spacing: 3) {
            Image(systemName: (window.durationMinutes ?? 0) <= 360 ? "clock" : "calendar")
            Text("\(window.usedPercent)%")
        }
        .foregroundStyle(gptQuota.isStale ? .white.opacity(0.5) : .white)
        .help(gptQuota.isStale
              ? "GPT quota — no recent update; make sure Codex is installed and signed in"
              : "GPT usage · \(windowDescription(window))")
    }

    private func windowDescription(_ window: CodexQuotaMonitor.Window) -> String {
        guard let minutes = window.durationMinutes else { return "usage limit" }
        if minutes < 60 { return "\(minutes)-minute window" }
        if minutes < 24 * 60 { return "\(minutes / 60)-hour window" }
        return "\(minutes / (24 * 60))-day window"
    }
}

/// A tiny AppKit view that reports hover (the mascot half of the bar is AppKit, so SwiftUI's
/// `.onHover` can't cover it) — hovering the mascot opens the same controls menu as the readout.
private final class HoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    // Click the cat to pet it (fires the heart burst). A non-activating panel still delivers the
    // click without stealing focus from whatever you're working in.
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Owns the notch bar: ONE borderless panel spanning mascot strip + notch + quota readout, drawn as a
/// single continuous black shape (the physical notch sits over its middle, black on black — so the
/// whole thing reads as one wide notch, never two floating pieces). Also owns the controls popover
/// opened on hover, and drives the mascot's mood from app state.
@MainActor
final class QuotaHUDController {
    private let panel: NSPanel
    /// The one black strip: rounded at BOTH outer-bottom corners, square across the notch.
    private let container: NSView
    private let barMask = CAShapeLayer()
    private let mascotHost: HoverTrackingView
    private let mascot = ClaudeMascot()
    private let hosting: NSHostingView<QuotaHUDView>
    private let popover: NSPopover
    private let barHeight: CGFloat
    private let appState: AppState
    private let claudeQuota: ClaudeQuotaMonitor
    private let gptQuota: CodexQuotaMonitor
    private var quotaSource: QuotaSource = .claude

    private var hudHovered = false
    private var menuHovered = false
    private var closeWork: DispatchWorkItem?
    private var moodTimer: Timer?

    /// Both ends of the bar use the SAME fixed width: the mascot's stage on the left mirrors the
    /// readout on the right, so the bar is symmetric around the notch and never resizes as the quota
    /// numbers appear/disappear (the readout content just centres in its half). Slimmer now that the
    /// readout is just the two quota numbers in a smaller font (the status icon is gone).
    private static let sideWidth: CGFloat = 130

    /// Edge-detection state for the event animations: the previous tick's snapshot of what was
    /// running/launching, so transitions (started, finished, failed) can fire transient animations.
    private var runningBuildIDs: Set<Project.ID> = []
    private var runningWorkerIDs: Set<Project.ID> = []
    private var launchingServerIDs: Set<Project.ID> = []
    private var runningServerIDs: Set<Project.ID> = []
    private var wasKeepingAwake = false
    private var wasRed = false
    /// The transient event animation currently showing, and until when.
    private var transientMood: ClaudeMascot.Mood?
    private var transientUntil = Date.distantPast

    init(claudeQuota: ClaudeQuotaMonitor, gptQuota: CodexQuotaMonitor, appState: AppState) {
        self.appState = appState
        self.claudeQuota = claudeQuota
        self.gptQuota = gptQuota
        barHeight = NSScreen.notched?.auxiliaryTopRightArea?.height ?? Self.menuBarHeight()

        popover = NSPopover()
        popover.behavior = .transient

        hosting = NSHostingView(rootView: QuotaHUDView(claudeQuota: claudeQuota, gptQuota: gptQuota,
                                                       source: .claude, appState: appState,
                                                       barHeight: barHeight,
                                                       onZoneHover: { _ in }, onContentChange: {}, onToggle: {}))

        container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true   // clip the mascot inside the bar
        container.layer?.mask = barMask         // custom notch silhouette (concave top, convex bottom)

        mascotHost = HoverTrackingView()
        mascotHost.wantsLayer = true
        mascotHost.layer?.addSublayer(mascot.root)
        container.addSubview(mascotHost)
        container.addSubview(hosting)

        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Above the fullscreen shield so it stays visible over fullscreen apps (`.statusBar` sits
        // BELOW fullscreen content); `.fullScreenAuxiliary` + `.canJoinAllSpaces` put it on every
        // Space, so it's a standalone overlay, not tied to the (hidden-in-fullscreen) menu bar.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = container
        reposition()
        panel.orderFrontRegardless()

        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environment(appState).environment(\.locale, appState.uiLocale)
                .onHover { [weak self] in self?.menuHover($0) })

        updateQuotaView()
        mascotHost.onHover = { [weak self] in self?.zoneHover($0) }
        mascotHost.onClick = { [weak self] in self?.love() }

        updateMood()
        // State (builds, health, keep-awake, quota) isn't one cheap stream to subscribe to, so poll —
        // a ~1s lag on a state that lasts seconds/minutes is imperceptible, and switching the mascot's
        // mood only reinstalls a handful of animations.
        moodTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMood() }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func updateQuotaView() {
        hosting.rootView = QuotaHUDView(claudeQuota: claudeQuota, gptQuota: gptQuota,
                                        source: quotaSource, appState: appState, barHeight: barHeight,
                                        onZoneHover: { [weak self] in self?.zoneHover($0) },
                                        onContentChange: { [weak self] in
                                            DispatchQueue.main.async { self?.reposition() }
                                        }, onToggle: { [weak self] in self?.toggleQuotaSource() })
    }

    private func toggleQuotaSource() {
        quotaSource = quotaSource == .claude ? .gpt : .claude
        if quotaSource == .gpt { gptQuota.activate() }
        updateQuotaView()
    }

    // MARK: - Mascot mood

    /// Event-driven mascot: most of the time the cat just lives its life (idle vignettes). App
    /// activity fires short TRANSIENT animations (3 s each):
    ///   failed      — something failed (health went red / a build exited non-zero): red X eyes
    ///   completed   — a launching server reached running: the rocket lifts off + check eyes
    ///   exploded    — a server died mid-launch: the rocket explodes + red X eyes
    ///   celebrating — a build finished OK: check eyes, hops + confetti
    ///   gearedUp    — a background worker just started: hard hat drops on + determined nod
    ///   caffeinated — keep-awake switched on: a steaming coffee, a couple of sips
    /// Four CONTINUOUS states: while a server is LAUNCHING the rocket vibrates on the pad; while a
    /// build runs the cat hammers away; while a production PREVIEW serves it watches its little
    /// screen; and when the machine is under pressure the warning-eyes animation outranks
    /// EVERYTHING (explicit policy).
    private func updateMood() {
        let now = Date()

        // Builds: one leaving the running set finished — code 0 celebrates, anything else goes red.
        let buildsRunning = Set(appState.builds.filter { $0.value.isRunning }.map(\.key))
        for id in runningBuildIDs.subtracting(buildsRunning) {
            fire(appState.builds[id]?.result == 0 ? .celebrating : .failed, at: now)
        }
        runningBuildIDs = buildsRunning

        // Workers: a NEW one starting gets the 3-second hard-hat salute; while it runs, nothing.
        let workersNow = Set(appState.workers.filter { $0.value.isRunning }.map(\.key))
        if !workersNow.subtracting(runningWorkerIDs).isEmpty { fire(.gearedUp, at: now) }
        runningWorkerIDs = workersNow

        // Keep-awake toggled ON → a 3-second coffee break.
        let keepingAwake = appState.sleepGuard.isActive
        if keepingAwake && !wasKeepingAwake { fire(.caffeinated, at: now) }
        wasKeepingAwake = keepingAwake

        // Servers (dev sessions + previews). Launching is CONTINUOUS (the rocket loop plays for as
        // long as a server is coming up — that can be well past 3 s); reaching running fires the
        // 3-second green-check event.
        var launchingNow = Set<Project.ID>(), runningNow = Set<Project.ID>()
        for sessions in [appState.sessions, appState.previews] {
            for (id, s) in sessions {
                switch s.state {
                case .launching, .recycling: launchingNow.insert(id)
                case .running:               runningNow.insert(id)
                default:                     break
                }
            }
        }
        // Anything going red (a session failing, a worker crashing…). Generic — the specific
        // launch outcomes below may override it on the same tick with a better story.
        let red = appState.serversHealth == .red
        if red && !wasRed { fire(.failed, at: now) }
        wasRed = red

        // Where did each launching server END UP? Reaching running lifts the rocket off
        // (`completed`); dying mid-launch blows it up (`exploded`). Checked last so the launch
        // outcome wins the event slot over the generic red flash.
        for id in launchingServerIDs.subtracting(launchingNow) {
            if runningNow.contains(id) {
                fire(.completed, at: now)
            } else {
                switch appState.sessions[id]?.state ?? appState.previews[id]?.state {
                case .failed?, .stopped?, nil: fire(.exploded, at: now)
                default: break                 // still alive in some other state — no story
                }
            }
        }
        launchingServerIDs = launchingNow
        runningServerIDs = runningNow

        let mood: ClaudeMascot.Mood
        if appState.systemUnderPressure {
            mood = .pressured                                    // outranks everything
        } else if let transient = transientMood, now < transientUntil {
            mood = transient
        } else if !launchingNow.isEmpty {
            mood = .launching                                    // continuous while a server boots
        } else if !buildsRunning.isEmpty {
            mood = .working
        } else if appState.previews.values.contains(where: {
            if case .running = $0.state { return true } else { return false }
        }) {
            mood = .previewing                                   // production preview serving
        } else {
            mood = .idle
        }
        mascot.set(mood)
    }

    /// Show a transient event animation for 3 seconds (replacing whatever event was showing).
    private func fire(_ mood: ClaudeMascot.Mood, at now: Date) {
        transientMood = mood
        transientUntil = now.addingTimeInterval(3)
    }

    /// You clicked the cat: reward it with a 3-second heart burst. `poke` forces the animation to
    /// (re)start even on a rapid repeat click, and the transient window keeps it up until the next
    /// real event (or pressure) reclaims the slot on the poll tick.
    private func love() {
        let now = Date()
        transientMood = .loved
        transientUntil = now.addingTimeInterval(3)
        mascot.poke(.loved)
    }

    // MARK: - Hover / popover

    private func zoneHover(_ hovering: Bool) {
        hudHovered = hovering
        if hovering { openMenu() } else { scheduleClose() }
    }

    private func menuHover(_ hovering: Bool) {
        menuHovered = hovering
        if hovering { closeWork?.cancel() } else { scheduleClose() }
    }

    private func openMenu() {
        closeWork?.cancel()
        guard !popover.isShown else { return }
        popover.show(relativeTo: hosting.bounds, of: hosting, preferredEdge: .minY)
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hudHovered, !self.menuHovered, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Geometry

    /// One frame for the whole bar: a fixed-width mascot stage hugging the notch's left side, the
    /// notch, and an equally wide readout on the right. The physical notch covers the middle of the
    /// black container, so on screen — and in screenshots — it's one continuous, symmetric shape.
    /// Falls back to a compact mascot+readout bar in the top-right corner on a display without a notch.
    @objc private func reposition() {
        guard let screen = NSScreen.notched else { return }
        let side = Self.sideWidth
        let frame: NSRect
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let h = left.height
            frame = NSRect(x: left.maxX - side, y: left.minY,
                           width: side + (right.minX - left.maxX) + side, height: h)
        } else if screen.hasNotch {
            // Notch display mid-transition: the auxiliary areas momentarily read nil. Keep the last
            // good frame instead of jumping to a corner — the bar must stay static behind the camera.
            return
        } else {
            let h = Self.menuBarHeight(on: screen)
            frame = NSRect(x: screen.frame.maxX - 2 * side - 8, y: screen.frame.maxY - h,
                           width: 2 * side, height: h)
        }
        panel.setFrame(frame, display: true)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = frame.height
        container.frame = NSRect(origin: .zero, size: frame.size)
        barMask.frame = CGRect(origin: .zero, size: frame.size)
        barMask.path = Self.notchPath(width: frame.width, height: h,
                                      topRadius: min(h * 0.28, 12), bottomRadius: h * 0.32)
        mascotHost.frame = NSRect(x: 0, y: 0, width: side, height: h)              // left stage
        hosting.frame = NSRect(x: frame.width - side, y: 0, width: side, height: h) // right readout
        mascot.layout(width: side, height: h, backing: screen.backingScaleFactor)
        CATransaction.commit()
    }

    /// A notch silhouette in the layer's (y-up) coordinate space: the top-outer corners flare out
    /// CONCAVELY so the bar melts into the top bezel (no hard 90° corner), while the bottom-outer
    /// corners round CONVEXLY into the menu bar. `tR` = top concave radius, `bR` = bottom convex radius.
    nonisolated private static func notchPath(width W: CGFloat, height H: CGFloat,
                                              topRadius tR: CGFloat, bottomRadius bR: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: H))                                              // top-left @ screen top
        p.addQuadCurve(to: CGPoint(x: tR, y: H - tR), control: CGPoint(x: tR, y: H)) // concave top-left
        p.addLine(to: CGPoint(x: tR, y: bR))                                         // down left side
        p.addQuadCurve(to: CGPoint(x: tR + bR, y: 0), control: CGPoint(x: tR, y: 0)) // convex bottom-left
        p.addLine(to: CGPoint(x: W - tR - bR, y: 0))                                 // bottom edge
        p.addQuadCurve(to: CGPoint(x: W - tR, y: bR), control: CGPoint(x: W - tR, y: 0)) // convex bottom-right
        p.addLine(to: CGPoint(x: W - tR, y: H - tR))                                 // up right side
        p.addQuadCurve(to: CGPoint(x: W, y: H), control: CGPoint(x: W - tR, y: H))   // concave top-right
        p.closeSubpath()                                                             // top edge back to start
        return p
    }

    private static func menuBarHeight(on screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen else { return 24 }
        return max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }
}

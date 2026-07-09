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

/// The always-visible readout on the RIGHT side of the notch bar: just the Claude 5h/7d usage (the
/// old constellation status icon is gone — the mascot's event animations carry that job now; hover
/// the bar for the controls menu). Instead of matching the menu-bar tint (unreliable in fullscreen /
/// over rotating wallpapers), it sits on the bar's black strip that visually extends the notch's
/// bezel — so a plain white glyph is always legible, everywhere. The black background itself is drawn
/// by `QuotaHUDController`'s container (one continuous shape from the mascot, across the notch, to
/// here), not by this view.
struct QuotaHUDView: View {
    var quota: ClaudeQuotaMonitor
    var appState: AppState
    var barHeight: CGFloat
    var onZoneHover: (Bool) -> Void
    var onContentChange: () -> Void

    var body: some View {
        let numberColor: Color = quota.isStale ? .white.opacity(0.5) : .claudeCoral
        HStack(spacing: 8) {
            if let five = quota.fiveHour { metric("clock", five, numberColor) }
            if let seven = quota.sevenDay { metric("calendar", seven, numberColor) }
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .imageScale(.medium)
        .padding(.horizontal, 10)
        .frame(height: barHeight)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .onHover { onZoneHover($0) }
        .onChange(of: quota.fiveHour == nil) { _, _ in onContentChange() }
        .onChange(of: quota.sevenDay == nil) { _, _ in onContentChange() }
    }

    private func metric(_ symbol: String, _ pct: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(pct)%")
        }
        .foregroundStyle(color)
        .help(quota.isStale
              ? "Claude quota — no recent update; run a Claude session to refresh"
              : "Claude usage · clock = 5-hour window · calendar = 7-day window")
    }
}

/// A tiny AppKit view that reports hover (the mascot half of the bar is AppKit, so SwiftUI's
/// `.onHover` can't cover it) — hovering the mascot opens the same controls menu as the readout.
private final class HoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
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
    private let quota: ClaudeQuotaMonitor

    private var hudHovered = false
    private var menuHovered = false
    private var closeWork: DispatchWorkItem?
    private var moodTimer: Timer?

    /// Both ends of the bar use the SAME fixed width: the mascot's stage on the left mirrors the
    /// readout on the right, so the bar is symmetric around the notch and never resizes as the quota
    /// numbers appear/disappear (the readout content just centres in its half). Slimmer now that the
    /// readout is just the two quota numbers (the status icon is gone).
    private static let sideWidth: CGFloat = 150

    /// Edge-detection state for the event animations: the previous tick's snapshot of what was
    /// running/launching, so transitions (started, finished, failed) can fire transient animations.
    private var runningBuildIDs: Set<Project.ID> = []
    private var runningWorkerIDs: Set<Project.ID> = []
    private var launchingServerIDs: Set<Project.ID> = []
    private var runningServerIDs: Set<Project.ID> = []
    private var wasRed = false
    /// The transient event animation currently showing, and until when.
    private var transientMood: ClaudeMascot.Mood?
    private var transientUntil = Date.distantPast

    init(quota: ClaudeQuotaMonitor, appState: AppState) {
        self.appState = appState
        self.quota = quota
        barHeight = NSScreen.notched?.auxiliaryTopRightArea?.height ?? Self.menuBarHeight()

        popover = NSPopover()
        popover.behavior = .transient

        hosting = NSHostingView(rootView: QuotaHUDView(quota: quota, appState: appState,
                                                       barHeight: barHeight,
                                                       onZoneHover: { _ in }, onContentChange: {}))

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

        hosting.rootView = QuotaHUDView(quota: quota, appState: appState, barHeight: barHeight,
                                        onZoneHover: { [weak self] in self?.zoneHover($0) },
                                        onContentChange: { [weak self] in
                                            DispatchQueue.main.async { self?.reposition() }
                                        })
        mascotHost.onHover = { [weak self] in self?.zoneHover($0) }

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

    // MARK: - Mascot mood

    /// Event-driven mascot: most of the time the cat just lives its life (idle vignettes). App
    /// activity fires short TRANSIENT animations (3 s each):
    ///   failed      — something failed (health went red / a build exited non-zero): red X eyes
    ///   completed   — a launching server reached running: the rocket lifts off + check eyes
    ///   exploded    — a server died mid-launch: the rocket explodes + red X eyes
    ///   celebrating — a build finished OK: check eyes, hops + confetti
    ///   gearedUp    — a background worker just started: hard hat drops on + determined nod
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

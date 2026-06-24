import SwiftUI
import AppKit

@main
struct DevMonitorApp: App {
    @State private var appState = AppState()
    // Notifications are wired in AppState.init (Notifier.attach): delegate, categories, authorization.

    var body: some Scene {
        // Single main window (not a WindowGroup): "Open Window" focuses the existing one
        // instead of spawning duplicates.
        Window("Dev Monitor", id: "main") {
            RootSplitView()
                .environment(appState)
                .environment(\.locale, appState.uiLocale)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .environment(\.locale, appState.uiLocale)
        } label: {
            MenuBarStatusIcon()
                .environment(appState)
                .environment(\.locale, appState.uiLocale)
        }
        .menuBarExtraStyle(.window)

        // Settings and Doctor are real windows (native title bar + traffic-light close button).
        Window("Settings", id: "settings") {
            AppSettingsView().environment(appState).environment(\.locale, appState.uiLocale)
        }
        .windowResizability(.contentSize)

        Window("Doctor", id: "doctor") {
            DoctorSheet().environment(appState).environment(\.locale, appState.uiLocale)
        }
        .windowResizability(.contentSize)

        Window("History", id: "history") {
            HistoryView().environment(appState).environment(\.locale, appState.uiLocale)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar icon: the logo's 7-dot constellation, drawn one dot per *live* process — each tinted
/// by that process's OWN status (running green ▸ starting orange ▸ failed/stopped red). So two
/// servers, one green and one red, show as two differently-coloured dots instead of a single
/// aggregate dot that's red whenever anything is red. The first process takes the centre slot; each
/// further one fills a scattered slot (fixed order, so dots don't flicker); past 7 they're not shown.
/// Unused slots stay white, so the full constellation is always visible.
struct MenuBarStatusIcon: View {
    @Environment(AppState.self) private var app

    private static let iconSize: CGFloat = 18                 // menu-bar glyph size (points)
    private static let dotRadiusRatio: CGFloat = 0.115        // dot radius ÷ icon size

    /// Dot-slot centres (normalized, SVG top-down y — from `logo.svg`), in a fixed *scattered* order:
    /// centre, then corners and edges. Index = the Nth live process.
    private static let slots: [(x: CGFloat, y: CGFloat)] = [
        (0.500, 0.500),  // centre — the first process
        (0.830, 0.326),  // top-right
        (0.170, 0.686),  // bottom-left
        (0.169, 0.326),  // top-left
        (0.831, 0.684),  // bottom-right
        (0.500, 0.171),  // top
        (0.500, 0.830),  // bottom
    ]

    /// One colour per live run-control (dev/worker/build/preview, any project), by its own status.
    /// Stable order, capped at the slot count.
    private var dotColors: [NSColor] {
        app.projects.flatMap { app.runControls(for: $0) }
            .filter(\.isLive)
            // By launch time → the first/oldest process holds the centre slot and each newer one fills
            // the next scattered slot (tabID breaks ties so the order stays stable between renders).
            .sorted { ($0.startedAt ?? .distantPast, $0.tabID) < ($1.startedAt ?? .distantPast, $1.tabID) }
            .prefix(Self.slots.count)
            .map { NSColor($0.status.color) }
    }

    var body: some View {
        // A drawing-handler NSImage is THE way to do a menu-bar icon: it sizes correctly and AppKit
        // re-runs the handler on redraw, so `labelColor` tracks the menu bar's light/dark appearance.
        // A new NSImage is built whenever the dot colours change (a process starts/stops/changes state).
        let colors = dotColors
        return Image(nsImage: Self.icon(dots: colors))
            .renderingMode(.original)
            .accessibilityLabel("Dev Monitor")
            .accessibilityValue(colors.isEmpty ? "idle"
                : "\(colors.count) active process\(colors.count == 1 ? "" : "es")")
    }

    /// Draw the full 7-dot constellation: the first N slots take live processes' status colours, the
    /// rest stay **white** (the resting/unused slots), so the logo is always visible and you can read
    /// both how many processes run and how each is doing.
    private static func icon(dots: [NSColor]) -> NSImage {
        let size = iconSize
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let r = size * dotRadiusRatio
            for (i, slot) in slots.enumerated() {
                // Used slot → that process's status colour; unused slot → white.
                let color = i < dots.count ? dots[i] : NSColor.white
                color.setFill()
                let cx = slot.x * size
                let cy = (1 - slot.y) * size   // SVG is top-down; AppKit drawing is bottom-up
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
    }
}

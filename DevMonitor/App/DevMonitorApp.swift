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

/// The menu-bar icon: the app glyph (template, adapts to the menu bar) with its centre circle tinted
/// by aggregate server health — red (any failed) ▸ orange (any launching/recycling) ▸ green (all up)
/// ▸ black (nothing running). Geometry mirrors the source SVG (240×240, circle r≈41 at centre).
struct MenuBarStatusIcon: View {
    @Environment(AppState.self) private var app

    private static let iconSize: CGFloat = 18                 // menu-bar glyph size (points)
    private static let dotRatio = 2 * 41.197 / 240.0         // circle ÷ viewBox (≈0.343)

    /// Centre-dot colour by aggregate health. Idle uses the icon's own colour (`labelColor`) so the
    /// dot blends into the body — the icon just looks solid when nothing is running.
    private var dotColor: NSColor {
        switch app.serversHealth {
        case .red:    return .systemRed
        case .orange: return .systemOrange
        case .green:  return .systemGreen
        case .idle:   return .labelColor
        }
    }

    var body: some View {
        // A drawing-handler NSImage is THE way to do a menu-bar icon: it sizes correctly (a SwiftUI
        // vector label renders huge) and AppKit re-runs the handler whenever the status item redraws,
        // so `labelColor` tracks the menu bar's light/dark appearance with no observer — and no
        // SwiftUI snapshot loop (that pegged the main thread and hung the app). A new NSImage is built
        // whenever `serversHealth` changes (the captured dot colour differs).
        Image(nsImage: Self.icon(dot: dotColor))
            .renderingMode(.original)
            .accessibilityLabel("Dev Monitor")
            .accessibilityValue(healthLabel)
    }

    /// Spoken aggregate health for the menu-bar item, so VoiceOver conveys what the dot colour shows.
    private var healthLabel: String {
        switch app.serversHealth {
        case .red:    return "attention needed"
        case .orange: return "starting"
        case .green:  return "running"
        case .idle:   return "idle"
        }
    }

    private static func icon(dot: NSColor) -> NSImage {
        let size = iconSize
        let body = NSImage(named: "navbar-body")
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // 1) the glyph body, tinted to the menu-bar label colour (adapts light/dark).
            if let body {
                body.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.labelColor.set()
                NSGraphicsContext.current?.compositingOperation = .sourceAtop
                NSBezierPath(rect: rect).fill()
            }
            // 2) the centre dot.
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            dot.setFill()
            let d = size * dotRatio
            NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2,
                                        width: d, height: d)).fill()
            return true
        }
    }
}

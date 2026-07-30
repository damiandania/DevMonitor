import SwiftUI

/// A small filled status circle (server state, build outcome, recommendation severity). Replaces the
/// ad-hoc `Circle().fill(…).frame(…)` repeated across the sidebar, terminal tabs and Doctor list.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    /// Rasterise the dot into an opaque bitmap so the macOS selection *vibrancy* can't darken it on a
    /// selected/tinted row (a plain Circle gets blended down). Needed in the project sidebar.
    var drawingGroup = false
    /// Spoken state for VoiceOver (e.g. "Running"). When nil the dot is decorative (hidden) — its
    /// colour is usually paired with adjacent text that already conveys the state.
    var accessibilityLabel: String? = nil

    @ViewBuilder var body: some View {
        let dot = Circle().fill(color).frame(width: size, height: size)
        Group { if drawingGroup { dot.drawingGroup() } else { dot } }
            .accessibilityHidden(accessibilityLabel == nil)
            .accessibilityLabel(accessibilityLabel ?? "")
    }
}

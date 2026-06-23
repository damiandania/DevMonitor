import SwiftUI

/// A small filled status circle (server state, build outcome, recommendation severity). Replaces the
/// ad-hoc `Circle().fill(…).frame(…)` repeated across the sidebar, terminal tabs and Doctor list.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    /// Rasterise the dot into an opaque bitmap so the macOS selection *vibrancy* can't darken it on a
    /// selected/tinted row (a plain Circle gets blended down). Needed in the project sidebar.
    var drawingGroup = false

    @ViewBuilder var body: some View {
        let dot = Circle().fill(color).frame(width: size, height: size)
        if drawingGroup { dot.drawingGroup() } else { dot }
    }
}

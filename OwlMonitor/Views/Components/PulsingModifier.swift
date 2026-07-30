import SwiftUI

/// Fades a view in and out while `active` — the shared "in progress" signal (e.g. a run-control's
/// text blinks while launching/building). When `active` is false it sits at full opacity.
private struct PulsingModifier: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.4 : 1)
            .onAppear { if active { startPulsing() } }
            .onChange(of: active) { _, now in
                if now { startPulsing() } else { withAnimation(.easeOut(duration: 0.2)) { dim = false } }
            }
    }

    private func startPulsing() {
        dim = false
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
    }
}

extension View {
    /// Blink (fade) this view while `active`. Default `true` pulses forever, like an in-progress mark.
    func pulsing(active: Bool = true) -> some View { modifier(PulsingModifier(active: active)) }
}

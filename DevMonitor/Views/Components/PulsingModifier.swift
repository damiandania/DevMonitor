import SwiftUI

/// Fades a view in and out forever — the shared "in progress" signal (the toolbar "Build Running"
/// label and the red Stop icon pulse in sync). Replaces the duplicated `@State pulse` + `.opacity`
/// + `.onAppear { withAnimation(…) }` dance.
private struct PulsingModifier: ViewModifier {
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

extension View {
    func pulsing() -> some View { modifier(PulsingModifier()) }
}

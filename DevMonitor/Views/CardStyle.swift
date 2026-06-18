import SwiftUI
import AppKit

extension View {
    /// Inset rounded "card" surface used across the detail pane — the modal/System-Settings look
    /// (control-tinted fill on the window-tinted base, soft shadow).
    func dmCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

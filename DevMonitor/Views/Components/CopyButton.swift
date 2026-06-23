import SwiftUI
import AppKit

/// A small icon button that copies `text` to the clipboard and briefly flips to a green checkmark
/// (with a little scale bump) so the user gets clear feedback that it worked.
struct CopyButton: View {
    let text: String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : .secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
                .scaleEffect(copied ? 1.18 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : help)
    }
}

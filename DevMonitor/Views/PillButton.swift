import SwiftUI

/// Reusable capsule button used across the dashboard controls, so every button
/// shares the same size, shape and icon treatment.
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var assetImage: String? = nil   // template-rendered asset (e.g. "chrome", "vscode")
    var prominent = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label {
                Text(title)
            } icon: {
                icon
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var icon: some View {
        if let systemImage {
            Image(systemName: systemImage)
        } else if let assetImage {
            // The brand SVGs are full-bleed; render a touch smaller than 16 so their optical size
            // matches the SF Symbols used by the other preset buttons (which carry built-in padding).
            Image(assetImage)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        }
    }
}

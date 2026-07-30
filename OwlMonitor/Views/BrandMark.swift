import SwiftUI

/// The owl + wordmark lockup — the app's brand, shown at the top of the sidebar and of Settings.
///
/// The owl is a full-colour asset with a dark-appearance variant (`OwlLogo.imageset`), so unlike the
/// glyphs around it it must NOT get `.renderingMode(.template)` — that would flatten the purple wing
/// and the facial disc into one tint.
struct BrandMark: View {
    /// Height of the owl; the wordmark is sized off it so the lockup scales as one unit.
    var size: CGFloat = 22
    /// Show the running version under the name (Settings does, the sidebar doesn't).
    var showsVersion = false

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        HStack(spacing: size * 0.36) {
            Image("OwlLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                // The wordmark beside it already announces the name — don't say it twice.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Owl Monitor")
                    .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                if showsVersion {
                    Text("Version \(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

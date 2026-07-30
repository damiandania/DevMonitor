import SwiftUI
import AppKit

/// Shows the project's favicon if one exists in the folder, else the framework's SF Symbol.
struct ProjectIconView: View {
    let project: Project
    var size: CGFloat = 20

    var body: some View {
        if let image = Self.favicon(for: project.path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: project.framework.symbolName)
                .font(.system(size: size * 0.95))
                .frame(width: size, height: size)
        }
    }

    private static var cache: [String: NSImage?] = [:]
    private static let candidates = [
        "public/favicon.ico", "public/favicon.png", "public/favicon-32x32.png",
        "public/favicon.svg", "public/apple-touch-icon.png",
        "app/favicon.ico", "src/favicon.ico", "static/favicon.ico",
        "assets/favicon.ico", "favicon.ico", "favicon.png",
    ]

    static func favicon(for projectPath: String) -> NSImage? {
        if let cached = cache[projectPath] { return cached }
        let fm = FileManager.default
        var found: NSImage?
        for relative in candidates {
            let path = projectPath + "/" + relative
            if fm.fileExists(atPath: path), let image = NSImage(contentsOfFile: path), image.isValid {
                found = image
                break
            }
        }
        cache[projectPath] = found
        return found
    }
}

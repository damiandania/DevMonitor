// Resamples brand/app-icon.png into every size the macOS asset catalog needs and writes them into
// OwlMonitor/Resources/Assets.xcassets/AppIcon.appiconset/. Run: swift tools/make-icon.swift
//
// The icon is DESIGNED ARTWORK (brand/app-icon.png, exported from the Affinity source), not something
// drawn here — an earlier version of this script rebuilt the owl with Core Graphics, which meant the
// icon and the real design could drift apart. To change the icon, re-export brand/app-icon.png and run
// this; don't reach for code.
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("brand/app-icon.png")
let outDir = root.appendingPathComponent(
    "OwlMonitor/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

guard let data = try? Data(contentsOf: source),
      let rep = NSBitmapImageRep(data: data),
      let master = rep.cgImage
else { fatalError("could not read \(source.path)") }

// Warn rather than fail: everything up to 512 is still a clean downscale, and a soft 1024 beats no icon.
if master.width < 1024 {
    FileHandle.standardError.write(Data("""
        warning: brand/app-icon.png is \(master.width)×\(master.height); icon_1024.png will be upscaled \
        and slightly soft. Re-export the artwork at 1024×1024 for a crisp Retina icon.\n
        """.utf8))
}

let cs = CGColorSpaceCreateDeviceRGB()

func write(size: Int) {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create the \(size)px context") }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    let out = outDir.appendingPathComponent("icon_\(size).png")
    let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote \(out.lastPathComponent)")
}

for size in [16, 32, 64, 128, 256, 512, 1024] { write(size: size) }

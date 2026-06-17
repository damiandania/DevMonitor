// Renders Dev Monitor's app icon (1024×1024 PNG) with Core Graphics, then emits
// every size the macOS asset catalog needs. Run: swift tools/make-icon.swift
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// Rounded-rect plate with macOS-style margin + corner radius.
let margin: CGFloat = 92
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.2237
let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
let bg = [
    CGColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1),  // slate top
    CGColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1),  // near-black bottom
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: bg, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// EKG / heartbeat pulse — the "monitor" mark.
func wave() -> CGPath {
    let x0 = rect.minX + rect.width * 0.11
    let w = rect.width * 0.78
    let baseY = rect.midY
    let h = rect.height
    let pts: [(CGFloat, CGFloat)] = [
        (0.00, 0.00), (0.27, 0.00), (0.33, 0.05), (0.39, -0.05),
        (0.46, 0.31), (0.53, -0.35), (0.59, 0.11), (0.66, 0.00), (1.00, 0.00),
    ]
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0, y: baseY))
    for (fx, fy) in pts { p.addLine(to: CGPoint(x: x0 + w * fx, y: baseY + h * fy)) }
    return p
}
let pulse = CGColor(red: 0.20, green: 0.93, blue: 0.56, alpha: 1)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(pulse.copy(alpha: 0.22)!)   // glow
ctx.setLineWidth(78)
ctx.addPath(wave())
ctx.strokePath()
ctx.setStrokeColor(pulse)                       // core line
ctx.setLineWidth(36)
ctx.addPath(wave())
ctx.strokePath()
ctx.restoreGState()

// Subtle top inner highlight for depth.
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
ctx.setLineWidth(3)
ctx.addPath(plate)
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
let out = "/tmp/devmonitor-icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

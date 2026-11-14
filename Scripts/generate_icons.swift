import AppKit
import CoreGraphics
import Foundation

// Coordinates use a unit square with the origin at top left. Keep these outlines
// in sync with ChocliftBrandIconView; the letter never depends on installed fonts.
func drawMark(in cg: CGContext) {
    let letter = CGMutablePath()
    // Compact x-height, forward lean, tapered exit and round ear give a lowercase italic c.
    letter.move(to: CGPoint(x: 0.704, y: 0.354))
    letter.addCurve(to: CGPoint(x: 0.572, y: 0.265), control1: CGPoint(x: 0.711, y: 0.293), control2: CGPoint(x: 0.655, y: 0.258))
    letter.addCurve(to: CGPoint(x: 0.309, y: 0.491), control1: CGPoint(x: 0.435, y: 0.265), control2: CGPoint(x: 0.337, y: 0.365))
    letter.addCurve(to: CGPoint(x: 0.439, y: 0.659), control1: CGPoint(x: 0.284, y: 0.597), control2: CGPoint(x: 0.331, y: 0.659))
    letter.addCurve(to: CGPoint(x: 0.695, y: 0.537), control1: CGPoint(x: 0.541, y: 0.659), control2: CGPoint(x: 0.642, y: 0.613))
    letter.addLine(to: CGPoint(x: 0.647, y: 0.499))
    letter.addCurve(to: CGPoint(x: 0.483, y: 0.581), control1: CGPoint(x: 0.592, y: 0.556), control2: CGPoint(x: 0.535, y: 0.581))
    letter.addCurve(to: CGPoint(x: 0.437, y: 0.483), control1: CGPoint(x: 0.429, y: 0.581), control2: CGPoint(x: 0.422, y: 0.542))
    letter.addCurve(to: CGPoint(x: 0.559, y: 0.329), control1: CGPoint(x: 0.455, y: 0.397), control2: CGPoint(x: 0.503, y: 0.329))
    letter.addCurve(to: CGPoint(x: 0.592, y: 0.364), control1: CGPoint(x: 0.585, y: 0.329), control2: CGPoint(x: 0.595, y: 0.343))
    letter.addCurve(to: CGPoint(x: 0.646, y: 0.409), control1: CGPoint(x: 0.584, y: 0.394), control2: CGPoint(x: 0.607, y: 0.413))
    letter.addCurve(to: CGPoint(x: 0.704, y: 0.354), control1: CGPoint(x: 0.679, y: 0.407), control2: CGPoint(x: 0.699, y: 0.385))
    letter.closeSubpath()
    let foil = CGMutablePath()
    foil.move(to: CGPoint(x: 0.168, y: 0.742))
    foil.addCurve(to: CGPoint(x: 0.82, y: 0.701), control1: CGPoint(x: 0.354, y: 0.667), control2: CGPoint(x: 0.561, y: 0.819))
    foil.addLine(to: CGPoint(x: 0.8, y: 0.817))
    foil.addCurve(to: CGPoint(x: 0.188, y: 0.85), control1: CGPoint(x: 0.552, y: 0.921), control2: CGPoint(x: 0.349, y: 0.769))
    foil.addLine(to: CGPoint(x: 0.207, y: 0.794))
    foil.closeSubpath()
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 0.183, y: 0.76))
    ribbon.addCurve(to: CGPoint(x: 0.816, y: 0.722), control1: CGPoint(x: 0.366, y: 0.697), control2: CGPoint(x: 0.568, y: 0.841))
    ribbon.addLine(to: CGPoint(x: 0.803, y: 0.794))
    ribbon.addCurve(to: CGPoint(x: 0.189, y: 0.829), control1: CGPoint(x: 0.559, y: 0.899), control2: CGPoint(x: 0.355, y: 0.751))
    ribbon.addLine(to: CGPoint(x: 0.219, y: 0.789))
    ribbon.closeSubpath()
    for (path, hex) in [(foil, 0xF4A261), (ribbon, 0xD62828), (letter, 0xFFF3E2)] {
        cg.addPath(path)
        cg.setFillColor(color(hex))
        cg.fillPath()
    }
}

func color(_ hex: Int) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

// A continuous-corner cubic squircle, inset only on macOS.
func tilePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0.5, y: 0))
    p.addCurve(to: CGPoint(x: 1, y: 0.5), control1: CGPoint(x: 0.94, y: 0), control2: CGPoint(x: 1, y: 0.06))
    p.addCurve(to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 1, y: 0.94), control2: CGPoint(x: 0.94, y: 1))
    p.addCurve(to: CGPoint(x: 0, y: 0.5), control1: CGPoint(x: 0.06, y: 1), control2: CGPoint(x: 0, y: 0.94))
    p.addCurve(to: CGPoint(x: 0.5, y: 0), control1: CGPoint(x: 0, y: 0.06), control2: CGPoint(x: 0.06, y: 0))
    p.closeSubpath()
    return p
}

func renderIcon(size: Int, opaque: Bool, outputPath: URL) throws {
    // Supersample every size for clean small-size edges, then downsample once.
    let scale = 4
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: CGFloat(pixels), y: -CGFloat(pixels))
    if !opaque {
        cg.translateBy(x: 0.065, y: 0.065)
        cg.scaleBy(x: 0.87, y: 0.87)
        cg.addPath(tilePath())
        cg.clip()
    }
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x6B3418), color(0x381808)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1, y: 1),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    drawMark(in: cg)

    let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: opaque ? 3 : 4, hasAlpha: !opaque, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: output)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: pixels, height: pixels))
        .draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try output.representation(using: .png, properties: [:])!.write(to: outputPath)
}

// Resolve against this script, never a developer's primary checkout or current directory.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for platform in ["IOS", "Watch", "Mac"] {
    let directory = root.appendingPathComponent("Apps/Choclift\(platform)/Resources/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in platform == "Mac" ? [16, 32, 64, 128, 256, 512, 1024] : [1024] {
        let filename = platform == "Mac" ? "icon_\(size).png" : "AppIcon-1024.png"
        try renderIcon(size: size, opaque: platform != "Mac", outputPath: directory.appendingPathComponent(filename))
    }
}
print("Generated Choclift icons in \(root.path)")

import AppKit
import CoreGraphics
import Foundation

// Coordinates use a unit square with the origin at top left. Keep these outlines
// in sync with ChocliftBrandIconView; the letter never depends on installed fonts.
func drawMark(in cg: CGContext) {
    let letter = CGMutablePath()
    letter.move(to: CGPoint(x: 0.718, y: 0.255))
    letter.addCurve(to: CGPoint(x: 0.419, y: 0.222), control1: CGPoint(x: 0.655, y: 0.175), control2: CGPoint(x: 0.521, y: 0.167))
    letter.addCurve(to: CGPoint(x: 0.285, y: 0.548), control1: CGPoint(x: 0.304, y: 0.284), control2: CGPoint(x: 0.256, y: 0.438))
    letter.addCurve(to: CGPoint(x: 0.602, y: 0.625), control1: CGPoint(x: 0.316, y: 0.671), control2: CGPoint(x: 0.483, y: 0.698))
    letter.addCurve(to: CGPoint(x: 0.701, y: 0.521), control1: CGPoint(x: 0.647, y: 0.598), control2: CGPoint(x: 0.679, y: 0.561))
    letter.addLine(to: CGPoint(x: 0.626, y: 0.475))
    letter.addCurve(to: CGPoint(x: 0.488, y: 0.566), control1: CGPoint(x: 0.586, y: 0.535), control2: CGPoint(x: 0.54, y: 0.566))
    letter.addCurve(to: CGPoint(x: 0.427, y: 0.42), control1: CGPoint(x: 0.416, y: 0.566), control2: CGPoint(x: 0.406, y: 0.497))
    letter.addCurve(to: CGPoint(x: 0.549, y: 0.284), control1: CGPoint(x: 0.45, y: 0.332), control2: CGPoint(x: 0.494, y: 0.284))
    letter.addCurve(to: CGPoint(x: 0.6, y: 0.332), control1: CGPoint(x: 0.583, y: 0.284), control2: CGPoint(x: 0.598, y: 0.303))
    letter.addLine(to: CGPoint(x: 0.694, y: 0.332))
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

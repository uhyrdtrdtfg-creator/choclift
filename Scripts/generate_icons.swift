import AppKit
import CoreGraphics
import CoreText
import Foundation

func renderIcon(size: Int, outputPath: String) throws {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to allocate bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. Rich roasted chocolate background gradient
    let bgColors = [
        CGColor(red: 0.44, green: 0.21, blue: 0.10, alpha: 1.0),
        CGColor(red: 0.20, green: 0.08, blue: 0.03, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // 2. Subtle inner chocolate bevel
    let insetRect = rect.insetBy(dx: s * 0.055, dy: s * 0.055)
    let innerPath = CGPath(roundedRect: insetRect, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    cg.saveGState()
    cg.addPath(innerPath)
    cg.setStrokeColor(CGColor(red: 0.65, green: 0.36, blue: 0.20, alpha: 0.45))
    cg.setLineWidth(s * 0.018)
    cg.strokePath()
    cg.restoreGState()

    // 3. Gold foil swoop + Crimson wrapper wave at bottom-left (matching Choclift icon!)
    cg.saveGState()
    let goldPath = CGMutablePath()
    goldPath.move(to: CGPoint(x: 0, y: s * 0.36))
    goldPath.addQuadCurve(to: CGPoint(x: s * 0.86, y: 0), control: CGPoint(x: s * 0.42, y: s * 0.22))
    goldPath.addLine(to: CGPoint(x: 0, y: 0))
    goldPath.closeSubpath()
    cg.addPath(goldPath)
    cg.clip()
    let goldGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.92, green: 0.67, blue: 0.32, alpha: 1.0),
            CGColor(red: 0.68, green: 0.41, blue: 0.16, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(goldGrad, start: CGPoint(x: 0, y: s * 0.36), end: CGPoint(x: s * 0.85, y: 0), options: [])
    cg.restoreGState()

    cg.saveGState()
    let redPath = CGMutablePath()
    redPath.move(to: CGPoint(x: 0, y: s * 0.30))
    redPath.addQuadCurve(to: CGPoint(x: s * 0.72, y: 0), control: CGPoint(x: s * 0.30, y: s * 0.14))
    redPath.addLine(to: CGPoint(x: 0, y: 0))
    redPath.closeSubpath()
    cg.addPath(redPath)
    cg.clip()
    let redGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.86, green: 0.15, blue: 0.14, alpha: 1.0),
            CGColor(red: 0.52, green: 0.05, blue: 0.05, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(redGrad, start: CGPoint(x: 0, y: s * 0.30), end: CGPoint(x: s * 0.72, y: 0), options: [])
    cg.restoreGState()

    // 4. Cream serif italic "c" in the center
    let font = NSFont(name: "Georgia-BoldItalic", size: s * 0.64)
        ?? NSFont.systemFont(ofSize: s * 0.64, weight: .black)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    shadow.shadowBlurRadius = s * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.025)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.87, alpha: 1.0),
        .shadow: shadow
    ]
    let str = NSAttributedString(string: "c", attributes: attrs)
    let textSize = str.size()
    let drawOrigin = CGPoint(
        x: (s - textSize.width) / 2.0 - s * 0.02,
        y: (s - textSize.height) / 2.0 + s * 0.06
    )
    str.draw(at: drawOrigin)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    try png.write(to: URL(fileURLWithPath: outputPath))
}

let fm = FileManager.default
let iosIconDir = "/Users/xiaobo/choclift/Apps/ChocliftIOS/Resources/Assets.xcassets/AppIcon.appiconset"
let watchIconDir = "/Users/xiaobo/choclift/Apps/ChocliftWatch/Resources/Assets.xcassets/AppIcon.appiconset"
let macIconDir = "/Users/xiaobo/choclift/Apps/ChocliftMac/Resources/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: iosIconDir, withIntermediateDirectories: true)
try fm.createDirectory(atPath: watchIconDir, withIntermediateDirectories: true)
try fm.createDirectory(atPath: macIconDir, withIntermediateDirectories: true)

try renderIcon(size: 1024, outputPath: "\(iosIconDir)/AppIcon-1024.png")
try renderIcon(size: 1024, outputPath: "\(watchIconDir)/AppIcon-1024.png")
for sz in [16, 32, 64, 128, 256, 512, 1024] {
    try renderIcon(size: sz, outputPath: "\(macIconDir)/icon_\(sz).png")
}
print("Generated icons successfully")

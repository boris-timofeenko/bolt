// Draws App/AppIcon.icns: a dark tile with a flat yellow bolt, on the macOS icon grid
// (824 px tile on a 1024 px canvas). Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let scale = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // A thin frame inside the tile: the photo the bolt sits on.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 120, dy: 120), cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(14)
    ctx.strokePath()

    let bolt: [CGPoint] = [(580, 800), (370, 500), (500, 500), (430, 224), (660, 560), (526, 560), (600, 800)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    ctx.addLines(between: bolt)
    ctx.closePath()
    ctx.setFillColor(CGColor(red: 1.0, green: 0.78, blue: 0.16, alpha: 1))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(iconset.path)

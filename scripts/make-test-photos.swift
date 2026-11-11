// Generates a folder of synthetic photos for manual testing and benchmarks.
//
//   swift scripts/make-test-photos.swift <out-dir> [count] [--size 4032x3024] [--format heic|jpg|png] [--broken]
//
// Every fourth shot belongs to a "burst": same scene, slightly shifted, some blurred.
// Every fifth shot is stored landscape with EXIF orientation 6, like an iPhone portrait photo.

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

var positional: [String] = []
var size = (width: 4032, height: 3024)
var format = "heic"
var broken = false

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iterator.next() {
    switch arg {
    case "--size":
        let parts = (iterator.next() ?? "").split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 { size = (parts[0], parts[1]) }
    case "--format":
        format = iterator.next() ?? format
    case "--broken":
        broken = true
    default:
        positional.append(arg)
    }
}

guard let outPath = positional.first else {
    print("usage: make-test-photos.swift <out-dir> [count] [--size WxH] [--format heic|jpg|png] [--broken]")
    exit(1)
}
let count = positional.count > 1 ? Int(positional[1]) ?? 40 : 40
let outDir = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let type: UTType = switch format {
case "jpg", "jpeg": .jpeg
case "png": .png
default: .heic
}

func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
    let h = (hue - floor(hue)) * 6
    let c = brightness * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = brightness - c
    let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) {
    case 0: (c, x, 0)
    case 1: (x, c, 0)
    case 2: (0, c, x)
    case 3: (0, x, c)
    case 4: (x, 0, c)
    default: (c, 0, x)
    }
    return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
}

func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2)
    CTLineDraw(line, ctx)
}

func makeScene(index: Int, width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let burst = index / 4
    let hue = CGFloat(burst % 12) / 12
    let w = CGFloat(width), h = CGFloat(height)

    let gradient = CGGradient(colorsSpace: nil, colors: [
        color(hue: hue, saturation: 0.55, brightness: 0.95),
        color(hue: hue + 0.15, saturation: 0.7, brightness: 0.35),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])

    // Shift inside a burst so neighbouring frames differ a little, like a real series.
    let shift = CGFloat(index % 4) * w * 0.01
    for i in 0..<6 {
        let radius = h * (0.08 + CGFloat(i) * 0.025)
        let cx = w * (0.15 + CGFloat(i) * 0.14) + shift
        let cy = h * (0.3 + 0.4 * CGFloat((i * 7 + burst) % 5) / 5)
        ctx.setFillColor(color(hue: hue + CGFloat(i) * 0.08, saturation: 0.8, brightness: 0.9))
        ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
    }

    // Fine detail for checking sharpness at 100%.
    let patch = CGRect(x: w * 0.62 + shift, y: h * 0.08, width: w * 0.3, height: h * 0.25)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(patch)
    ctx.setFillColor(gray: 0, alpha: 1)
    var x = patch.minX
    var step: CGFloat = 1
    while x < patch.maxX {
        ctx.fill(CGRect(x: x, y: patch.minY, width: step, height: patch.height))
        x += step * 2
        step = step >= 8 ? 1 : step + 1
    }

    let label = CGColor(gray: 1, alpha: 0.92)
    drawText(String(format: "%03d", index + 1), in: ctx, at: CGPoint(x: w / 2, y: h * 0.62), size: h * 0.22, color: label)
    drawText("burst \(burst + 1) · frame \(index % 4 + 1)", in: ctx, at: CGPoint(x: w / 2, y: h * 0.42), size: h * 0.04, color: label)
    drawText("TOP", in: ctx, at: CGPoint(x: w / 2, y: h * 0.94), size: h * 0.035, color: label)
    return ctx.makeImage()!
}

func blurred(_ image: CGImage, radius: Double) -> CGImage {
    let input = CIImage(cgImage: image)
    let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
    return CIContext().createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: image.colorSpace)!
}

/// Stores a display-oriented image rotated 90° counter-clockwise so that EXIF orientation 6 shows it upright.
func rotatedForOrientation6(_ image: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                        space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: CGFloat(image.height), y: 0)
    ctx.rotate(by: .pi / 2)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

let exifDate = DateFormatter()
exifDate.locale = Locale(identifier: "en_US_POSIX")
exifDate.dateFormat = "yyyy:MM:dd HH:mm:ss"
let start = exifDate.date(from: "2026:10:12 14:03:00")!

for index in 0..<count {
    let portrait = index % 5 == 4
    var image = portrait
        ? makeScene(index: index, width: size.height, height: size.width)
        : makeScene(index: index, width: size.width, height: size.height)
    if index % 4 == 3 { image = blurred(image, radius: 6) }
    if portrait { image = rotatedForOrientation6(image) }

    let date = exifDate.string(from: start.addingTimeInterval(Double(index) * 37))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: portrait ? 6 : 1,
        kCGImageDestinationEmbedThumbnail: true,
        kCGImageDestinationLossyCompressionQuality: 0.8,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 15 Pro",
            kCGImagePropertyTIFFDateTime: date,
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: date,
            kCGImagePropertyExifDateTimeDigitized: date,
            kCGImagePropertyExifISOSpeedRatings: [64 + index % 8 * 50],
            kCGImagePropertyExifExposureTime: 1.0 / Double(60 + index % 5 * 60),
            kCGImagePropertyExifFNumber: 1.78,
            kCGImagePropertyExifFocalLength: 6.86,
            kCGImagePropertyExifFocalLenIn35mmFilm: 24,
            kCGImagePropertyExifLensModel: "iPhone 15 Pro back triple camera 6.86mm f/1.78",
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 59.9386 + Double(index) * 0.0001,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 30.3141,
            kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]

    // Mixed case and numbering on purpose: natural sort must put IMG_9 before IMG_10.
    let name = String(format: "IMG_%d.%@", index + 1, type.preferredFilenameExtension?.uppercased() ?? format)
    let url = outDir.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        print("failed: \(name)")
        continue
    }
    print(name)
}

if broken {
    FileManager.default.createFile(atPath: outDir.appendingPathComponent("empty.jpg").path, contents: Data())
    FileManager.default.createFile(atPath: outDir.appendingPathComponent("garbage.heic").path,
                                   contents: Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
    if let first = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
        .first(where: { $0.lastPathComponent.hasPrefix("IMG_") }) {
        let data = try Data(contentsOf: first)
        try data.prefix(data.count / 3).write(to: outDir.appendingPathComponent("truncated.\(first.pathExtension)"))
    }
    print("broken files added")
}

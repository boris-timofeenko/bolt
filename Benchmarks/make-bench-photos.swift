// Photos for comparing viewers: iPhone-sized HEIC with an embedded thumbnail, built so a screen
// recording can tell which photo is on screen and whether it's the sharp one.
//
//   swiftc -O Benchmarks/make-bench-photos.swift -o .build/make-bench-photos
//   .build/make-bench-photos <out-dir> [count] [width] [height]
//
// Photo i is filled with hue frac(i × 0.618): neighbours always differ by ~0.38 of the colour wheel.
// Vertical stripes 12 px apart cover the whole frame; a screen-sized decode keeps them, the 320 px
// embedded thumbnail blurs them away. Per-pixel grain gives the file a real photo's size.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: make-bench-photos <out-dir> [count] [width] [height]")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
let count = arguments.count > 2 ? Int(arguments[2]) ?? 200 : 200
let width = arguments.count > 3 ? Int(arguments[3]) ?? 4032 : 4032
let height = arguments.count > 4 ? Int(arguments[4]) ?? 3024 : 3024
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Shared with the measuring tool: the hue photo `index` is filled with.
func hue(of index: Int) -> Double {
    (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
}

func rgb(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
    let h = hue * 6
    let c = value * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = value - c
    let (r, g, b): (Double, Double, Double) = switch Int(h) {
    case 0: (c, x, 0)
    case 1: (x, c, 0)
    case 2: (0, c, x)
    case 3: (0, x, c)
    case 4: (x, 0, c)
    default: (c, 0, x)
    }
    return (r + m, g + m, b + m)
}

var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
func nextRandom() -> UInt64 {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return seed
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let exifDate = DateFormatter()
exifDate.locale = Locale(identifier: "en_US_POSIX")
exifDate.dateFormat = "yyyy:MM:dd HH:mm:ss"
let start = Date(timeIntervalSince1970: 1_791_800_000)

for index in 0..<count {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let (r, g, b) = rgb(hue: hue(of: index), saturation: 0.7, value: 0.72)
    let dark = [r, g, b].map { UInt8(($0 * 0.8 * 255).rounded()) }
    let light = [r, g, b].map { UInt8(min($0 * 1.25, 1) * 255) }
    for y in 0..<height {
        let row = pixels + y * width * 4
        for x in 0..<width {
            let base = (x / 6) % 2 == 0 ? dark : light
            let grain = Int(nextRandom() & 15) - 8
            let pixel = row + x * 4
            pixel[0] = UInt8(clamping: Int(base[0]) + grain)
            pixel[1] = UInt8(clamping: Int(base[1]) + grain)
            pixel[2] = UInt8(clamping: Int(base[2]) + grain)
        }
    }
    let image = context.makeImage()!
    let name = String(format: "IMG_%04d.HEIC", index + 1)
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                      UTType.heic.identifier as CFString, 1, nil)!
    let date = exifDate.string(from: start.addingTimeInterval(Double(index) * 5))
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationEmbedThumbnail: true,
        kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro"],
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(name)") }
}
print("\(count) photos in \(output.path)")

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import IOSurface

/// Screen-sized frames of HEIC and JPEG photos, decoded and scaled by Core Image into GPU memory that a layer
/// shows without a copy. On iPhone photos it takes ~16 ms against ImageIO's ~47 (~150 with HDR), and four can
/// run at once where ImageIO stops gaining after two (perf-lab/decode/RESULTS.md).
enum CoreImageFrames {
    /// One context for the app: it is thread-safe, and every new one compiles its GPU kernels again.
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Bolt frames"])
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let extendedLinearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// Where Core Image is faster and shows the same picture. Everything else (PNG, GIF, TIFF, RAW, AVIF…)
    /// stays with ImageIO.
    static func handles(_ info: ImageInfo) -> Bool {
        guard let type = info.typeIdentifier, !info.isAnimated else { return false }
        return ["public.heic", "public.heif", "public.jpeg"].contains(type)
    }

    /// The photo rendered `longSide` pixels long, EXIF orientation applied. With `headroom` above 1 (an EDR screen),
    /// a photo with a gain map is rendered as HDR for that much headroom into a half-float frame.
    /// Nil when Core Image fails, and for colour that isn't plain RGB (CMYK, grey, HDR without a gain map):
    /// ImageIO knows those better.
    static func decode(_ source: CGImageSource, longSide: Int, headroom: CGFloat) -> (surface: IOSurface, isHDR: Bool)? {
        var image = CIImage(cgImageSource: source, index: 0, options: [.applyOrientationProperty: true])
        guard !image.extent.isEmpty, let space = image.colorSpace, space.model == .rgb,
              !CGColorSpaceUsesExtendedRange(space), !CGColorSpaceUsesITUR_2100TF(space) else { return nil }

        var contentHeadroom: CGFloat = 1
        if headroom > 1, #available(macOS 15, *) {
            let gainMap = CIImage(cgImageSource: source, index: 0,
                                  options: [.applyOrientationProperty: true, .auxiliaryHDRGainMap: true])
            if !gainMap.extent.isEmpty {
                // As much of the gain map as the screen can show, like ImageIO's HDR decode, rather than all of it
                // with the highlights the screen can't reach clipped.
                image = image.applyingGainMap(gainMap, headroom: Float(headroom))
                contentHeadroom = CGFloat(image.contentHeadroom)
            }
        }
        let isHDR = contentHeadroom > 1

        // Rounded the way ImageIO rounds, so both paths make frames of the same size.
        let original = max(image.extent.width, image.extent.height)
        let width = max(Int((image.extent.width * CGFloat(longSide) / original).rounded(.toNearestOrEven)), 1)
        let height = max(Int((image.extent.height * CGFloat(longSide) / original).rounded(.toNearestOrEven)), 1)
        let fitted = image
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                               y: CGFloat(height) / image.extent.height))
        let placed = fitted.transformed(by: CGAffineTransform(translationX: -fitted.extent.minX, y: -fitted.extent.minY))

        guard let surface = render(placed, width: width, height: height, hdr: isHDR) else { return nil }
        if isHDR, #available(macOS 15, *) {
            // The layer tone maps from this down to what the screen has right now, as it does for ImageIO's HDR frames.
            IOSurfaceSetValue(surface, kIOSurfaceContentHeadroom, contentHeadroom as CFNumber)
        }
        return (surface, isHDR)
    }

    /// Renders into a new IOSurface tagged with its colour space: 8-bit Display P3, or half-float extended linear
    /// Display P3 for HDR, twice the memory. A 10-bit PQ frame would be as small as the 8-bit one, but nothing here
    /// confirmed an EDR layer shows it right (FLIP-RESULTS.md).
    static func render(_ image: CIImage, width: Int, height: Int, hdr: Bool) -> IOSurface? {
        let space = hdr ? extendedLinearDisplayP3 : displayP3
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = space
        do {
            try context.startTask(toRender: image, to: destination).waitUntilCompleted()
        } catch {
            return nil
        }
        if let plist = space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist) }
        return surface
    }

    /// A frame `render` made, as a Core Image image again.
    static func image(of surface: IOSurface, hdr: Bool) -> CIImage {
        CIImage(ioSurface: surface, options: [.colorSpace: hdr ? extendedLinearDisplayP3 : displayP3])
    }

    /// An 8-bit bitmap in `colorSpace`, sRGB if nil.
    static func cgImage(_ image: CIImage, colorSpace: CGColorSpace?) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .BGRA8,
                              colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

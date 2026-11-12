import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import IOSurface

public enum FrameKind: Int, Comparable, Sendable {
    /// The thumbnail the camera embedded in the file. Milliseconds to get, blurry.
    case preview
    /// Decoded straight to the size of the screen. What the viewer normally shows.
    case screen
    /// Every pixel, for zooming past the screen size.
    case full

    public static func < (lhs: FrameKind, rhs: FrameKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A fully decoded bitmap, ready to be handed to a layer without further work on the main thread.
public struct DecodedFrame: @unchecked Sendable {
    public enum Bitmap {
        /// Decoded by ImageIO.
        case image(CGImage)
        /// Rendered by Core Image into GPU memory, tagged with its colour space (`CoreImageFrames`).
        case surface(IOSurface)
    }

    public let bitmap: Bitmap
    public let kind: FrameKind
    public let info: ImageInfo
    public let decodeTime: Duration
    /// Brighter-than-white pixels, from an iPhone gain map or an HDR format.
    public let isHDR: Bool

    public init(image: CGImage, kind: FrameKind, info: ImageInfo, decodeTime: Duration) {
        bitmap = .image(image)
        self.kind = kind
        self.info = info
        self.decodeTime = decodeTime
        isHDR = image.colorSpace.map { CGColorSpaceUsesExtendedRange($0) || CGColorSpaceUsesITUR_2100TF($0) } ?? false
    }

    init(surface: IOSurface, isHDR: Bool, kind: FrameKind, info: ImageInfo, decodeTime: Duration) {
        bitmap = .surface(surface)
        self.kind = kind
        self.info = info
        self.decodeTime = decodeTime
        self.isHDR = isHDR
    }

    /// What `CALayer.contents` takes.
    public var layerContents: Any {
        switch bitmap {
        case .image(let image): image
        case .surface(let surface): surface
        }
    }

    /// The ImageIO bitmap; nil for a frame Core Image rendered.
    public var cgImage: CGImage? {
        if case .image(let image) = bitmap { image } else { nil }
    }

    /// The frame as a Core Image image, for turning it or drawing a copy.
    public var ciImage: CIImage {
        switch bitmap {
        case .image(let image): CIImage(cgImage: image)
        case .surface(let surface): CoreImageFrames.image(of: surface, hdr: isHDR)
        }
    }

    public var width: Int {
        switch bitmap {
        case .image(let image): image.width
        case .surface(let surface): IOSurfaceGetWidth(surface)
        }
    }

    public var height: Int {
        switch bitmap {
        case .image(let image): image.height
        case .surface(let surface): IOSurfaceGetHeight(surface)
        }
    }

    /// Bytes held.
    public var cost: Int {
        switch bitmap {
        case .image(let image): image.bytesPerRow * image.height
        case .surface(let surface): IOSurfaceGetAllocSize(surface)
        }
    }

    public var longSide: Int { max(width, height) }

    /// A better replacement for `other` on screen: a higher kind, or the same kind decoded bigger.
    public func isSharper(than other: DecodedFrame?) -> Bool {
        guard let other else { return true }
        return kind > other.kind || longSide > other.longSide
    }

    /// True when the bitmap has every pixel of the original, so a bigger decode would add nothing.
    public var isFullResolution: Bool {
        longSide >= max(info.pixelWidth, info.pixelHeight)
    }

    /// The same pixels turned by `orientation`, without reading the file again. `info` describes the result.
    public func turned(_ orientation: CGImagePropertyOrientation, info: ImageInfo) -> DecodedFrame? {
        let turned = ciImage.oriented(orientation)
        let placed = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
        switch bitmap {
        case .image(let image):
            guard let result = CoreImageFrames.cgImage(placed, colorSpace: image.colorSpace) else { return nil }
            return DecodedFrame(image: result, kind: kind, info: info, decodeTime: decodeTime)
        case .surface(let surface):
            guard let result = CoreImageFrames.render(placed, width: Int(placed.extent.width),
                                                      height: Int(placed.extent.height), hdr: isHDR) else { return nil }
            if #available(macOS 15, *), let headroom = IOSurfaceCopyValue(surface, kIOSurfaceContentHeadroom) {
                IOSurfaceSetValue(result, kIOSurfaceContentHeadroom, headroom)
            }
            return DecodedFrame(surface: result, isHDR: isHDR, kind: kind, info: info, decodeTime: decodeTime)
        }
    }
}

/// Stateless decoding: ImageIO, and Core Image for screen frames where it is faster. Safe to call from any thread.
public enum ImageDecoder {
    /// CALayer refuses bitmaps above this size on Apple silicon GPUs.
    public static let maxTextureSide = 16384

    public static func info(at url: URL) -> ImageInfo? {
        if MediaTypes.isVideo(url) { return VideoFrames.info(at: url) }
        return openSource(url).flatMap(readInfo)
    }

    public static func captureDate(at url: URL) -> Date? {
        info(at: url)?.captureDate
    }

    /// Shooting dates of many files, read on all cores. Files without one are left out.
    public static func captureDates(of urls: [URL]) -> [URL: Date] {
        let dates = concurrentMap(urls) { captureDate(at: $0) }
        return Dictionary(uniqueKeysWithValues: zip(urls, dates).compactMap { url, date in date.map { (url, $0) } })
    }

    /// The embedded thumbnail only. Never decodes the main image, so it returns nil for files without one.
    public static func preview(at url: URL, maxPixelSize: Int = 1280) -> DecodedFrame? {
        let clock = ContinuousClock.now
        guard let source = openSource(url), let info = readInfo(source),
              let image = thumbnail(source, maxPixelSize: maxPixelSize, decodeMainImage: false) else { return nil }
        return DecodedFrame(image: image, kind: .preview, info: info, decodeTime: clock.duration(to: .now))
    }

    /// Decodes at the size the image takes when fitted into `target` (in pixels), never larger than the original.
    /// With `headroom` above 1 (an EDR screen), photos that carry HDR data keep it, for that much headroom.
    public static func screen(at url: URL, fitting target: CGSize, headroom: CGFloat = 1) -> DecodedFrame? {
        let clock = ContinuousClock.now
        if MediaTypes.isVideo(url) { return videoPoster(at: url, fitting: target, since: clock) }
        guard let source = openSource(url), let info = readInfo(source) else { return nil }
        let longSide = fittedLongSide(of: info.pixelSize, in: target)
        let kind: FrameKind = longSide >= max(info.pixelWidth, info.pixelHeight) ? .full : .screen

        if CoreImageFrames.handles(info),
           let decoded = CoreImageFrames.decode(source, longSide: longSide, headroom: headroom) {
            return DecodedFrame(surface: decoded.surface, isHDR: decoded.isHDR, kind: kind, info: info,
                                decodeTime: clock.duration(to: .now))
        }
        var image: CGImage?
        if MediaTypes.isRaw(url) {
            // RAW files usually carry a full-size JPEG; demosaicing is ten times slower.
            image = thumbnail(source, maxPixelSize: longSide, decodeMainImage: false, hdr: false)
            if let embedded = image, Double(max(embedded.width, embedded.height)) < Double(longSide) * 0.9 {
                image = nil
            }
        }
        guard let image = image ?? thumbnail(source, maxPixelSize: longSide, decodeMainImage: true, hdr: headroom > 1)
        else { return nil }
        return DecodedFrame(image: image, kind: kind, info: info, decodeTime: clock.duration(to: .now))
    }

    /// Every pixel, capped at the largest texture a layer can show.
    public static func full(at url: URL, hdr: Bool = false) -> DecodedFrame? {
        let clock = ContinuousClock.now
        if MediaTypes.isVideo(url) { return videoPoster(at: url, fitting: CGSize(width: maxTextureSide, height: maxTextureSide), since: clock) }
        guard let source = openSource(url), let info = readInfo(source) else { return nil }
        let longSide = min(max(info.pixelWidth, info.pixelHeight), maxTextureSide)
        guard let image = thumbnail(source, maxPixelSize: longSide, decodeMainImage: true, hdr: hdr) else { return nil }
        return DecodedFrame(image: image, kind: .full, info: info, decodeTime: clock.duration(to: .now))
    }

    /// A small image for grids and strips: the embedded thumbnail when it is big enough, a real decode otherwise.
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        if MediaTypes.isVideo(url) { return VideoFrames.poster(at: url, maxPixelSize: maxPixelSize) }
        guard let source = openSource(url) else { return nil }
        if let embedded = thumbnail(source, maxPixelSize: maxPixelSize, decodeMainImage: false),
           max(embedded.width, embedded.height) >= maxPixelSize * 3 / 4 {
            return embedded
        }
        return thumbnail(source, maxPixelSize: maxPixelSize, decodeMainImage: true)
    }

    public static func fittedLongSide(of size: CGSize, in target: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return 1 }
        let scale = min(target.width / size.width, target.height / size.height, 1)
        return max(Int((max(size.width, size.height) * scale).rounded(.up)), 1)
    }

    private static func videoPoster(at url: URL, fitting target: CGSize, since clock: ContinuousClock.Instant)
        -> DecodedFrame? {
        guard let info = VideoFrames.info(at: url),
              let image = VideoFrames.poster(at: url, maxPixelSize: fittedLongSide(of: info.pixelSize, in: target))
        else { return nil }
        // A poster is all a video frame will ever be here; playback is the player's job.
        return DecodedFrame(image: image, kind: .full, info: info, decodeTime: clock.duration(to: .now))
    }

    // MARK: - ImageIO

    private static func openSource(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func readInfo(_ source: CGImageSource) -> ImageInfo? {
        let count = CGImageSourceGetCount(source)
        guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        let info = ImageInfo(properties: properties, frameCount: count,
                             typeIdentifier: CGImageSourceGetType(source) as String?)
        return info.pixelWidth > 0 && info.pixelHeight > 0 ? info : nil
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int, decodeMainImage: Bool,
                                  hdr: Bool = false) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: decodeMainImage,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: decodeMainImage,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

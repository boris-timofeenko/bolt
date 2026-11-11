import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case jpeg, heic, avif, png, tiff

    public var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        case .png: .png
        case .tiff: .tiff
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .avif: "avif"
        case .png: "png"
        case .tiff: "tiff"
        }
    }

    public var isLossy: Bool { self == .jpeg || self == .heic || self == .avif }

    /// Formats this Mac can write. WebP, for one, ImageIO only reads.
    public static var available: [ExportFormat] {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return allCases.filter { writable.contains($0.type.identifier) }
    }
}

public enum MetadataPolicy: String, CaseIterable, Codable, Sendable {
    case keep
    /// GPS and camera/lens serial numbers: what gives away where you were and which camera is yours.
    case removePrivate
    case removeAll
}

public struct ExportSettings: Codable, Equatable, Sendable {
    /// Nil keeps the original format.
    public var format: ExportFormat?
    public var quality: Double
    /// Long side in pixels; nil keeps the original size. Never enlarges.
    public var maxLongSide: Int?
    public var metadata: MetadataPolicy

    public init(format: ExportFormat? = .jpeg, quality: Double = 0.85, maxLongSide: Int? = nil,
                metadata: MetadataPolicy = .keep) {
        self.format = format
        self.quality = quality
        self.maxLongSide = maxLongSide
        self.metadata = metadata
    }
}

public enum ExportError: LocalizedError {
    case unreadable
    case unwritable

    public var errorDescription: String? {
        switch self {
        case .unreadable: NSLocalizedString("The file can't be read.", comment: "")
        case .unwritable: NSLocalizedString("Couldn't write the new file.", comment: "")
        }
    }
}

/// Re-encodes photos: crop, resize, convert, drop metadata. The pixels are oriented on the way,
/// so the result has orientation 1 and looks the same everywhere.
public enum ImageExporter {
    /// Writes an edited version of `source` to `destination` and returns where it ended up:
    /// if another export took that name meanwhile, the file gets " (2)" instead of replacing it.
    /// `crop` is a fraction of the displayed (oriented) image, origin at the top left.
    @discardableResult
    public static func export(_ source: URL, to destination: URL, settings: ExportSettings,
                              crop: CGRect? = nil) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(imageSource),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        else { throw ExportError.unreadable }
        let info = ImageInfo(properties: properties)
        let fullSide = max(info.pixelWidth, info.pixelHeight)

        // Without a crop, ImageIO can decode straight to the target size, which is much faster.
        let decodeSide = crop == nil ? min(settings.maxLongSide ?? fullSide, fullSide) : fullSide
        guard var image = decode(imageSource, longSide: decodeSide) else { throw ExportError.unreadable }
        if let crop {
            let rect = CGRect(x: crop.minX * CGFloat(image.width), y: crop.minY * CGFloat(image.height),
                              width: crop.width * CGFloat(image.width), height: crop.height * CGFloat(image.height))
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !rect.isEmpty, let cropped = image.cropping(to: rect) else { throw ExportError.unreadable }
            image = cropped
            if let limit = settings.maxLongSide, max(image.width, image.height) > limit {
                image = scaled(image, longSide: limit) ?? image
            }
        }

        let type = settings.format?.type.identifier as CFString? ?? sourceType
        let temporary = FileOperations.temporaryURL(beside: destination)
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else {
            throw ExportError.unwritable
        }
        var outputProperties = filteredMetadata(properties, policy: settings.metadata)
        outputProperties[kCGImageDestinationLossyCompressionQuality as String] = settings.quality
        CGImageDestinationAddImage(output, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ExportError.unwritable
        }
        do {
            return try FileOperations.move(temporary, to: destination)
        } catch let error as POSIXError where error.code == .EEXIST {
            return try FileOperations.move(temporary, into: destination.deletingLastPathComponent(),
                                           named: destination.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// "IMG_1.HEIC" exported as JPEG into `folder` → "IMG_1.jpg", or "IMG_1 (2).jpg" if taken.
    public static func destination(for source: URL, settings: ExportSettings, in folder: URL) -> URL {
        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        let ext = settings.format?.fileExtension ?? source.pathExtension
        return FileOperations.availableURL(for: ext.isEmpty ? stem : "\(stem).\(ext)", in: folder)
    }

    // MARK: - Steps

    private static func decode(_ source: CGImageSource, longSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The source's metadata minus what the policy drops. Orientation is always reset:
    /// the pixels were already turned upright.
    static func filteredMetadata(_ properties: [String: Any], policy: MetadataPolicy) -> [String: Any] {
        var result: [String: Any] = [:]
        if policy != .removeAll {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary] {
                if let value = properties[key as String] { result[key as String] = value }
            }
        }
        if policy == .removePrivate {
            result[kCGImagePropertyGPSDictionary as String] = nil
            result[kCGImagePropertyExifAuxDictionary as String] = nil
            result[kCGImagePropertyMakerAppleDictionary as String] = nil
            if var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif[kCGImagePropertyExifBodySerialNumber as String] = nil
                exif[kCGImagePropertyExifLensSerialNumber as String] = nil
                exif[kCGImagePropertyExifCameraOwnerName as String] = nil
                result[kCGImagePropertyExifDictionary as String] = exif
            }
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        result[kCGImagePropertyOrientation as String] = 1
        return result
    }
}

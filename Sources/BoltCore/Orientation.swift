import Foundation
import ImageIO

/// EXIF orientation as "mirror horizontally (or not), then rotate clockwise by quarter turns".
/// All eight EXIF values fit this form, and composing with another rotation or flip stays in it.
public struct Orientation: Equatable, Sendable {
    public var mirrored: Bool
    /// Clockwise quarter turns, 0...3.
    public var quarterTurns: Int

    public init(mirrored: Bool = false, quarterTurns: Int = 0) {
        self.mirrored = mirrored
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
    }

    public init(exif value: Int) {
        switch value {
        case 2: self.init(mirrored: true, quarterTurns: 0)
        case 3: self.init(mirrored: false, quarterTurns: 2)
        case 4: self.init(mirrored: true, quarterTurns: 2)
        case 5: self.init(mirrored: true, quarterTurns: 3)
        case 6: self.init(mirrored: false, quarterTurns: 1)
        case 7: self.init(mirrored: true, quarterTurns: 1)
        case 8: self.init(mirrored: false, quarterTurns: 3)
        default: self.init()
        }
    }

    public var exifValue: Int {
        switch (mirrored, quarterTurns) {
        case (false, 1): 6
        case (false, 2): 3
        case (false, 3): 8
        case (true, 0): 2
        case (true, 1): 7
        case (true, 2): 4
        case (true, 3): 5
        default: 1
        }
    }

    /// The orientation that takes an image shown as `from` to how it looks as `to`.
    /// Lets the viewer rotate the bitmap it already has instead of decoding the file again.
    public static func relative(from: Orientation, to: Orientation) -> Orientation {
        to.composed(after: from.inverted)
    }

    public var inverted: Orientation {
        // R(k)·F is its own inverse; a plain rotation inverts to the opposite turn.
        mirrored ? self : Orientation(quarterTurns: -quarterTurns)
    }

    /// `self` applied after `other`: R(a)·F^m · R(b)·F^n.
    public func composed(after other: Orientation) -> Orientation {
        if mirrored {
            return Orientation(mirrored: !other.mirrored, quarterTurns: quarterTurns - other.quarterTurns)
        }
        return Orientation(mirrored: other.mirrored, quarterTurns: quarterTurns + other.quarterTurns)
    }

    /// Applies `transform` on top of what the viewer already shows.
    public func applying(_ transform: OrientationTransform) -> Orientation {
        switch transform {
        case .rotateRight:
            return Orientation(mirrored: mirrored, quarterTurns: quarterTurns + 1)
        case .rotateLeft:
            return Orientation(mirrored: mirrored, quarterTurns: quarterTurns - 1)
        case .flipHorizontal:
            // A mirror turns a clockwise rotation into a counter-clockwise one: F·R(k) = R(-k)·F.
            return Orientation(mirrored: !mirrored, quarterTurns: -quarterTurns)
        }
    }
}

public enum OrientationTransform: Sendable {
    case rotateLeft, rotateRight, flipHorizontal
}

public enum MetadataError: LocalizedError {
    case unreadable
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .unreadable: NSLocalizedString("The file can't be read.", comment: "")
        case .unsupportedFormat: NSLocalizedString("This format can't be rotated without re-encoding.", comment: "")
        }
    }
}

/// Lossless metadata edits: ImageIO copies the compressed image data and rewrites only the tags.
public enum MetadataWriter {
    public static func orientation(of url: URL) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw MetadataError.unreadable
        }
        return properties[kCGImagePropertyOrientation as String] as? Int ?? 1
    }

    /// Rewrites the EXIF orientation tag in place. Pixel data stays byte-for-byte the same.
    public static func setOrientation(_ value: Int, of url: URL) throws {
        try rewrite(url, options: [kCGImageDestinationOrientation: value])
    }

    /// Writes a copy of `url` without location and serial numbers to `destination`.
    /// The image data is copied as is, so nothing is re-encoded.
    public static func copyWithoutPrivateData(_ url: URL, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MetadataError.unreadable }
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let cleaned = CGImageMetadataCreateMutableCopy(metadata) {
            for path in ["exifEX:BodySerialNumber", "exifEX:LensSerialNumber", "exifEX:CameraOwnerName",
                         "aux:SerialNumber", "aux:LensSerialNumber", "aux:OwnerName"] {
                CGImageMetadataRemoveTagWithPath(cleaned, nil, path as CFString)
            }
            options[kCGImageDestinationMetadata] = cleaned
            options[kCGImageDestinationMergeMetadata] = false
        }
        try copy(source, to: destination, options: options)
    }

    private static func rewrite(_ url: URL, options: [CFString: Any]) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MetadataError.unreadable }
        let temporary = FileOperations.temporaryURL(beside: url)
        try copy(source, to: temporary, options: options)
        do {
            // replaceItemAt keeps the original's creation date, permissions and Finder tags.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Lossless: ImageIO copies the compressed image data and writes only the metadata anew.
    private static func copy(_ source: CGImageSource, to url: URL, options: [CFString: Any]) throws {
        guard let type = CGImageSourceGetType(source) else { throw MetadataError.unreadable }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw MetadataError.unsupportedFormat
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: url)
            throw error?.takeRetainedValue() as Error? ?? MetadataError.unsupportedFormat
        }
    }
}

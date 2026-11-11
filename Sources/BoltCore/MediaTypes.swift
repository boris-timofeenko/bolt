import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaTypes {
    /// Lower-cased extensions of every still-image format ImageIO can decode on this Mac, RAW included.
    public static let imageExtensions: Set<String> = {
        var extensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "webp", "avif", "dng"]
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        for identifier in identifiers {
            guard let type = UTType(identifier), !excluded.contains(where: type.conforms(to:)) else { continue }
            for ext in type.tags[.filenameExtension] ?? [] {
                extensions.insert(ext.lowercased())
            }
        }
        return extensions
    }()

    /// Formats ImageIO opens that nobody browses as photos.
    private static let excluded: [UTType] = [.pdf, .icns, .ico]

    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func isImage(_ url: URL) -> Bool {
        isImage(name: url.lastPathComponent)
    }

    public static func isImage(name: String) -> Bool {
        imageExtensions.contains(fileExtension(of: name))
    }

    public static func isVideo(_ url: URL) -> Bool {
        isVideo(name: url.lastPathComponent)
    }

    public static func isVideo(name: String) -> Bool {
        videoExtensions.contains(fileExtension(of: name))
    }

    /// Anything the viewer lists: photos and videos.
    public static func isMedia(name: String) -> Bool {
        isImage(name: name) || isVideo(name: name)
    }

    private static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
    }
}

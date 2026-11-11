import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small images for the grid and the strip, cached in memory and on disk.
///
/// The disk key is path + modification date + size, so a rotated or replaced file gets a fresh
/// thumbnail without any explicit invalidation.
public final class ThumbnailStore: @unchecked Sendable {
    public static let pixelSize = 384

    private struct Key: Hashable, Sendable {
        let path: String
        let modified: Date
        let size: Int64

        init(_ item: PhotoItem) {
            path = item.url.path
            modified = item.modified
            size = item.fileSize
        }
    }

    private struct Thumbnail: @unchecked Sendable {
        let image: CGImage
    }

    private let memory = LRUCache<Key, Thumbnail>(budget: 96 * 1024 * 1024)
    private let directory: URL
    private let diskLimit: Int

    public init(directory: URL, diskLimit: Int = 500 * 1024 * 1024) {
        self.directory = directory
        self.diskLimit = diskLimit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Memory only, safe on the main thread.
    public func cached(_ item: PhotoItem) -> CGImage? {
        memory.value(for: Key(item))?.image
    }

    /// Disk cache, or a fresh decode. Blocks; call it off the main thread.
    public func load(_ item: PhotoItem) -> CGImage? {
        let key = Key(item)
        if let hit = memory.value(for: key) { return hit.image }

        let file = diskURL(for: key)
        let image = read(file) ?? ImageDecoder.thumbnail(at: item.url, maxPixelSize: Self.pixelSize).map { image in
            write(image, to: file)
            return image
        }
        if let image {
            memory.insert(Thumbnail(image: image), for: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Deletes the oldest cached thumbnails until the folder is well under its limit.
    public func trimDisk() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        let entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > diskLimit else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > diskLimit * 8 / 10 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func diskURL(for key: Key) -> URL {
        let identity = "\(key.path)\n\(key.modified.timeIntervalSince1970)\n\(key.size)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".jpg")
    }

    private func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        // Reading marks the file as recently used, so trimming removes the ones nobody looked at.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func write(_ image: CGImage, to file: URL) {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

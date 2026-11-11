import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BoltCore

/// A temporary folder that removes itself, including anything a test sent to the Trash.
final class TemporaryFolder {
    let url: URL
    private var trashed: [URL] = []

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bolt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        for item in trashed { try? FileManager.default.removeItem(at: item) }
    }

    func noteTrashed(_ url: URL) { trashed.append(url) }

    @discardableResult
    func file(_ name: String, contents: String = "x") throws -> URL {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A real JPEG with a gradient, so decoders and metadata writers have something to chew on.
    @discardableResult
    func jpeg(_ name: String, width: Int = 64, height: Int = 48, orientation: Int = 1) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let file = url.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:12 14:03:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 59.93, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 30.31, kCGImagePropertyGPSLongitudeRef: "E"],
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }
}

func photo(_ name: String, size: Int64 = 0, modified: TimeInterval = 0) -> PhotoItem {
    PhotoItem(url: URL(fileURLWithPath: "/photos/\(name)"), fileSize: size, modified: Date(timeIntervalSince1970: modified))
}

/// Tests run in parallel and the Trash is shared: two files with the same name trashed at the same moment
/// can be given the same name there. Anything a test trashes gets a name no other test uses.
func uniqueName(_ name: String) -> String {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    let tag = UUID().uuidString.prefix(8)
    return ext.isEmpty ? "\(base)-\(tag)" : "\(base)-\(tag).\(ext)"
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Decoded pixels without applying orientation: identical bytes mean the compressed data was not touched.
func rawPixels(_ url: URL) throws -> Data {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return try #require(image.dataProvider?.data as Data?)
}

extension TemporaryFolder {
    /// Files an operation sent to the Trash get deleted together with this folder.
    func cleanUpTrash(after outcome: FileHistory.Outcome?) {
        for case .trashed(_, let trashed) in outcome?.changes ?? [] { noteTrashed(trashed) }
    }
}

/// The history's callbacks as async calls, so tests read top to bottom.
@MainActor
extension FileHistory {
    func performAndWait(_ requests: [FileRequest]) async -> Outcome {
        await withCheckedContinuation { continuation in
            perform(requests, label: "test") { continuation.resume(returning: $0) }
        }
    }

    func performBatchAndWait(_ requests: [FileRequest], progress: @escaping @MainActor @Sendable (Int, Int) -> Void)
        async -> Outcome {
        await withCheckedContinuation { continuation in
            performBatch(requests, label: "test", progress: progress) { continuation.resume(returning: $0) }
        }
    }

    func undoAndWait() async -> Outcome? {
        await withCheckedContinuation { continuation in
            if !undo(completion: { continuation.resume(returning: $0) }) { continuation.resume(returning: nil) }
        }
    }

    func redoAndWait() async -> Outcome? {
        await withCheckedContinuation { continuation in
            if !redo(completion: { continuation.resume(returning: $0) }) { continuation.resume(returning: nil) }
        }
    }
}

import Foundation
import ImageIO
import Testing
@testable import BoltCore

struct MetadataWriterTests {
    @Test func rotationChangesOnlyTheOrientationTag() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg")
        let before = try rawPixels(file)

        try MetadataWriter.setOrientation(Orientation(exif: 1).applying(.rotateRight).exifValue, of: file)

        #expect(try MetadataWriter.orientation(of: file) == 6)
        #expect(try rawPixels(file) == before)
        #expect(ImageDecoder.info(at: file)?.captureDate != nil)
    }

    @MainActor
    @Test func rotationThroughHistoryCanBeUndone() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg", orientation: 6)
        let history = FileHistory()

        let outcome = await history.performAndWait([.transform(file, .rotateLeft)])
        #expect(outcome.changes == [.reoriented(file, from: 6, to: 1)])

        _ = await history.undoAndWait()
        #expect(try MetadataWriter.orientation(of: file) == 6)
    }

    @Test func privateDataIsDroppedWithoutReencoding() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg")
        let clean = folder.url.appendingPathComponent("clean.jpg")

        try MetadataWriter.copyWithoutPrivateData(file, to: clean)

        let source = try #require(CGImageSourceCreateWithURL(clean as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(ImageDecoder.info(at: clean)?.captureDate != nil)
        #expect(try rawPixels(clean) == rawPixels(file))
    }
}

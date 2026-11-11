import CoreGraphics
import Foundation
import Testing
@testable import BoltCore

struct DecoderTests {
    @Test func screenFrameFitsTheTargetAndAppliesOrientation() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("portrait.jpg", width: 400, height: 300, orientation: 6)

        let frame = try #require(ImageDecoder.screen(at: file, fitting: CGSize(width: 150, height: 150)))

        #expect(frame.info.pixelSize == CGSize(width: 300, height: 400))
        #expect(frame.image.width < frame.image.height)
        #expect(frame.longSide == 150)
        #expect(frame.kind == .screen)
    }

    @Test func brokenFilesDecodeToNilInsteadOfCrashing() throws {
        let folder = try TemporaryFolder()
        let empty = try folder.file("empty.jpg", contents: "")
        let garbage = try folder.file("garbage.heic", contents: String(repeating: "not an image ", count: 100))

        for file in [empty, garbage, folder.url.appendingPathComponent("missing.jpg")] {
            #expect(ImageDecoder.screen(at: file, fitting: CGSize(width: 100, height: 100)) == nil)
            #expect(ImageDecoder.preview(at: file) == nil)
            #expect(ImageDecoder.info(at: file) == nil)
        }
    }

    /// Real headers followed by garbage, cut at random lengths: the decoder must return nil, not crash.
    @Test func randomlyDamagedFilesNeverCrashTheDecoder() throws {
        let folder = try TemporaryFolder()
        let valid = try Data(contentsOf: folder.jpeg("seed.jpg", width: 120, height: 90))
        var generator = SplitMix64(seed: 7)
        for index in 0..<200 {
            var bytes = [UInt8](valid.prefix(Int(generator.next() % UInt64(valid.count))))
            for _ in 0..<Int(generator.next() % 40) where !bytes.isEmpty {
                bytes[Int(generator.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: generator.next())
            }
            let file = folder.url.appendingPathComponent("broken-\(index).jpg")
            try Data(bytes).write(to: file)
            _ = ImageDecoder.preview(at: file)
            _ = ImageDecoder.screen(at: file, fitting: CGSize(width: 64, height: 64))
            _ = ImageDecoder.info(at: file)
        }
    }

    @Test func exifDatesHonourTheirOffset() {
        let date = ExifDate.parse("2026:10:12 14:03:00", subseconds: "5", offset: "+03:00")

        #expect(date == Date(timeIntervalSince1970: 1_791_802_980.5))
        #expect(ExifDate.parse("0000:00:00 00:00:00") == nil)
    }
}

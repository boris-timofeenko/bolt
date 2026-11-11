import CoreGraphics
import Foundation
import Testing
@testable import BoltCore

struct ExportTests {
    @Test func exportResizesConvertsAndUprightsThePixels() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg", width: 400, height: 300, orientation: 6)
        let settings = ExportSettings(format: .heic, quality: 0.8, maxLongSide: 200, metadata: .removePrivate)

        let written = try ImageExporter.export(file, to: ImageExporter.destination(for: file, settings: settings,
                                                                                    in: folder.url),
                                               settings: settings)

        let info = try #require(ImageDecoder.info(at: written))
        #expect(written.lastPathComponent == "IMG_1.heic")
        #expect(info.orientation == 1)
        #expect(info.pixelSize == CGSize(width: 150, height: 200))
    }

    @Test func cropTakesTheRequestedPartOfTheUprightImage() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg", width: 400, height: 300)

        let written = try ImageExporter.export(file, to: folder.url.appendingPathComponent("crop.jpg"),
                                               settings: ExportSettings(format: nil),
                                               crop: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))

        #expect(ImageDecoder.info(at: written)?.pixelSize == CGSize(width: 200, height: 300))
    }

    @MainActor
    @Test func replacingTheOriginalKeepsItInTheTrashUntilUndo() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg(uniqueName("IMG_1.jpg"), width: 400, height: 300)
        let history = FileHistory()

        let outcome = await history.performAndWait([.edit(file, .crop(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                                                          replacingOriginal: true)])
        #expect(outcome.failures.isEmpty)
        #expect(ImageDecoder.info(at: file)?.pixelSize == CGSize(width: 200, height: 150))

        folder.cleanUpTrash(after: await history.undoAndWait())
        #expect(ImageDecoder.info(at: file)?.pixelSize == CGSize(width: 400, height: 300))
    }
}

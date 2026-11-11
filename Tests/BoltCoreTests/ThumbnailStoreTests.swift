import Foundation
import Testing
@testable import BoltCore

struct ThumbnailStoreTests {
    @Test func secondLoadComesFromDiskWithoutTheOriginal() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg", width: 800, height: 600)
        let item = try #require(PhotoItem(url: file))
        let cache = folder.url.appendingPathComponent("cache")

        let first = try #require(ThumbnailStore(directory: cache).load(item))
        try FileManager.default.removeItem(at: file)
        let second = try #require(ThumbnailStore(directory: cache).load(item))

        #expect(max(first.width, first.height) == ThumbnailStore.pixelSize)
        #expect(second.width == first.width)
    }

    @Test func aChangedFileGetsANewThumbnail() throws {
        let folder = try TemporaryFolder()
        let file = try folder.jpeg("IMG_1.jpg", width: 800, height: 600)
        let store = ThumbnailStore(directory: folder.url.appendingPathComponent("cache"))
        _ = store.load(try #require(PhotoItem(url: file)))

        try MetadataWriter.setOrientation(6, of: file)
        let changed = try #require(PhotoItem(url: file))
        let rotated = try #require(store.load(changed))

        #expect(rotated.height > rotated.width)
    }
}

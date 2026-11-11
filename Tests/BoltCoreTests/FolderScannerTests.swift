import Foundation
import Testing
@testable import BoltCore

struct FolderScannerTests {
    @Test func listsVisibleImagesWithSizes() throws {
        let folder = try TemporaryFolder()
        try folder.file("IMG_1.HEIC", contents: "12345")
        try folder.file("notes.txt")
        try folder.file(".hidden.jpg")
        try folder.folder("Picks")

        let photos = try FolderScanner.photos(in: folder.url)

        #expect(photos.map(\.name) == ["IMG_1.HEIC"])
        #expect(photos.first?.fileSize == 5)
    }

    @Test func agreesWithFileManagerOnABigFolder() throws {
        let folder = try TemporaryFolder()
        for index in 0..<1500 { try folder.file("photo_\(index).jpg", contents: String(repeating: "x", count: index)) }

        let scanned = try FolderScanner.photos(in: folder.url)
        let listed = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)

        #expect(scanned.count == listed.count)
        #expect(Dictionary(uniqueKeysWithValues: scanned.map { ($0.name, $0.fileSize) })["photo_1234.jpg"] == 1234)
    }

    @Test func liveVideoHidesBehindItsPhotoButOtherVideosAreListed() throws {
        let folder = try TemporaryFolder()
        for name in ["IMG_1.HEIC", "IMG_1.MOV", "clip.mov"] { try folder.file(name) }

        let names = try FolderScanner.photos(in: folder.url).map(\.name).sorted()

        #expect(names == ["IMG_1.HEIC", "clip.mov"])
    }

    @Test func subfoldersComeInNaturalOrder() throws {
        let folder = try TemporaryFolder()
        for name in ["day 10", "day 2", "day 1"] { try folder.folder(name) }

        #expect(FolderScanner.subfolders(of: folder.url).map(\.lastPathComponent) == ["day 1", "day 2", "day 10"])
    }
}

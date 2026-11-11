import Foundation
import Testing
@testable import BoltCore

struct CompanionTests {
    @Test func rawLivePhotoAndEditedCopyBelongToTheOriginal() {
        let names = ["IMG_1234.HEIC", "IMG_1234.MOV", "IMG_1234.DNG", "IMG_E1234.HEIC", "IMG_O1234.AAE",
                     "IMG_12345.HEIC", "IMG_1235.HEIC", "img_1234.xmp"]

        let companions = Companions.of(URL(fileURLWithPath: "/p/IMG_1234.HEIC"), among: names).map(\.lastPathComponent)

        #expect(Set(companions) == ["IMG_1234.MOV", "IMG_1234.DNG", "IMG_E1234.HEIC", "IMG_O1234.AAE", "img_1234.xmp"])
    }

    @Test func anotherPhotoWithTheSameNameIsNotACompanion() {
        let companions = Companions.of(URL(fileURLWithPath: "/p/cover.jpg"), among: ["cover.png", "cover.psd", "cover.NEF"])

        #expect(companions.map(\.lastPathComponent) == ["cover.NEF"])
    }

    @Test func deletingTheEditedCopyKeepsTheOriginal() {
        let companions = Companions.of(URL(fileURLWithPath: "/p/IMG_E1234.HEIC"), among: ["IMG_1234.HEIC", "IMG_E1234.MOV"])

        #expect(companions.map(\.lastPathComponent) == ["IMG_E1234.MOV"])
    }

    @Test func otherNamesOnlyPairByStem() {
        let companions = Companions.of(URL(fileURLWithPath: "/p/DSC_0001.JPG"), among: ["DSC_0001.NEF", "DSC_0002.NEF"])

        #expect(companions.map(\.lastPathComponent) == ["DSC_0001.NEF"])
    }

    @MainActor
    @Test func trashingAPhotoTakesItsRawAlongAndUndoBringsBothBack() async throws {
        let folder = try TemporaryFolder()
        let stem = uniqueName("DSC_0001")
        let jpeg = try folder.file(stem + ".JPG")
        let raw = try folder.file(stem + ".NEF")
        let history = FileHistory()

        let outcome = await history.performAndWait([.trash(jpeg)])
        folder.cleanUpTrash(after: outcome)
        #expect(outcome.changes.count == 2)
        #expect(!exists(raw))

        _ = await history.undoAndWait()
        #expect(exists(raw))
        #expect(exists(jpeg))
    }
}

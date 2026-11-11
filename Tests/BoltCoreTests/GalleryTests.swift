import Foundation
import Testing
@testable import BoltCore

struct GalleryTests {
    let gallery = Gallery(randomSeed: 1)
    let folder = URL(fileURLWithPath: "/photos")

    init() {
        gallery.load(["5.jpg", "1.jpg", "3.jpg", "2.jpg", "4.jpg"].map { photo($0) }, folder: folder, focus: nil)
    }

    private var names: [String] { gallery.items.map(\.name) }

    @Test func loadSortsAndFocusesTheOpenedFile() {
        gallery.load(["4.jpg", "2.jpg", "5.jpg", "3.jpg", "1.jpg"].map { photo($0) }, folder: folder,
                     focus: photo("3.jpg").url)

        #expect(names == ["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg"])
        #expect(gallery.current?.name == "3.jpg")
    }

    @Test func stepStopsAtTheEnds() {
        #expect(!gallery.step(by: -1))
        #expect(gallery.step(by: 10))
        #expect(gallery.current?.name == "5.jpg")
    }

    @Test func removingTheCurrentPhotoShowsTheNextOne() {
        gallery.move(to: 1)
        gallery.remove([photo("2.jpg").url])

        #expect(gallery.current?.name == "3.jpg")
        #expect(gallery.count == 4)
    }

    @Test func removingTheLastPhotoShowsThePreviousOne() {
        gallery.move(to: 4)
        gallery.remove([photo("5.jpg").url])

        #expect(gallery.current?.name == "4.jpg")
    }

    @Test func removingOtherPhotosKeepsTheCurrentOne() {
        gallery.move(to: 3)
        gallery.remove([photo("1.jpg").url, photo("5.jpg").url])

        #expect(gallery.current?.name == "4.jpg")
    }

    @Test func insertGoesToItsSortedPlaceWithoutMovingTheCurrentPhoto() {
        gallery.move(to: 2)
        gallery.remove([photo("2.jpg").url])
        gallery.insert(photo("2.jpg"))

        #expect(names == ["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg"])
        #expect(gallery.current?.name == "3.jpg")
    }

    @Test func renameMovesTheEntryAndKeepsItCurrent() {
        gallery.move(to: 0)
        gallery.replace(photo("1.jpg").url, with: photo("9.jpg"))

        #expect(names == ["2.jpg", "3.jpg", "4.jpg", "5.jpg", "9.jpg"])
        #expect(gallery.current?.name == "9.jpg")
    }

    @Test func shiftSelectionMakesEveryPickedPhotoATarget() {
        gallery.move(to: 1)
        gallery.extendSelection(by: 1)
        gallery.extendSelection(by: 1)

        #expect(gallery.targets.map(\.name) == ["2.jpg", "3.jpg", "4.jpg"])
        #expect(gallery.current?.name == "4.jpg")
    }

    @Test func filterHidesPhotosButKeepsTheCurrentOneWhenItMatches() {
        gallery.move(to: 3)
        gallery.setFilter { $0.name != "2.jpg" && $0.name != "3.jpg" }

        #expect(names == ["1.jpg", "4.jpg", "5.jpg"])
        #expect(gallery.current?.name == "4.jpg")
        #expect(gallery.totalCount == 5)
    }
}

struct GalleryMergeTests {
    let gallery = Gallery(randomSeed: 1)

    init() {
        gallery.load(["1.jpg", "2.jpg", "3.jpg"].map { photo($0) }, folder: URL(fileURLWithPath: "/photos"), focus: nil)
        gallery.move(to: 1)
    }

    @Test func newFilesAppearWithoutMovingTheCurrentPhoto() {
        let result = gallery.merge(["0.jpg", "1.jpg", "2.jpg", "3.jpg"].map { photo($0) })

        #expect(result.added == [photo("0.jpg").url])
        #expect(gallery.current?.name == "2.jpg")
        #expect(gallery.count == 4)
    }

    @Test func aFileDeletedOutsideMakesTheNextOneCurrent() {
        let result = gallery.merge(["1.jpg", "3.jpg"].map { photo($0) })

        #expect(result.removed == [photo("2.jpg").url])
        #expect(gallery.current?.name == "3.jpg")
    }

    @Test func deletionAndArrivalTogetherStillShowTheNextPhoto() {
        gallery.merge(["0.jpg", "1.jpg", "3.jpg"].map { photo($0) })

        #expect(gallery.current?.name == "3.jpg")
    }

    @Test func aRewrittenFileIsReportedAsChanged() {
        let result = gallery.merge([photo("1.jpg"), photo("2.jpg", size: 99), photo("3.jpg")])

        #expect(result.changed == [photo("2.jpg").url])
        #expect(result.added.isEmpty && result.removed.isEmpty)
    }

    @Test func anIdenticalListingChangesNothing() {
        let revision = gallery.revision

        #expect(gallery.merge(gallery.items).isEmpty)
        #expect(gallery.revision == revision)
    }
}

struct GallerySelectionTests {
    let gallery = Gallery(randomSeed: 1)

    init() {
        gallery.load(["1.jpg", "2.jpg", "3.jpg"].map { photo($0) }, folder: URL(fileURLWithPath: "/photos"), focus: nil)
    }

    @Test func aSelectionTheFilterShrinksToOnePhotoIsDropped() {
        gallery.extendSelection(by: 1)
        gallery.setFilter { $0.name != "1.jpg" }

        #expect(gallery.selection.isEmpty)
        #expect(gallery.targets.map(\.name) == ["2.jpg"])
    }
}

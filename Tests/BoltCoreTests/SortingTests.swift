import Foundation
import Testing
@testable import BoltCore

struct NaturalOrderTests {
    @Test func numbersCompareByValue() {
        #expect(NaturalOrder.sorted(["IMG_10.HEIC", "IMG_9.HEIC", "IMG_100.HEIC", "IMG_1.HEIC"])
            == ["IMG_1.HEIC", "IMG_9.HEIC", "IMG_10.HEIC", "IMG_100.HEIC"])
    }

    @Test func letterCaseDoesNotSplitGroups() {
        #expect(NaturalOrder.sorted(["b.jpg", "A.jpg", "a2.jpg", "B1.jpg"]) == ["A.jpg", "a2.jpg", "b.jpg", "B1.jpg"])
    }

    @Test func leadingZerosOnlyBreakTies() {
        #expect(NaturalOrder.sorted(["img_010", "img_9", "img_09"]) == ["img_9", "img_09", "img_010"])
    }

    @Test func digitsLongerThanUInt64StillSort() {
        #expect(NaturalOrder.sorted(["x99999999999999999999999", "x100000000000000000000000"])
            == ["x99999999999999999999999", "x100000000000000000000000"])
    }
}

struct PhotoComparatorTests {
    @Test func sortsByCaptureDateFallingBackToModificationDate() {
        let early = photo("b.jpg", modified: 300)
        let late = photo("a.jpg", modified: 100)
        let undated = photo("c.jpg", modified: 200)
        let dates = [early.url: Date(timeIntervalSince1970: 10), late.url: Date(timeIntervalSince1970: 500)]
        let comparator = PhotoComparator(order: Sorting(key: .dateTaken), captureDates: dates)

        #expect(comparator.sorted([late, undated, early]).map(\.name) == ["b.jpg", "c.jpg", "a.jpg"])
    }

    @Test func descendingSizeKeepsNameOrderForTies() {
        let items = [photo("2.jpg", size: 5), photo("10.jpg", size: 5), photo("1.jpg", size: 9)]
        let comparator = PhotoComparator(order: Sorting(key: .size, ascending: false))

        #expect(comparator.sorted(items).map(\.name) == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test func randomOrderIsStableForTheSameSeed() {
        let items = (1...20).map { photo("\($0).jpg") }
        let comparator = PhotoComparator(order: Sorting(key: .random), seed: 42)

        #expect(comparator.sorted(items) == comparator.sorted(items.reversed()))
        #expect(comparator.sorted(items) != items)
    }
}

struct RenameTemplateTests {
    private func input(_ name: String, _ date: String = "2026-10-12T14:03:05Z") -> RenameTemplate.Input {
        RenameTemplate.Input(url: URL(fileURLWithPath: "/Trip/\(name)"), date: ISO8601DateFormatter().date(from: date)!)
    }

    @Test func dateAndCounterTokensKeepTheExtension() {
        let dated = RenameTemplate("{date:yyyy-MM-dd}_{counter:3}")
        #expect(dated.names(for: [input("IMG_1.HEIC"), input("IMG_2.jpg")]) == ["2026-10-12_001.HEIC", "2026-10-12_002.jpg"])
        #expect(RenameTemplate("{folder} {name}").names(for: [input("IMG_1.HEIC")]) == ["Trip IMG_1.HEIC"])
    }

    @Test func clashingNamesGetNumbered() {
        let names = RenameTemplate("{date:yyyy-MM-dd}").names(for: [input("a.jpg"), input("b.jpg"), input("c.jpg")])
        #expect(names == ["2026-10-12.jpg", "2026-10-12 (2).jpg", "2026-10-12 (3).jpg"])
    }

    @Test func slashesAndUnknownTokensAreHarmless() {
        #expect(RenameTemplate("a/b {nope}").names(for: [input("x.jpg")]) == ["a-b {nope}.jpg"])
        #expect(RenameTemplate("").names(for: [input("x.jpg")]) == ["x.jpg"])
    }
}

struct DateFoldersTests {
    @Test func photosGoIntoYearAndMonthFolders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = ISO8601DateFormatter().date(from: "2026-03-05T10:00:00Z")!

        let folder = DateFolders.folder(for: date, in: URL(fileURLWithPath: "/Photos"), calendar: calendar)

        #expect(folder.path == "/Photos/2026/2026-03")
    }
}

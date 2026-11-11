import Foundation
import Testing
@testable import BoltCore

struct LabelTests {
    @Test func labelsRoundTripThroughFinderTagsWithoutTouchingOtherTags() throws {
        let folder = try TemporaryFolder()
        let file = try folder.file("IMG_1.jpg")
        try (file as NSURL).setResourceValue(["Trip"], forKey: .tagNamesKey)

        try LabelStorage.write(PhotoLabels(flag: .pick, rating: 3, color: 6), to: file)
        try LabelStorage.write(LabelChange.rating(4).applied(to: LabelStorage.read(file)), to: file)

        #expect(LabelStorage.read(file) == PhotoLabels(flag: .pick, rating: 4, color: 6))
        #expect(Set(try file.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []) == ["Trip", "Pick", "★★★★"])
    }

    @MainActor
    @Test func labelChangesCanBeUndone() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.file("IMG_1.jpg")
        let history = FileHistory()

        _ = await history.performAndWait([.label(file, .flag(.reject))])
        #expect(LabelStorage.read(file).flag == .reject)

        _ = await history.undoAndWait()
        #expect(LabelStorage.read(file).isEmpty)
    }

    @Test func filterKeepsOnlyMatchingLabels() {
        #expect(LabelFilter.rated(atLeast: 3).matches(PhotoLabels(rating: 4)))
        #expect(!LabelFilter.rejects.matches(PhotoLabels(flag: .pick)))
    }
}

import Testing
@testable import BoltCore

struct FuzzyMatchTests {
    @Test func matchesSubsequenceIgnoringCase() {
        #expect(FuzzyMatch.score("bst", in: "Best shots") != nil)
        #expect(FuzzyMatch.score("xyz", in: "Best shots") == nil)
    }

    @Test func prefersWordStartsAndConsecutiveLetters() throws {
        let prefix = try #require(FuzzyMatch.score("tri", in: "Trip 2026"))
        let scattered = try #require(FuzzyMatch.score("tri", in: "Things to review"))

        #expect(prefix > scattered)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }
}

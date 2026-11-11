import Foundation

/// Subsequence matching for the folder picker and the command palette.
/// "tri" finds "Trip 2026" and, ranked lower, "Things to review".
public enum FuzzyMatch {
    /// Nil when the query's letters don't all appear in order. Higher is a better match.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())

        var score = 0
        var matched = 0
        var previous = -2
        for (index, character) in haystack.enumerated() where matched < needle.count {
            guard character == needle[matched] else { continue }
            var points = 1
            if index == previous + 1 { points += 5 }
            if index == 0 { points += 4 }
            if index == 0 || !(haystack[index - 1].isLetter || haystack[index - 1].isNumber) { points += 8 }
            score += points
            previous = index
            matched += 1
        }
        guard matched == needle.count else { return nil }
        return score - haystack.count / 10
    }
}

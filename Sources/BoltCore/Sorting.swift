import Foundation

/// Finder-style ordering: digit runs compare as numbers, so IMG_9 comes before IMG_10.
/// Like Finder, punctuation sorts before digits and digits before letters, so "a.jpg" < "a2.jpg" < "ab.jpg".
public enum NaturalOrder {
    public struct Key: Comparable, Sendable {
        fileprivate let atoms: [Atom]
        fileprivate let original: String

        public static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.atoms != rhs.atoms { return lhs.atoms.lexicographicallyPrecedes(rhs.atoms) }
            return lhs.original < rhs.original
        }

        public static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.original == rhs.original
        }
    }

    fileprivate enum Atom: Comparable, Sendable {
        case symbol(String)
        case number(digits: String, leadingZeros: Int)
        case letter(String)

        private var rank: Int {
            switch self {
            case .symbol: 0
            case .number: 1
            case .letter: 2
            }
        }

        static func < (lhs: Atom, rhs: Atom) -> Bool {
            switch (lhs, rhs) {
            case let (.number(a, za), .number(b, zb)):
                if a.count != b.count { return a.count < b.count }
                if a != b { return a < b }
                return za < zb
            case let (.symbol(a), .symbol(b)), let (.letter(a), .letter(b)):
                return a < b
            default:
                return lhs.rank < rhs.rank
            }
        }
    }

    public static func key(for name: String) -> Key {
        var atoms: [Atom] = []
        var digits = ""

        func flushDigits() {
            guard !digits.isEmpty else { return }
            let significant = digits.drop { $0 == "0" }
            atoms.append(.number(digits: significant.isEmpty ? "0" : String(significant),
                                 leadingZeros: digits.count - max(significant.count, 1)))
            digits = ""
        }

        for character in name {
            if character.isASCII && character.isNumber {
                digits.append(character)
                continue
            }
            flushDigits()
            let lowered = character.lowercased()
            atoms.append(character.isLetter || character.isNumber ? .letter(lowered) : .symbol(lowered))
        }
        flushDigits()
        return Key(atoms: atoms, original: name)
    }

    public static func sorted(_ names: [String]) -> [String] {
        names.map { (key(for: $0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

public enum SortKey: String, CaseIterable, Sendable {
    case name, dateTaken, dateModified, size, random
}

public struct Sorting: Equatable, Sendable {
    public var key: SortKey
    public var ascending: Bool

    public init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

/// Orders photos; ties always fall back to natural name order so the result is stable.
public struct PhotoComparator: Sendable {
    public let order: Sorting
    public let captureDates: [URL: Date]
    public let seed: UInt64

    public init(order: Sorting, captureDates: [URL: Date] = [:], seed: UInt64 = 0) {
        self.order = order
        self.captureDates = captureDates
        self.seed = seed
    }

    public func sorted(_ items: [PhotoItem]) -> [PhotoItem] {
        if order.key == .random {
            var generator = SplitMix64(seed: seed)
            return items.sorted { NaturalOrder.key(for: $0.name) < NaturalOrder.key(for: $1.name) }
                .shuffled(using: &generator)
        }
        let keyed = items.map { (item: $0, name: NaturalOrder.key(for: $0.name)) }
        return keyed.sorted { inIncreasingOrder($0.item, $0.name, $1.item, $1.name) }.map(\.item)
    }

    public func inIncreasingOrder(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        inIncreasingOrder(a, NaturalOrder.key(for: a.name), b, NaturalOrder.key(for: b.name))
    }

    private func inIncreasingOrder(_ a: PhotoItem, _ aName: NaturalOrder.Key,
                                   _ b: PhotoItem, _ bName: NaturalOrder.Key) -> Bool {
        let result: ComparisonResult = switch order.key {
        case .name, .random: compare(aName, bName)
        case .dateTaken: compare(captureDate(a), captureDate(b))
        case .dateModified: compare(a.modified, b.modified)
        case .size: compare(a.fileSize, b.fileSize)
        }
        switch result {
        case .orderedAscending: return order.ascending
        case .orderedDescending: return !order.ascending
        case .orderedSame: return aName < bName
        }
    }

    private func captureDate(_ item: PhotoItem) -> Date {
        captureDates[item.url] ?? item.modified
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
    }
}

/// Deterministic generator, so "random" order stays put while a folder is open.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

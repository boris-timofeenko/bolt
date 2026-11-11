import Foundation

/// Flag, star rating and color label of a photo, kept in Finder tags so they never touch the image
/// file, show up in Finder and travel with the file when it moves.
public struct PhotoLabels: Equatable, Sendable {
    public enum Flag: Sendable {
        case none, pick, reject
    }

    public var flag: Flag = .none
    /// 0...5.
    public var rating = 0
    /// Finder label number: 0 none, then gray, green, purple, blue, yellow, red, orange.
    public var color = 0

    public init(flag: Flag = .none, rating: Int = 0, color: Int = 0) {
        self.flag = flag
        self.rating = rating
        self.color = color
    }

    public var isEmpty: Bool { self == PhotoLabels() }

    // Tag names are fixed English words and star strings, so they mean the same in every language.
    static let pickTag = "Pick"
    static let rejectTag = "Reject"
    static func ratingTag(_ stars: Int) -> String { String(repeating: "★", count: stars) }

    static func isOwnTag(_ tag: String) -> Bool {
        tag == pickTag || tag == rejectTag || (!tag.isEmpty && tag.allSatisfy { $0 == "★" } && tag.count <= 5)
    }
}

public enum LabelChange: Sendable {
    case flag(PhotoLabels.Flag)
    case rating(Int)
    case color(Int)

    public func applied(to labels: PhotoLabels) -> PhotoLabels {
        var result = labels
        switch self {
        case .flag(let flag): result.flag = flag
        case .rating(let stars): result.rating = min(max(stars, 0), 5)
        case .color(let color): result.color = min(max(color, 0), 7)
        }
        return result
    }
}

public enum LabelStorage {
    public static func read(_ url: URL) -> PhotoLabels {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey]) else { return PhotoLabels() }
        let tags = values.tagNames ?? []
        var labels = PhotoLabels()
        if tags.contains(PhotoLabels.rejectTag) {
            labels.flag = .reject
        } else if tags.contains(PhotoLabels.pickTag) {
            labels.flag = .pick
        }
        labels.rating = tags.filter { PhotoLabels.isOwnTag($0) && $0.first == "★" }.map(\.count).max() ?? 0
        labels.color = values.labelNumber ?? 0
        return labels
    }

    /// Replaces Bolt's own tags and the color label; any other tags the user set stay as they are.
    public static func write(_ labels: PhotoLabels, to url: URL) throws {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let current = (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        var tags = current.filter { !PhotoLabels.isOwnTag($0) }
        switch labels.flag {
        case .pick: tags.append(PhotoLabels.pickTag)
        case .reject: tags.append(PhotoLabels.rejectTag)
        case .none: break
        }
        if labels.rating > 0 { tags.append(PhotoLabels.ratingTag(labels.rating)) }

        // Tags have no public setter on URLResourceValues; NSURL's does the same thing.
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        // The color label is itself a tag ("Red"), so it goes second or the line above would erase it.
        var values = URLResourceValues()
        values.labelNumber = labels.color
        try fresh.setResourceValues(values)
    }
}

/// Which photos the list shows.
public enum LabelFilter: Hashable, Sendable {
    case all, picks, rejects, unflagged
    case rated(atLeast: Int)

    public func matches(_ labels: PhotoLabels) -> Bool {
        switch self {
        case .all: true
        case .picks: labels.flag == .pick
        case .rejects: labels.flag == .reject
        case .unflagged: labels.flag == .none
        case .rated(let stars): labels.rating >= stars
        }
    }
}

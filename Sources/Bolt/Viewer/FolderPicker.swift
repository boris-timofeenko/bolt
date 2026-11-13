import AppKit
import BoltCore

/// Rows for the "which folder?" picker: recent destinations, bucket folders, folders next to the photo
/// and a few standard places, plus "Create …" when the typed name doesn't exist yet.
@MainActor
enum FolderPicker {
    static func candidates(near folder: URL?) -> [URL] {
        var result: [URL] = []
        // The photo's own folder is never a destination.
        func add(_ url: URL) {
            guard !(folder.map(url.isSameLocation(as:)) ?? false),
                  !result.contains(where: url.isSameLocation(as:)) else { return }
            result.append(url)
        }

        Preferences.recentFolders.filter(isFolder).forEach(add)
        (1...9).compactMap(Preferences.bucket).forEach(add)
        if let folder {
            FolderScanner.subfolders(of: folder).forEach(add)
            FolderScanner.subfolders(of: folder.deletingLastPathComponent()).forEach(add)
        }
        let places: [FileManager.SearchPathDirectory] = [.picturesDirectory, .desktopDirectory, .downloadsDirectory]
        places.compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }.forEach(add)
        return result
    }

    static func items(query: String, candidates: [URL], base: URL?,
                      choose: @escaping (URL) -> Void, browse: @escaping () -> Void) -> [PickerItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        // Names only, unless the query looks like a path: scattered letters across a long path match anything.
        let searchesPaths = text.contains("/")
        let ranked: [URL] = text.isEmpty ? candidates : candidates
            .compactMap { url -> (score: Int, url: URL)? in
                let haystack = searchesPaths ? Format.path(url) : url.lastPathComponent
                return FuzzyMatch.score(text, in: haystack).map { ($0, url) }
            }
            .enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.url)

        var items = ranked.prefix(40).map { url in
            PickerItem(title: url.lastPathComponent, subtitle: Format.path(url.deletingLastPathComponent()),
                       accessory: bucketNumber(of: url).map(String.init), action: { choose(url) })
        }

        let lowered = text.lowercased()
        if !text.isEmpty, let target = newFolderURL(for: text, base: base),
           !ranked.contains(where: { $0.lastPathComponent.lowercased() == target.lastPathComponent.lowercased() }),
           !isFolder(target) {
            let create = PickerItem(title: L("Create “%@”", target.lastPathComponent),
                                    subtitle: Format.path(target.deletingLastPathComponent()),
                                    accessory: nil, action: { choose(target) })
            // Return should do what was typed unless an existing folder clearly starts with it.
            let closeMatch = ranked.first?.lastPathComponent.lowercased().hasPrefix(lowered) ?? false
            items.insert(create, at: closeMatch ? 1 : 0)
        }
        items.append(PickerItem(title: L("Other Folder…"), subtitle: nil, accessory: nil, action: browse))
        return items
    }

    /// "Picks" goes next to the photo; "~/Pictures/Picks" or "/Volumes/Card/Picks" go where they say.
    static func newFolderURL(for text: String, base: URL?) -> URL? {
        if text.hasPrefix("~") {
            return FolderAccess.home.appendingPathComponent(String(text.dropFirst()), isDirectory: true)
        }
        if text.hasPrefix("/") {
            return URL(fileURLWithPath: text, isDirectory: true)
        }
        return base?.appendingPathComponent(text, isDirectory: true)
    }

    private static func bucketNumber(of url: URL) -> Int? {
        (1...9).first { Preferences.bucket($0)?.isSameLocation(as: url) ?? false }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

import AppKit
import BoltCore

enum CanvasBackground: String, CaseIterable {
    case system, gray, black

    var color: NSColor {
        switch self {
        case .system: .windowBackgroundColor
        case .gray: NSColor(white: 0.2, alpha: 1)
        case .black: .black
        }
    }

    var title: String {
        switch self {
        case .system: L("Same as Window")
        case .gray: L("Gray")
        case .black: L("Black")
        }
    }
}

/// What happens after copying a photo or giving it a flag or rating.
/// Moving and trashing always show the next photo: the current one is gone.
enum AfterAction: String, CaseIterable {
    case next, stay
}

enum WheelAction: String, CaseIterable {
    case navigate, zoom
}

enum EditSaveMode: String, CaseIterable {
    case copy, replace
}

/// Settings stored in UserDefaults. The SwiftUI settings window binds to the same keys with @AppStorage.
enum Preferences {
    enum Key {
        static let background = "background"
        static let afterAction = "afterAction"
        static let wheelAction = "wheelAction"
        static let editSaveMode = "editSaveMode"
        static let cacheMegabytes = "cacheMegabytes"
        static let keyProfile = "keyProfile"
        static let externalEditor = "externalEditor"
        static let buckets = "buckets"
        static let recentFolders = "recentFolders"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let showStrip = "showStrip"
        static let showInfo = "showInfo"
        static let keyOverrides = "keyOverrides"
        static let slideshowSeconds = "slideshowSeconds"
        static let shownTips = "shownTips"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.background: CanvasBackground.system.rawValue,
            Key.afterAction: AfterAction.next.rawValue,
            Key.wheelAction: WheelAction.navigate.rawValue,
            Key.editSaveMode: EditSaveMode.copy.rawValue,
            Key.cacheMegabytes: 1024,
            Key.keyProfile: KeyProfile.bolt.rawValue,
            Key.sortKey: SortKey.name.rawValue,
            Key.sortAscending: true,
            Key.showStrip: false,
            Key.showInfo: false,
            Key.slideshowSeconds: 3,
        ])
    }

    static var background: CanvasBackground {
        get { CanvasBackground(rawValue: defaults.string(forKey: Key.background) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.background) }
    }

    static var afterAction: AfterAction {
        AfterAction(rawValue: defaults.string(forKey: Key.afterAction) ?? "") ?? .next
    }

    static var wheelAction: WheelAction {
        WheelAction(rawValue: defaults.string(forKey: Key.wheelAction) ?? "") ?? .navigate
    }

    static var editSaveMode: EditSaveMode {
        EditSaveMode(rawValue: defaults.string(forKey: Key.editSaveMode) ?? "") ?? .copy
    }

    static var cacheBytes: Int {
        max(defaults.integer(forKey: Key.cacheMegabytes), 256) * 1024 * 1024
    }

    static var keyProfile: KeyProfile {
        get { KeyProfile(rawValue: defaults.string(forKey: Key.keyProfile) ?? "") ?? .bolt }
        set { defaults.set(newValue.rawValue, forKey: Key.keyProfile) }
    }

    /// The app "O" opens photos in. Preview unless the user picked something else.
    static var externalEditor: URL? {
        get {
            if let path = defaults.string(forKey: Key.externalEditor) { return URL(fileURLWithPath: path) }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        }
        set { defaults.set(newValue?.path, forKey: Key.externalEditor) }
    }

    static var sortOrder: Sorting {
        get {
            Sorting(key: SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .name,
                      ascending: defaults.bool(forKey: Key.sortAscending))
        }
        set {
            defaults.set(newValue.key.rawValue, forKey: Key.sortKey)
            defaults.set(newValue.ascending, forKey: Key.sortAscending)
        }
    }

    static var showStrip: Bool {
        get { defaults.bool(forKey: Key.showStrip) }
        set { defaults.set(newValue, forKey: Key.showStrip) }
    }

    static var showInfo: Bool {
        get { defaults.bool(forKey: Key.showInfo) }
        set { defaults.set(newValue, forKey: Key.showInfo) }
    }

    /// Shortcuts the user changed, by command id. An empty list means the command has no key.
    static var keyOverrides: [String: [String]] {
        get { defaults.dictionary(forKey: Key.keyOverrides) as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: Key.keyOverrides) }
    }

    static var slideshowSeconds: Int {
        max(defaults.integer(forKey: Key.slideshowSeconds), 1)
    }

    // MARK: - Buckets

    /// True the first time it's asked about a tip, false ever after: each tip shows once.
    static func takeTip(_ name: String) -> Bool {
        var shown = defaults.stringArray(forKey: Key.shownTips) ?? []
        guard !shown.contains(name) else { return false }
        shown.append(name)
        defaults.set(shown, forKey: Key.shownTips)
        return true
    }

    /// Folders assigned to keys 1–9.
    static func bucket(_ number: Int) -> URL? {
        guard let path = (defaults.dictionary(forKey: Key.buckets) as? [String: String])?[String(number)] else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setBucket(_ number: Int, to folder: URL?) {
        var buckets = defaults.dictionary(forKey: Key.buckets) as? [String: String] ?? [:]
        buckets[String(number)] = folder?.path
        defaults.set(buckets, forKey: Key.buckets)
    }

    // MARK: - Recent destinations

    static var recentFolders: [URL] {
        (defaults.stringArray(forKey: Key.recentFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func noteRecentFolder(_ folder: URL) {
        var paths = defaults.stringArray(forKey: Key.recentFolders) ?? []
        paths.removeAll { $0 == folder.path }
        paths.insert(folder.path, at: 0)
        defaults.set(Array(paths.prefix(20)), forKey: Key.recentFolders)
    }
}

import Foundation

/// The ordered list of photos in one folder, the current position and the Shift-selection.
/// Not thread-safe: owned by a window and used on the main thread.
public final class Gallery {
    public private(set) var folder: URL?
    /// What the user pages through: everything in the folder, sorted, minus what the filter hides.
    public private(set) var items: [PhotoItem] = []
    public private(set) var currentIndex = 0
    /// Photos picked with Shift+arrows. The current photo is always a target too, see `targets`.
    public private(set) var selection: Set<URL> = []

    /// Changes whenever the list itself changes (not when only the current photo moves),
    /// so views showing the whole list know when to reload.
    public private(set) var revision = 0
    public private(set) var order = Sorting()
    public private(set) var captureDates: [URL: Date] = [:]
    public let randomSeed: UInt64

    private var allItems: [PhotoItem] = []
    private var filter: ((PhotoItem) -> Bool)?
    private var indexByURL: [URL: Int] = [:]

    public init(randomSeed: UInt64 = .random(in: 0...UInt64.max)) {
        self.randomSeed = randomSeed
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    /// Size of the folder before filtering.
    public var totalCount: Int { allItems.count }
    public var isFiltered: Bool { filter != nil }

    public var current: PhotoItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    public func index(of url: URL) -> Int? {
        indexByURL[url]
    }

    public func contains(_ url: URL) -> Bool {
        allItems.contains { $0.url == url }
    }

    /// Photos an action applies to, in list order: the selection plus the current photo.
    public var targets: [PhotoItem] {
        guard let current else { return [] }
        if selection.isEmpty { return [current] }
        return items.filter { selection.contains($0.url) || $0.url == current.url }
    }

    // MARK: - Loading and ordering

    /// Replaces the list. `focus` stays current if it is in the new list.
    public func load(_ newItems: [PhotoItem], folder: URL, focus: URL?) {
        self.folder = folder
        allItems = comparator.sorted(newItems)
        selection.removeAll()
        rebuild(keeping: focus)
    }

    public func sort(by newOrder: Sorting) {
        order = newOrder
        allItems = comparator.sorted(allItems)
        rebuild(keeping: current?.url)
    }

    /// Capture dates arrive in the background; re-sorts only if they affect the order.
    public func updateCaptureDates(_ dates: [URL: Date]) {
        captureDates.merge(dates) { _, new in new }
        if order.key == .dateTaken { sort(by: order) }
    }

    public func setFilter(_ predicate: ((PhotoItem) -> Bool)?) {
        filter = predicate
        rebuild(keeping: current?.url)
    }

    /// Re-applies the filter after labels changed, keeping the current photo when it still matches.
    public func refilter() {
        rebuild(keeping: current?.url)
    }

    private var comparator: PhotoComparator {
        PhotoComparator(order: order, captureDates: captureDates, seed: randomSeed)
    }

    private func rebuild(keeping url: URL?) {
        revision += 1
        let previousIndex = currentIndex
        items = filter.map { allItems.filter($0) } ?? allItems
        indexByURL = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.url, $0) })
        if let url, let index = indexByURL[url] {
            currentIndex = index
        } else {
            currentIndex = min(previousIndex, max(items.count - 1, 0))
        }
        // A selection is two or more photos including the current one. Anything less isn't shown
        // anywhere, and actions on hidden targets are how photos get trashed by surprise.
        selection = selection.filter { indexByURL[$0] != nil }
        if selection.count < 2 || !(current.map { selection.contains($0.url) } ?? false) {
            selection.removeAll()
        }
    }

    // MARK: - Navigation

    @discardableResult
    public func move(to index: Int) -> Bool {
        guard !items.isEmpty else { return false }
        let clamped = min(max(index, 0), items.count - 1)
        guard clamped != currentIndex else { return false }
        currentIndex = clamped
        return true
    }

    @discardableResult
    public func move(to url: URL) -> Bool {
        guard let index = indexByURL[url] else { return false }
        return move(to: index)
    }

    @discardableResult
    public func step(by delta: Int) -> Bool {
        move(to: currentIndex + delta)
    }

    // MARK: - Selection

    /// Shift+arrow: selects the current photo, moves, selects the new one.
    public func extendSelection(by delta: Int) {
        guard let current else { return }
        selection.insert(current.url)
        if step(by: delta), let next = self.current {
            selection.insert(next.url)
        }
    }

    /// Shift- or Cmd-click in the grid: keeps what's selected, adds the clicked photo and makes it current.
    public func extendSelection(to index: Int) {
        guard let current else { return }
        selection.insert(current.url)
        move(to: index)
        if let clicked = self.current { selection.insert(clicked.url) }
    }

    public func clearSelection() {
        selection.removeAll()
    }

    public func selectAll() {
        selection = Set(items.map(\.url))
    }

    // MARK: - Changes from file operations

    public struct MergeResult: Equatable {
        public var added: [URL] = []
        public var removed: [URL] = []
        /// Same name, different size or date: the decoded pixels are stale.
        public var changed: [URL] = []

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    }

    /// Brings the list in line with a fresh listing of the folder, keeping the current photo and the
    /// selection. Used when files appear or vanish behind the app's back.
    @discardableResult
    public func merge(_ listing: [PhotoItem]) -> MergeResult {
        let known = Dictionary(uniqueKeysWithValues: allItems.map { ($0.url, $0) })
        let fresh = Set(listing.map(\.url))
        var result = MergeResult()
        result.removed = allItems.map(\.url).filter { !fresh.contains($0) }
        for item in listing {
            if let old = known[item.url] {
                if old.modified != item.modified || old.fileSize != item.fileSize { result.changed.append(item.url) }
            } else {
                result.added.append(item.url)
            }
        }
        guard !result.isEmpty else { return result }

        // The current photo if it survived, else the next one that did, else the one before.
        let position = min(currentIndex, items.count)
        let keep = items[position...].first { fresh.contains($0.url) }?.url
            ?? items[..<position].last { fresh.contains($0.url) }?.url
        allItems = comparator.sorted(listing)
        selection = selection.filter { fresh.contains($0) }
        rebuild(keeping: keep)
        return result
    }

    /// Removes photos. If the current one goes away, the next surviving photo becomes current.
    public func remove(_ urls: Set<URL>) {
        guard allItems.contains(where: { urls.contains($0.url) }) else { return }
        let survivorsBefore = items[..<min(currentIndex, items.count)].filter { !urls.contains($0.url) }.count
        let keep = current.flatMap { urls.contains($0.url) ? nil : $0.url }
        allItems.removeAll { urls.contains($0.url) }
        selection.subtract(urls)
        currentIndex = survivorsBefore
        rebuild(keeping: keep)
    }

    /// Inserts a photo at its sorted position. Does nothing if it is already listed.
    public func insert(_ item: PhotoItem) {
        guard !allItems.contains(where: { $0.url == item.url }) else { return }
        let keep = current?.url
        if order.key == .random {
            allItems.insert(item, at: min(currentIndex, allItems.count))
        } else {
            let comparator = comparator
            let position = allItems.partitioningIndex { !comparator.inIncreasingOrder($0, item) }
            allItems.insert(item, at: position)
        }
        rebuild(keeping: keep)
    }

    /// Puts the new version of an entry where it now sorts, e.g. after a rename or when size and date changed.
    /// The current photo and the selection follow it.
    public func replace(_ url: URL, with item: PhotoItem) {
        guard let index = allItems.firstIndex(where: { $0.url == url }) else { return }
        let wasCurrent = current?.url == url
        let keep = wasCurrent ? item.url : current?.url
        if selection.remove(url) != nil { selection.insert(item.url) }
        allItems.remove(at: index)
        if order.key == .random {
            allItems.insert(item, at: index)
        } else {
            let comparator = comparator
            allItems.insert(item, at: allItems.partitioningIndex { !comparator.inIncreasingOrder($0, item) })
        }
        rebuild(keeping: keep)
    }
}

extension Array {
    /// First index where `predicate` becomes true, assuming it is false-then-true across the array.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

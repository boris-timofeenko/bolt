import Foundation

/// Runs `transform` over `items` on all cores and returns the results in order.
/// For short, independent, blocking jobs like reading EXIF from a few thousand files.
public func concurrentMap<Item: Sendable, Result: Sendable>(
    _ items: [Item], _ transform: @Sendable (Item) -> Result
) -> [Result] {
    let results = LockedArray<Result?>(repeating: nil, count: items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { index in
        results[index] = transform(items[index])
    }
    return results.values.map { $0! }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element]

    init(repeating value: Element, count: Int) {
        storage = Array(repeating: value, count: count)
    }

    subscript(index: Int) -> Element {
        get { lock.withLock { storage[index] } }
        set { lock.withLock { storage[index] = newValue } }
    }

    var values: [Element] { lock.withLock { storage } }
}

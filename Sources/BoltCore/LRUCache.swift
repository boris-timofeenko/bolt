import Foundation

/// A thread-safe cache with a byte budget that evicts the least recently used entries first.
/// Sized for dozens of decoded frames, so eviction is a linear scan rather than a linked list.
public final class LRUCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var budget: Int
    private var total = 0

    public init(budget: Int) {
        self.budget = budget
    }

    public var totalCost: Int {
        lock.withLock { total }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    /// Returns the value and marks it as recently used.
    public func value(for key: Key) -> Value? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.value
        }
    }

    /// Returns the value without touching its position.
    public func peek(_ key: Key) -> Value? {
        lock.withLock { entries[key]?.value }
    }

    public func contains(_ key: Key) -> Bool {
        lock.withLock { entries[key] != nil }
    }

    public func insert(_ value: Value, for key: Key, cost: Int) {
        lock.withLock {
            clock += 1
            total -= entries[key]?.cost ?? 0
            entries[key] = Entry(value: value, cost: cost, lastUse: clock)
            total += cost
            evict(downTo: budget, sparing: key)
        }
    }

    public func removeValue(for key: Key) {
        lock.withLock {
            total -= entries.removeValue(forKey: key)?.cost ?? 0
        }
    }

    public func removeAll(where shouldRemove: (Key) -> Bool) {
        lock.withLock {
            for key in entries.keys where shouldRemove(key) {
                total -= entries.removeValue(forKey: key)?.cost ?? 0
            }
        }
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            total = 0
        }
    }

    public func setBudget(_ newBudget: Int) {
        lock.withLock {
            budget = newBudget
            evict(downTo: budget, sparing: nil)
        }
    }

    /// Drops everything except `keep`, used under memory pressure.
    public func trim(keeping keep: Set<Key>) {
        removeAll { !keep.contains($0) }
    }

    private func evict(downTo limit: Int, sparing spared: Key?) {
        while total > limit {
            guard let victim = entries.filter({ $0.key != spared }).min(by: { $0.value.lastUse < $1.value.lastUse })
            else { return }
            total -= victim.value.cost
            entries.removeValue(forKey: victim.key)
        }
    }
}

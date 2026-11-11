import Testing
@testable import BoltCore

struct LRUCacheTests {
    @Test func evictsLeastRecentlyUsedWhenOverBudget() {
        let cache = LRUCache<String, Int>(budget: 30)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "b", cost: 10)
        cache.insert(3, for: "c", cost: 10)
        _ = cache.value(for: "a")

        cache.insert(4, for: "d", cost: 10)

        #expect(cache.peek("b") == nil)
        #expect(cache.peek("a") == 1)
        #expect(cache.totalCost == 30)
    }

    @Test func keepsAnEntryLargerThanTheWholeBudget() {
        let cache = LRUCache<String, Int>(budget: 10)
        cache.insert(1, for: "small", cost: 5)

        cache.insert(2, for: "huge", cost: 50)

        #expect(cache.peek("huge") == 2)
        #expect(cache.count == 1)
    }

    @Test func trimKeepsOnlyTheGivenKeys() {
        let cache = LRUCache<String, Int>(budget: 100)
        for key in ["a", "b", "c"] { cache.insert(0, for: key, cost: 1) }

        cache.trim(keeping: ["b"])

        #expect(cache.count == 1)
        #expect(cache.contains("b"))
    }
}

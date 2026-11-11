import AppKit
import BoltCore

/// Fetches thumbnails in the background for the grid and the strip. Newer requests run first,
/// so scrolling fast fills what's on screen now rather than what scrolled past.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    let store: ThumbnailStore
    private let queue = OperationQueue()
    private var waiting: [PhotoItem: [(CGImage?) -> Void]] = [:]
    private var operations: [PhotoItem: Operation] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        store = ThumbnailStore(directory: caches.appendingPathComponent("org.boltviewer.Bolt/Thumbnails"))
        queue.name = "Bolt thumbnails"
        queue.maxConcurrentOperationCount = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)
        queue.qualityOfService = .userInitiated
        let store = store
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10) { store.trimDisk() }
    }

    /// Returns the thumbnail if it's in memory; otherwise loads it and calls `completion` later.
    func image(for item: PhotoItem, completion: @escaping (CGImage?) -> Void) -> CGImage? {
        if let image = store.cached(item) { return image }
        waiting[item, default: []].append(completion)
        if let operation = operations[item] {
            operation.queuePriority = .veryHigh
            return nil
        }
        let store = store
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let image = store.load(item)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ThumbnailLoader.shared.finish(item, image: image) }
            }
        }
        operation.queuePriority = .veryHigh
        // Everything already waiting drops a notch, so the latest request wins.
        for pending in operations.values where !pending.isExecuting { pending.queuePriority = .normal }
        operations[item] = operation
        queue.addOperation(operation)
        return nil
    }

    /// The cell that asked scrolled away.
    func cancel(_ item: PhotoItem) {
        guard let operation = operations[item], !operation.isExecuting else { return }
        operation.cancel()
        operations[item] = nil
        waiting[item] = nil
    }

    private func finish(_ item: PhotoItem, image: CGImage?) {
        operations[item] = nil
        for callback in waiting.removeValue(forKey: item) ?? [] { callback(image) }
    }
}

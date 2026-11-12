import AppKit
import BoltCore
import os

/// Decodes frames in the background, keeps them in a byte-budgeted cache and hands them to the viewer.
///
/// The viewer says which frames it wants and how urgently (`schedule`); anything no longer wanted that
/// hasn't started yet is cancelled, so holding an arrow key never builds up a queue.
@MainActor
final class FrameLoader {
    enum Priority: Int, Comparable {
        case current, next, previous, background

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        var queuePriority: Operation.QueuePriority {
            switch self {
            case .current: .veryHigh
            case .next: .high
            case .previous: .normal
            case .background: .low
            }
        }

        var qualityOfService: QualityOfService {
            switch self {
            case .current: .userInteractive
            case .next, .previous: .userInitiated
            case .background: .utility
            }
        }
    }

    struct Request: Hashable, Sendable {
        let url: URL
        let kind: FrameKind
    }

    struct Stats {
        var hits = 0
        var misses = 0
        var lastDecode: Duration = .zero
        var lastDecodeKind: FrameKind = .screen
    }

    var onFrame: ((URL, DecodedFrame) -> Void)?
    var onFailure: ((URL) -> Void)?
    /// Pixel size frames are decoded to: the screen, so going full screen needs no new decode.
    private(set) var screenTarget = CGSize(width: 2560, height: 1600)
    /// True on screens that can show HDR; photos with HDR data are then decoded with it.
    private(set) var decodesHDR = false
    private(set) var stats = Stats()

    private let cache: LRUCache<Request, DecodedFrame>
    private let queue = OperationQueue()
    private var pending: [Request: DecodeOperation] = [:]
    /// Requests whose decode failed. Per kind: a RAW whose embedded preview shows fine but whose
    /// full decode fails is still a photo that opens.
    private var failed: Set<Request> = []
    /// Bumped when a file changes on disk, so decodes started before the change are thrown away.
    private var generations: [URL: Int] = [:]
    private let signposter = OSSignposter(subsystem: "org.boltviewer.Bolt", category: "Decode")

    init(budget: Int) {
        cache = LRUCache(budget: budget)
        queue.name = "Bolt decode"
        queue.maxConcurrentOperationCount = Self.performanceCoreCount
    }

    var cachedBytes: Int { cache.totalCost }

    /// Decodes for this screen from now on. True if the frame size changed.
    @discardableResult
    func fit(to screen: NSScreen) -> Bool {
        decodesHDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        let scale = screen.backingScaleFactor
        let target = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        guard target != screenTarget else { return false }
        screenTarget = target
        // Decodes already running are for the old size. Their frames still arrive, but the next
        // `schedule` starts these photos again at the new one.
        for operation in pending.values { operation.cancel() }
        pending.removeAll()
        return true
    }

    func setBudget(_ bytes: Int) {
        cache.setBudget(bytes)
    }

    // MARK: - Reading the cache

    /// The sharpest frame available right now: full, then screen, then the embedded preview.
    func bestFrame(for url: URL) -> DecodedFrame? {
        let frame = cache.value(for: Request(url: url, kind: .full))
            ?? cache.value(for: Request(url: url, kind: .screen))
            ?? cache.value(for: Request(url: url, kind: .preview))
        if frame == nil { stats.misses += 1 } else { stats.hits += 1 }
        return frame
    }

    /// True when the photo can't be shown at all: the screen-sized decode failed.
    func hasFailed(_ url: URL) -> Bool {
        failed.contains(Request(url: url, kind: .screen))
    }

    /// Reads the embedded preview on the calling thread. A few milliseconds for HEIC and JPEG from a local disk.
    func previewNow(_ url: URL) -> DecodedFrame? {
        let request = Request(url: url, kind: .preview)
        if let cached = cache.value(for: request) { return cached }
        // Being read in the background already (a new window does that): it's done or nearly done,
        // whereas one still waiting in the queue could be stuck behind screen-sized decodes.
        if let operation = pending[request], operation.isExecuting || operation.isFinished, !operation.isCancelled {
            operation.waitUntilFinished()
            if let frame = operation.result { cache.insert(frame, for: request, cost: frame.cost) }
            return operation.result
        }
        guard let frame = ImageDecoder.preview(at: url) else { return nil }
        cache.insert(frame, for: request, cost: frame.cost)
        return frame
    }

    /// True when the best cached frame already has every pixel the screen can show at this zoom.
    private func hasFullResolution(_ url: URL) -> Bool {
        if cache.peek(Request(url: url, kind: .full)) != nil { return true }
        return cache.peek(Request(url: url, kind: .screen))?.isFullResolution ?? false
    }

    // MARK: - Scheduling

    /// Replaces the set of wanted frames. Queued work for frames not in the list is cancelled.
    func schedule(_ wanted: [(Request, Priority)]) {
        let wantedRequests = Set(wanted.map(\.0))
        for (request, operation) in pending where !wantedRequests.contains(request) && !operation.isExecuting {
            operation.cancel()
            pending[request] = nil
        }
        for (request, priority) in wanted {
            guard !isSatisfied(request), !failed.contains(request) else { continue }
            if let operation = pending[request] {
                if !operation.isExecuting { operation.queuePriority = priority.queuePriority }
                continue
            }
            enqueue(request, priority: priority)
        }
    }

    private func cancelAll() {
        for operation in pending.values where !operation.isExecuting { operation.cancel() }
        pending = pending.filter { $0.value.isExecuting }
    }

    private func isSatisfied(_ request: Request) -> Bool {
        switch request.kind {
        case .preview:
            return cache.contains(request) || cache.contains(Request(url: request.url, kind: .screen))
        case .screen:
            guard let frame = cache.peek(request) else { return cache.contains(Request(url: request.url, kind: .full)) }
            // A frame decoded for a smaller screen doesn't count once the window moved to a bigger one.
            let needed = ImageDecoder.fittedLongSide(of: frame.info.pixelSize, in: screenTarget)
            return frame.isFullResolution || Double(frame.longSide) >= Double(needed) * 0.9
        case .full:
            return hasFullResolution(request.url)
        }
    }

    private func enqueue(_ request: Request, priority: Priority) {
        let generation = generations[request.url, default: 0]
        let target = screenTarget
        let signposter = signposter
        let operation = DecodeOperation(request: request, target: target, hdr: decodesHDR) { [weak self] operation, frame in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(operation, frame: frame, generation: generation)
                }
            }
        }
        operation.signposter = signposter
        operation.queuePriority = priority.queuePriority
        operation.qualityOfService = priority.qualityOfService
        pending[request] = operation
        queue.addOperation(operation)
    }

    private func finish(_ operation: DecodeOperation, frame: DecodedFrame?, generation: Int) {
        let request = operation.request
        if pending[request] === operation { pending[request] = nil }
        guard generation == generations[request.url, default: 0] else { return }

        guard let frame else {
            // A missing embedded thumbnail is normal; a failed screen decode means the file can't be shown.
            failed.insert(request)
            if request.kind == .screen { onFailure?(request.url) }
            return
        }
        cache.insert(frame, for: request, cost: frame.cost)
        stats.lastDecode = frame.decodeTime
        stats.lastDecodeKind = frame.kind
        onFrame?(request.url, frame)
    }

    // MARK: - Changes on disk

    /// Forgets everything about a file that changed or disappeared.
    func invalidate(_ url: URL) {
        generations[url, default: 0] += 1
        failed = failed.filter { $0.url != url }
        cache.removeAll { $0.url == url }
        for kind in [FrameKind.preview, .screen, .full] {
            let request = Request(url: url, kind: kind)
            pending.removeValue(forKey: request)?.cancel()
        }
    }

    /// Keeps decoded frames after a rename instead of decoding the same pixels again.
    func rename(_ old: URL, to new: URL) {
        // Whatever was cached under the new name belonged to another file.
        invalidate(new)
        for kind in [FrameKind.preview, .screen, .full] {
            if let frame = cache.peek(Request(url: old, kind: kind)) {
                cache.insert(frame, for: Request(url: new, kind: kind), cost: frame.cost)
            }
        }
        invalidate(old)
    }

    /// The orientation tag changed to `new`: turn the cached frames in memory instead of decoding again.
    /// Each frame is turned from the orientation it was decoded with, so a frame decoded after the tag
    /// was already rewritten isn't turned twice. Full-size frames are dropped; turning 48 megapixels
    /// costs more than decoding them when needed.
    func reorient(_ url: URL, to new: Int) {
        let kept = [FrameKind.preview, .screen].compactMap { kind in
            cache.peek(Request(url: url, kind: kind)).map { (kind, $0) }
        }
        invalidate(url)
        for (kind, frame) in kept {
            let relative = Orientation.relative(from: Orientation(exif: frame.info.orientation), to: Orientation(exif: new))
            if let rotated = FrameRotation.apply(relative, to: frame) {
                cache.insert(rotated, for: Request(url: url, kind: kind), cost: rotated.cost)
            }
        }
    }

    /// Drops screen-sized and full frames of photos outside `urls`. Embedded previews are tiny and stay.
    func retain(around urls: Set<URL>) {
        cache.removeAll { $0.kind != .preview && !urls.contains($0.url) }
    }

    /// Memory pressure: drop everything except the photos around the current one.
    func trim(keeping urls: Set<URL>) {
        cache.removeAll { !urls.contains($0.url) || $0.kind == .full }
    }

    func clear() {
        cancelAll()
        cache.removeAll()
        failed.removeAll()
    }

    private static let performanceCoreCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(ProcessInfo.processInfo.activeProcessorCount / 2, 2)
    }()
}

/// One decode. Checks for cancellation only before starting: ImageIO can't be interrupted midway.
private final class DecodeOperation: Operation, @unchecked Sendable {
    let request: FrameLoader.Request
    private let target: CGSize
    private let hdr: Bool
    private let completion: @Sendable (DecodeOperation, DecodedFrame?) -> Void
    var signposter: OSSignposter?
    /// Set before the operation finishes, so it can be read after `waitUntilFinished`.
    private(set) var result: DecodedFrame?

    init(request: FrameLoader.Request, target: CGSize, hdr: Bool,
         completion: @escaping @Sendable (DecodeOperation, DecodedFrame?) -> Void) {
        self.request = request
        self.target = target
        self.hdr = hdr
        self.completion = completion
    }

    override func main() {
        guard !isCancelled else { return }
        let state = signposter?.beginInterval("decode", "\(self.request.url.lastPathComponent, privacy: .public)")
        let frame: DecodedFrame? = switch request.kind {
        case .preview: ImageDecoder.preview(at: request.url)
        case .screen: ImageDecoder.screen(at: request.url, fitting: target, hdr: hdr)
        case .full: ImageDecoder.full(at: request.url, hdr: hdr)
        }
        if let state { signposter?.endInterval("decode", state) }
        result = frame
        completion(self, frame)
    }
}

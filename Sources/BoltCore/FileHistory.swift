import Foundation

/// Something the user asked to do with a file.
public enum FileRequest: Sendable {
    case trash(URL)
    case move(URL, into: URL)
    case copy(URL, into: URL)
    case rename(URL, to: String)
    /// Several renames in one folder that succeed or fail together; see `FileOperations.renameAll`.
    case renameAll([RenamePair])
    case transform(URL, OrientationTransform)
    case label(URL, LabelChange)
    /// A re-encoded copy in another folder: export presets, batch conversion.
    case export(URL, ExportSettings, into: URL)
    /// Crop or remove private metadata, saved next to the original or in its place.
    case edit(URL, ImageEdit, replacingOriginal: Bool)

    public var subject: URL {
        switch self {
        case .trash(let url), .move(let url, _), .copy(let url, _), .rename(let url, _), .transform(let url, _),
             .label(let url, _), .export(let url, _, _), .edit(let url, _, _): url
        case .renameAll(let pairs): pairs.first?.url ?? URL(fileURLWithPath: "/")
        }
    }

    /// Trash, move and copy take the photo's companions along (RAW, Live Photo video, edited copy).
    /// Each companion appears once even when several of a group were selected.
    static func includingCompanions(_ requests: [FileRequest]) -> [FileRequest] {
        var seen = Set(requests.map(\.subject))
        var result: [FileRequest] = []
        for request in requests {
            result.append(request)
            for companion in request.companions() where seen.insert(companion).inserted {
                result.append(request.applied(to: companion))
            }
        }
        return result
    }

    private func companions() -> [URL] {
        switch self {
        case .trash(let url), .move(let url, _), .copy(let url, _): Companions.of(url)
        case .rename, .renameAll, .transform, .label, .export, .edit: []
        }
    }

    private func applied(to url: URL) -> FileRequest {
        switch self {
        case .trash: .trash(url)
        case .move(_, let folder): .move(url, into: folder)
        case .copy(_, let folder): .copy(url, into: folder)
        case .rename, .renameAll, .transform, .label, .export, .edit: self
        }
    }

    func perform() throws -> [FileChange] {
        switch self {
        case .trash(let url):
            return [.trashed(original: url, trashed: try FileOperations.trash(url))]
        case .move(let url, let folder):
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return [.moved(from: url, to: try FileOperations.move(url, into: folder))]
        case .copy(let url, let folder):
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return [.copied(source: url, copy: try FileOperations.copy(url, into: folder))]
        case .rename(let url, let name):
            return [.moved(from: url, to: try FileOperations.rename(url, to: name))]
        case .renameAll(let pairs):
            return try FileOperations.renameAll(pairs.map { ($0.url, $0.name) }).map { .moved(from: $0.from, to: $0.to) }
        case .transform(let url, let transform):
            let old = try MetadataWriter.orientation(of: url)
            let new = Orientation(exif: old).applying(transform).exifValue
            try MetadataWriter.setOrientation(new, of: url)
            return [.reoriented(url, from: old, to: new)]
        case .label(let url, let change):
            let old = LabelStorage.read(url)
            let new = change.applied(to: old)
            try LabelStorage.write(new, to: url)
            return [.relabeled(url, from: old, to: new)]
        case .export(let url, let settings, let folder):
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = ImageExporter.destination(for: url, settings: settings, in: folder)
            return [.created(try ImageExporter.export(url, to: destination, settings: settings))]
        case .edit(let url, let edit, let replacing):
            return try edit.perform(on: url, replacingOriginal: replacing)
        }
    }
}

/// A pixel or metadata edit that produces a new file. The original is never overwritten in place:
/// either the result goes next to it, or the original goes to the Trash first.
public enum ImageEdit: Sendable {
    case crop(CGRect)
    case removePrivateData

    func perform(on url: URL, replacingOriginal: Bool) throws -> [FileChange] {
        let folder = url.deletingLastPathComponent()
        let output = replacingOriginal
            ? FileOperations.temporaryURL(beside: url)
            : FileOperations.availableURL(for: Self.copyName(for: url), in: folder)
        var written = output
        switch self {
        case .crop(let rect):
            written = try ImageExporter.export(url, to: output, settings: ExportSettings(format: nil, quality: 0.92),
                                               crop: rect)
        case .removePrivateData:
            try MetadataWriter.copyWithoutPrivateData(url, to: output)
        }
        guard replacingOriginal else { return [.copied(source: url, copy: written)] }
        let trashed: URL
        do {
            trashed = try FileOperations.trash(url)
        } catch {
            try? FileManager.default.removeItem(at: written)
            throw error
        }
        do {
            _ = try FileOperations.move(written, to: url)
        } catch {
            // The original is already in the Trash: bring it back before giving up.
            _ = try? FileOperations.moveBack(trashed, to: url)
            try? FileManager.default.removeItem(at: written)
            throw error
        }
        return [.trashed(original: url, trashed: trashed), .created(url)]
    }

    /// "IMG_1.HEIC" → "IMG_1 edited.HEIC".
    static func copyName(for url: URL) -> String {
        let name = url.lastPathComponent as NSString
        let suffix = NSLocalizedString("edited", comment: "Suffix for an edited copy: IMG_1 edited.HEIC")
        return name.pathExtension.isEmpty ? "\(name) \(suffix)"
                                          : "\(name.deletingPathExtension) \(suffix).\(name.pathExtension)"
    }
}

public struct RenamePair: Sendable {
    public let url: URL
    public let name: String

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

/// What an operation actually did, with enough detail to undo it.
/// Undoing a change produces another change, and undoing that one redoes the original.
public enum FileChange: Equatable, Sendable {
    case trashed(original: URL, trashed: URL)
    case restored(trashed: URL, original: URL)
    /// Also covers renames.
    case moved(from: URL, to: URL)
    case copied(source: URL, copy: URL)
    case reoriented(URL, from: Int, to: Int)
    case relabeled(URL, from: PhotoLabels, to: PhotoLabels)
    /// A file that didn't exist before: an export, or the edited photo put in place of the original.
    case created(URL)

    /// The file this change is about, where it is now.
    public var subject: URL {
        switch self {
        case .trashed(let original, _), .restored(_, let original): original
        case .moved(_, let to): to
        case .copied(_, let copy): copy
        case .reoriented(let url, _, _), .relabeled(let url, _, _), .created(let url): url
        }
    }

    /// The path that disappeared from its folder.
    public var removedURL: URL? {
        switch self {
        case .trashed(let original, _): original
        case .moved(let from, _): from
        case .restored, .copied, .reoriented, .relabeled, .created: nil
        }
    }

    /// The path that appeared in a folder.
    public var addedURL: URL? {
        switch self {
        case .restored(_, let original): original
        case .moved(_, let to): to
        case .copied(_, let copy): copy
        case .created(let url): url
        case .trashed, .reoriented, .relabeled: nil
        }
    }

    func reverted() throws -> FileChange {
        switch self {
        case .trashed(let original, let trashed):
            return .restored(trashed: trashed, original: try FileOperations.moveBack(trashed, to: original))
        case .restored(_, let original):
            return .trashed(original: original, trashed: try FileOperations.trash(original))
        case .moved(let from, let to):
            return .moved(from: to, to: try FileOperations.moveBack(to, to: from))
        case .copied(_, let copy), .created(let copy):
            // Undoing a copy never deletes outright: the copy goes to the Trash.
            return .trashed(original: copy, trashed: try FileOperations.trash(copy))
        case .reoriented(let url, let from, let to):
            try MetadataWriter.setOrientation(from, of: url)
            return .reoriented(url, from: to, to: from)
        case .relabeled(let url, let from, let to):
            try LabelStorage.write(from, to: url)
            return .relabeled(url, from: to, to: from)
        }
    }
}

/// Session-wide undo and redo for file operations.
///
/// Operations run in order on one background queue, so the UI can move on before the disk does,
/// and an undo issued right after an action still runs after that action finishes.
@MainActor
public final class FileHistory {
    public struct Failure: Sendable {
        public let url: URL
        public let message: String
    }

    public struct Outcome: Sendable {
        public let changes: [FileChange]
        public let failures: [Failure]
    }

    /// A batch of changes. `changes` is filled in on the file queue and only read there.
    private final class Entry: @unchecked Sendable {
        let label: String
        var changes: [FileChange] = []

        init(label: String) { self.label = label }
    }

    public typealias Completion = @MainActor @Sendable (Outcome) -> Void

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private let queue = DispatchQueue(label: "bolt.file-history", qos: .userInitiated)
    private let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }

    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    public func perform(_ requests: [FileRequest], label: String, completion: @escaping Completion) {
        let entry = Entry(label: label)
        undoStack.append(entry)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        run(entry: entry, completion: completion) {
            Self.apply(FileRequest.includingCompanions(requests).map { request in (request.subject, request.perform) })
        }
    }

    /// Returns false when there is nothing to undo.
    @discardableResult
    public func undo(completion: @escaping Completion) -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        let mirror = Entry(label: entry.label)
        redoStack.append(mirror)
        run(entry: mirror, completion: completion) { Self.revert(entry.changes) }
        return true
    }

    @discardableResult
    public func redo(completion: @escaping Completion) -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        let mirror = Entry(label: entry.label)
        undoStack.append(mirror)
        run(entry: mirror, completion: completion) { Self.revert(entry.changes) }
        return true
    }

    /// For long batches such as converting hundreds of photos: runs on all cores, off the queue that
    /// quick operations use, reports progress, and becomes a single undo step when it finishes.
    @discardableResult
    public func performBatch(_ requests: [FileRequest], label: String,
                             progress: @escaping @MainActor @Sendable (Int, Int) -> Void,
                             completion: @escaping Completion) -> BatchJob {
        let job = BatchJob(total: requests.count)
        let queue = queue
        job.running.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let requests = FileRequest.includingCompanions(requests)
            let results = concurrentMap(requests) { request -> (changes: [FileChange], failure: Failure?) in
                guard !job.isCancelled else { return ([], nil) }
                defer {
                    let done = job.finishOne()
                    if done % 4 == 0 || done == job.total {
                        DispatchQueue.main.async { MainActor.assumeIsolated { progress(done, job.total) } }
                    }
                }
                do {
                    return (try request.perform(), nil)
                } catch {
                    return ([], Failure(url: request.subject, message: error.localizedDescription))
                }
            }
            let changes = results.flatMap(\.changes)
            let failures = results.compactMap(\.failure)
            job.running.leave()
            let entry = Entry(label: label)
            // Written on the history queue like every other entry, so a later undo sees it.
            queue.async { entry.changes = changes }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !changes.isEmpty, let self {
                        self.undoStack.append(entry)
                        self.redoStack.removeAll()
                    }
                    completion(Outcome(changes: changes, failures: failures))
                }
            }
        }
        return job
    }

    /// Waits until every queued operation has finished, so quitting never cuts one short.
    public nonisolated func drain() {
        queue.sync {}
    }

    private func run(entry: Entry, completion: @escaping Completion,
                     work: @escaping @Sendable () -> ([FileChange], [Failure])) {
        queue.async { [weak self] in
            let (changes, failures) = work()
            entry.changes = changes
            let outcome = Outcome(changes: changes, failures: failures)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if changes.isEmpty { self?.forget(entry) }
                    completion(outcome)
                }
            }
        }
    }

    private func forget(_ entry: Entry) {
        undoStack.removeAll { $0 === entry }
        redoStack.removeAll { $0 === entry }
    }

    private nonisolated static func apply(_ steps: [(URL, () throws -> [FileChange])]) -> ([FileChange], [Failure]) {
        var changes: [FileChange] = []
        var failures: [Failure] = []
        for (url, step) in steps {
            do {
                changes.append(contentsOf: try step())
            } catch {
                failures.append(Failure(url: url, message: error.localizedDescription))
            }
        }
        return (changes, failures)
    }

    private nonisolated static func revert(_ changes: [FileChange]) -> ([FileChange], [Failure]) {
        apply(changes.reversed().map { change in (change.subject, { [try change.reverted()] }) })
    }
}

/// A running batch: how far it got, and a way to stop it. Photos already done stay done (and undoable).
public final class BatchJob: @unchecked Sendable {
    public let total: Int
    private let lock = NSLock()
    private var done = 0
    private var cancelled = false

    init(total: Int) {
        self.total = total
    }

    /// Left when every file has been handled, so quitting can wait for the batch to stop cleanly.
    let running = DispatchGroup()

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    /// Stops starting new files and waits for the ones in progress. Used when the app quits:
    /// a file must never be left half-written or parked in the Trash without its replacement.
    public func cancelAndWait() {
        cancel()
        running.wait()
    }

    func finishOne() -> Int {
        lock.withLock {
            done += 1
            return done
        }
    }
}

import Foundation
import Testing
@testable import BoltCore

/// Anything a test sends to the Trash has a unique name: tests run in parallel and share the Trash.
@MainActor
struct FileHistoryTests {
    let folder: TemporaryFolder
    let history = FileHistory()

    init() throws {
        folder = try TemporaryFolder()
    }

    @Test func undoPutsATrashedFileBack() async throws {
        let file = try folder.file(uniqueName("IMG_1.jpg"))

        let trashed = await history.performAndWait([.trash(file)])
        folder.cleanUpTrash(after: trashed)
        #expect(!exists(file))

        let restored = await history.undoAndWait()
        #expect(restored?.changes.first?.addedURL == file)
        #expect(exists(file))
    }

    @Test func undoAndRedoAMoveToABucket() async throws {
        let file = try folder.file("IMG_1.jpg")
        let picks = try folder.folder("Picks")

        _ = await history.performAndWait([.move(file, into: picks)])
        #expect(exists(picks.appendingPathComponent("IMG_1.jpg")))

        _ = await history.undoAndWait()
        #expect(exists(file))

        _ = await history.redoAndWait()
        #expect(exists(picks.appendingPathComponent("IMG_1.jpg")))
        #expect(!exists(file))
    }

    @Test func undoOfACopySendsTheCopyToTheTrash() async throws {
        let file = try folder.file(uniqueName("IMG_1.jpg"))
        let copy = try folder.folder("Picks").appendingPathComponent(file.lastPathComponent)

        _ = await history.performAndWait([.copy(file, into: copy.deletingLastPathComponent())])
        let undone = await history.undoAndWait()
        folder.cleanUpTrash(after: undone)

        let trashedChange = try #require(undone?.changes.first)
        guard case .trashed(let original, let trashed) = trashedChange else { Issue.record("not trashed"); return }
        #expect(original == copy)
        #expect(exists(trashed))
        #expect(exists(file))
    }

    @Test func undoRunsAfterTheActionItUndoesEvenIfIssuedImmediately() async throws {
        let file = try folder.file("IMG_1.jpg")
        let picks = try folder.folder("Picks")

        history.perform([.move(file, into: picks)], label: "move") { _ in }
        _ = await history.undoAndWait()

        #expect(exists(file))
    }

    @Test func failuresAreReportedAndLeaveNothingToUndo() async throws {
        let missing = folder.url.appendingPathComponent("gone.jpg")

        let outcome = await history.performAndWait([.trash(missing)])

        #expect(outcome.failures.map(\.url) == [missing])
        #expect(history.undoLabel == nil)
    }

    @Test func undoingABatchRestoresEveryFile() async throws {
        let files = try (1...3).map { try folder.file("IMG_\($0).jpg") }
        let picks = try folder.folder("Picks")

        _ = await history.performAndWait(files.map { .move($0, into: picks) })
        _ = await history.undoAndWait()

        #expect(files.allSatisfy(exists))
    }

    @Test func backgroundBatchReportsProgressAndUndoesAsOneStep() async throws {
        let files = try (1...6).map { try folder.jpeg(uniqueName("IMG_\($0).jpg")) }
        let output = folder.url.appendingPathComponent("Converted")
        var lastProgress = 0

        let outcome = await history.performBatchAndWait(files.map { .export($0, ExportSettings(format: .png), into: output) },
                                                        progress: { done, _ in lastProgress = done })
        #expect(outcome.changes.count == 6)
        #expect(lastProgress == 6)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count == 6)

        folder.cleanUpTrash(after: await history.undoAndWait())
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}

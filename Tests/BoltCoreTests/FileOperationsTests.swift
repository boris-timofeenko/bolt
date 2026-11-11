import Foundation
import Testing
@testable import BoltCore

struct FileOperationsTests {
    @Test func clashingNamesGetANumberInsteadOfReplacing() throws {
        let folder = try TemporaryFolder()
        let source = try folder.file("in/IMG_1.jpg", contents: "new")
        try folder.file("out/IMG_1.jpg", contents: "old")
        try folder.file("out/IMG_1 (2).jpg", contents: "older")

        let moved = try FileOperations.move(source, into: folder.url.appendingPathComponent("out"))

        #expect(moved.lastPathComponent == "IMG_1 (3).jpg")
        #expect(try String(contentsOf: folder.url.appendingPathComponent("out/IMG_1.jpg"), encoding: .utf8) == "old")
    }

    @Test func renameRefusesToOverwrite() throws {
        let folder = try TemporaryFolder()
        let first = try folder.file("a.jpg")
        try folder.file("b.jpg")

        #expect(throws: FileOperationError.nameTaken("b.jpg")) { try FileOperations.rename(first, to: "b.jpg") }
    }

    @Test func renameCanChangeOnlyTheLetterCase() throws {
        let folder = try TemporaryFolder()
        let file = try folder.file("img.jpg")

        let renamed = try FileOperations.rename(file, to: "IMG.jpg")

        #expect(renamed.lastPathComponent == "IMG.jpg")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["IMG.jpg"])
    }
}

struct RenameAllTests {
    @Test func namesCanSwap() throws {
        let folder = try TemporaryFolder()
        let a = try folder.file("a.jpg", contents: "A")
        let b = try folder.file("b.jpg", contents: "B")

        _ = try FileOperations.renameAll([(a, "b.jpg"), (b, "a.jpg")])

        #expect(try String(contentsOf: a, encoding: .utf8) == "B")
        #expect(try String(contentsOf: b, encoding: .utf8) == "A")
    }

    @Test func aClashWithAFileOutsideTheBatchPutsEverythingBack() throws {
        let folder = try TemporaryFolder()
        let first = try folder.file("2.jpg", contents: "two")
        let second = try folder.file("3.jpg", contents: "three")
        try folder.file("1.jpg", contents: "one")

        #expect(throws: FileOperationError.self) { try FileOperations.renameAll([(first, "1.jpg"), (second, "2.jpg")]) }

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(names == ["1.jpg", "2.jpg", "3.jpg"])
        #expect(try String(contentsOf: first, encoding: .utf8) == "two")
    }
}

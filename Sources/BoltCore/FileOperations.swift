import Darwin
import Foundation

public enum FileOperationError: LocalizedError, Equatable {
    case nameTaken(String)
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): String(format: NSLocalizedString("“%@” already exists.", comment: ""), name)
        case .invalidName: NSLocalizedString("That name can't be used.", comment: "")
        }
    }
}

/// The filesystem primitives behind every action. Nothing here deletes a file:
/// removal always goes through the Trash, and name clashes get a " (2)" suffix instead of overwriting.
public enum FileOperations {
    /// Moves to the Trash and returns where the file ended up, so it can be put back.
    public static func trash(_ url: URL) throws -> URL {
        // trashItem picks a free name in the Trash non-atomically: two files with the same name trashed
        // at once (a batch and another window) could be given the same spot. One at a time, then.
        try trashLock.withLock {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return (resulting as URL?) ?? url
        }
    }

    private static let trashLock = NSLock()

    /// Moves into `folder`, renaming to "name (2)" if the name is taken. Returns the new location.
    public static func move(_ url: URL, into folder: URL) throws -> URL {
        try move(url, to: availableURL(for: url.lastPathComponent, in: folder))
    }

    /// Moves to an exact path. Fails instead of replacing an existing file.
    public static func move(_ url: URL, to destination: URL) throws -> URL {
        if renamex_np(url.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
            return destination
        }
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Another volume: FileManager copies (cloning where it can), then removes the source.
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Copies into `folder` with " (2)" on a clash. APFS makes this a clone, not a byte copy.
    public static func copy(_ url: URL, into folder: URL) throws -> URL {
        let destination = availableURL(for: url.lastPathComponent, in: folder)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Renames within the same folder. Changing only letter case is allowed.
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileOperationError.invalidName
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
        guard destination.lastPathComponent != url.lastPathComponent else { return url }

        if renamex_np(url.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
        guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // "img.jpg" → "IMG.jpg" on a case-insensitive disk: the "existing" file is this very file.
        // On a case-sensitive disk it may be a different one, which must not be replaced.
        guard isSameFile(url, destination) else { throw FileOperationError.nameTaken(name) }
        guard renamex_np(url.path, destination.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }

    /// Renames several files in one folder as one step. Names may swap ("a" → "b", "b" → "a"): every file first
    /// gets a temporary name. If any rename fails, the files already renamed get their old names back.
    public static func renameAll(_ renames: [(url: URL, name: String)]) throws -> [(from: URL, to: URL)] {
        var parked: [(original: URL, temporary: URL)] = []
        var done: [(from: URL, to: URL)] = []
        do {
            for (url, _) in renames {
                parked.append((url, try rename(url, to: parkingName(for: url))))
            }
            for ((original, temporary), (_, name)) in zip(parked, renames) {
                done.append((original, try rename(temporary, to: name)))
            }
            return done
        } catch {
            for (original, renamed) in done.reversed() { _ = try? rename(renamed, to: original.lastPathComponent) }
            for (original, temporary) in parked.dropFirst(done.count) {
                _ = try? rename(temporary, to: original.lastPathComponent)
            }
            throw error
        }
    }

    /// A visible temporary name, so a crash between the two steps can't hide a photo.
    private static func parkingName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let tag = "bolt-\(UUID().uuidString.prefix(6))"
        return url.pathExtension.isEmpty ? "\(stem) (\(tag))" : "\(stem) (\(tag)).\(url.pathExtension)"
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        var first = stat()
        var second = stat()
        guard stat(a.path, &first) == 0, stat(b.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// A hidden name next to `url` for writing a file before it takes its real place.
    public static func temporaryURL(beside url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).bolt-\(UUID().uuidString.prefix(8))")
    }

    /// "IMG_1.HEIC" → "IMG_1 (2).HEIC" → "IMG_1 (3).HEIC"…
    public static func availableURL(for name: String, in folder: URL,
                                    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let candidate = folder.appendingPathComponent(name, isDirectory: false)
        guard exists(candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let numbered = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            let url = folder.appendingPathComponent(numbered, isDirectory: false)
            if !exists(url) { return url }
            number += 1
        }
    }

    /// Puts a file back at `original`, or next to it with a suffix if something took its place meanwhile.
    public static func moveBack(_ url: URL, to original: URL) throws -> URL {
        let folder = original.deletingLastPathComponent()
        if folder.isSameLocation(as: url.deletingLastPathComponent()) {
            do {
                return try rename(url, to: original.lastPathComponent)
            } catch FileOperationError.nameTaken {
                return try move(url, into: folder, named: original.lastPathComponent)
            }
        }
        return try move(url, into: folder, named: original.lastPathComponent)
    }

    /// Moves into `folder` under `name`, or "name (2)" if that's taken.
    public static func move(_ url: URL, into folder: URL, named name: String) throws -> URL {
        try move(url, to: availableURL(for: name, in: folder))
    }
}

extension URL {
    /// The same file or folder, however the path was spelled ("/a/b/../c" and "/a/c").
    public func isSameLocation(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }

    /// True for folders; false for files and for paths that don't exist.
    public var isFolder: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

import Darwin
import Foundation

/// Lists a directory with `getattrlistbulk`: one syscall returns names, types, sizes and dates
/// for hundreds of entries, which keeps a 10 000-file folder well under the 1 s budget.
public enum FolderScanner {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let fileSize: Int64
        public let modified: Date
    }

    /// Visible files and folders, in no particular order. Hidden entries are skipped.
    public static func entries(in folder: URL) throws -> [Entry] {
        do {
            return try bulkEntries(in: folder)
        } catch let error as POSIXError where error.code == .ENOTSUP || error.code == .EINVAL {
            // Some network file systems don't implement getattrlistbulk.
            return try fileManagerEntries(in: folder)
        }
    }

    /// Photos and videos directly inside `folder`, unsorted. The video half of a Live Photo
    /// (IMG_1234.MOV next to IMG_1234.HEIC) is left out: it belongs to the photo.
    public static func photos(in folder: URL) throws -> [PhotoItem] {
        let files = try entries(in: folder).filter { !$0.isDirectory && MediaTypes.isMedia(name: $0.name) }
        let imageStems = Set(files.filter { MediaTypes.isImage(name: $0.name) }.map { stem(of: $0.name) })
        return files
            .filter { !MediaTypes.isVideo(name: $0.name) || !imageStems.contains(stem(of: $0.name)) }
            .map { PhotoItem(url: folder.appendingPathComponent($0.name, isDirectory: false),
                             fileSize: $0.fileSize, modified: $0.modified) }
    }

    /// Whether one file belongs in the list, by the same rule `photos(in:)` applies to a whole folder.
    public static func isListed(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard MediaTypes.isMedia(name: name) else { return false }
        guard MediaTypes.isVideo(name: name) else { return true }
        return !Companions.of(url).contains { MediaTypes.isImage($0) && stem(of: $0.lastPathComponent) == stem(of: name) }
    }

    private static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    /// Visible subfolders of `folder`, sorted the way Finder sorts names.
    public static func subfolders(of folder: URL) -> [URL] {
        let names = ((try? entries(in: folder)) ?? []).filter(\.isDirectory).map(\.name)
        return NaturalOrder.sorted(names).map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: - getattrlistbulk

    private static func bulkEntries(in folder: URL) throws -> [Entry] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = group(ATTR_CMN_RETURNED_ATTRS) | group(ATTR_CMN_NAME) | group(ATTR_CMN_OBJTYPE)
            | group(ATTR_CMN_MODTIME) | group(ATTR_CMN_FLAGS)
        request.fileattr = group(ATTR_FILE_DATALENGTH)

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var result: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let entry = parseRecord(record + MemoryLayout<UInt32>.size) {
                    result.append(entry)
                }
                record += length
            }
        }
        return result
    }

    /// Fields come in a fixed order: the returned-attributes set, then common attributes by bit value,
    /// then file attributes. Fields the file system didn't return are absent, not zeroed.
    private static func parseRecord(_ start: UnsafeRawPointer) -> Entry? {
        var field = start
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        var name = ""
        if returned.commonattr & group(ATTR_CMN_NAME) != 0 {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            field += MemoryLayout<attrreference_t>.size
        }
        var objectType: fsobj_type_t = 0
        if returned.commonattr & group(ATTR_CMN_OBJTYPE) != 0 {
            objectType = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
        }
        var modified = Date.distantPast
        if returned.commonattr & group(ATTR_CMN_MODTIME) != 0 {
            modified = Date(timespec: field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if returned.commonattr & group(ATTR_CMN_FLAGS) != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var size: Int64 = 0
        if returned.fileattr & group(ATTR_FILE_DATALENGTH) != 0 {
            size = field.loadUnaligned(as: off_t.self)
        }

        let isDirectory = objectType == VDIR.rawValue
        let isFile = objectType == VREG.rawValue || objectType == VLNK.rawValue
        guard !name.isEmpty, !name.hasPrefix("."), flags & UInt32(UF_HIDDEN) == 0, isDirectory || isFile else {
            return nil
        }
        return Entry(name: name, isDirectory: isDirectory, fileSize: size, modified: modified)
    }

    private static func group<T: BinaryInteger>(_ value: T) -> attrgroup_t {
        attrgroup_t(truncatingIfNeeded: value)
    }

    // MARK: - Fallback

    private static func fileManagerEntries(in folder: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(name: url.lastPathComponent, isDirectory: values.isDirectory ?? false,
                         fileSize: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }
}

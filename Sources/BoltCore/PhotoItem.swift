import Foundation

/// A file in the viewer's list. Only what the directory listing gives for free;
/// EXIF and pixel data are read later and cached separately.
public struct PhotoItem: Hashable, Sendable, Identifiable {
    public let url: URL
    public let fileSize: Int64
    public let modified: Date

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var folder: URL { url.deletingLastPathComponent() }

    public init(url: URL, fileSize: Int64, modified: Date) {
        self.url = url
        self.fileSize = fileSize
        self.modified = modified
    }

    /// Reads size and modification date with a single stat call. Returns nil if the file is gone.
    public init?(url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        self.init(url: url, fileSize: Int64(info.st_size), modified: Date(timespec: info.st_mtimespec))
    }
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}

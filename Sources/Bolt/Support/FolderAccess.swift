import AppKit

/// Folder access for the App Store build, which runs in the App Sandbox. There Bolt may only read what the user
/// handed it: a photo opened from Finder gives access to that one file, not to its folder. So Bolt asks once for
/// the folder (or any folder above it) and keeps a security-scoped bookmark, which keeps working after a restart.
/// Outside the sandbox every call here does nothing.
@MainActor
enum FolderAccess {
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static let key = "folderAccess"
    private static var granted: [URL] = []

    /// Takes back the folders granted in earlier runs. Call once at launch.
    static func restore() {
        guard isSandboxed else { return }
        var fresh: [Data] = []
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            granted.append(url)
            fresh.append(stale ? (bookmark(url) ?? data) : data)
        }
        UserDefaults.standard.set(fresh, forKey: key)
    }

    /// The real home folder: in the sandbox NSHomeDirectory() is the app's container.
    nonisolated static let home: URL = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }()

    static func canRead(_ folder: URL) -> Bool {
        guard isSandboxed else { return true }
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Keeps access to a folder the user just chose or dropped, unless a granted folder already covers it.
    static func remember(_ folder: URL) {
        guard isSandboxed, !granted.contains(where: { folder.isInside($0) }), let data = bookmark(folder) else { return }
        granted.append(folder)
        UserDefaults.standard.set((UserDefaults.standard.array(forKey: key) as? [Data] ?? []) + [data], forKey: key)
    }

    /// Asks for a folder Bolt can't read yet. `done` gets true once it can.
    static func request(_ folder: URL, in window: NSWindow?, done: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.message = L("To show the other photos in “%@”, Bolt needs access to the folder. If you allow a folder above it, such as your home folder, Bolt won't ask about the folders inside it again.", folder.lastPathComponent)
        panel.prompt = L("Allow")
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return done(false) }
            remember(url)
            done(canRead(folder))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

private extension URL {
    func isInside(_ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.path
        let path = standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

import AppKit
import BoltCore

/// State shared by all windows: the open viewers, the key map, and the undo history for files.
@MainActor
final class Session {
    let history = FileHistory()
    private(set) var controllers: [ViewerWindowController] = []
    private(set) var keyMap = KeyMap.current()
    var onKeyMapChange: (() -> Void)?

    private var settingsWindow: NSWindow?
    private var guideWindow: NSWindow?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// The viewer the user is looking at: key window first, then main window, then any.
    var activeController: ViewerWindowController? {
        controllers.first { $0.owns(NSApp.keyWindow) }
            ?? controllers.first { $0.owns(NSApp.mainWindow) }
    }

    // MARK: - Windows

    @discardableResult
    func newWindow(opening url: URL? = nil) -> ViewerWindowController {
        let controller = ViewerWindowController(session: self, opening: url, after: controllers.last?.window)
        LaunchTimeline.mark("window created")
        controllers.append(controller)
        controller.showWindow(nil)
        // The window appears with its first committed frame. Commit it now rather than after the rest of
        // launch (the menu, the key monitor): ~15 ms sooner on screen.
        CATransaction.flush()
        LaunchTimeline.mark("window shown")
        return controller
    }

    /// Opens photos or folders. A folder already open in some window is reused, so double-clicking
    /// another photo from the same folder in Finder jumps there instead of opening a second window.
    func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let isFolder = url.isFolder
        let folder = isFolder ? url : url.deletingLastPathComponent()

        if let existing = controllers.first(where: { $0.gallery.folder?.isSameLocation(as: folder) ?? false }) {
            if isFolder {
                existing.open(url)
            } else if !existing.gallery.move(to: url) {
                existing.open(url)
            } else {
                existing.displayCurrent()
            }
            existing.visibleWindow?.makeKeyAndOrderFront(nil)
            return
        }
        if let empty = controllers.first(where: { $0.gallery.folder == nil }) {
            empty.open(url)
            empty.visibleWindow?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(opening: url)
        }
    }

    func windowDidClose(_ controller: ViewerWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func showOpenPanel(for controller: ViewerWindowController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller?.gallery.folder
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let controller {
                controller.open(url)
            } else {
                self?.open([url])
            }
        }
        if let window = controller?.visibleWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: - Changes

    /// Every window updates its list from the same file changes, so two windows on one folder stay in sync.
    func broadcast(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        for controller in controllers { controller.apply(changes) }
    }

    func preferencesDidChange() {
        let current = KeyMap.current()
        if current.bindings != keyMap.bindings {
            keyMap = current
            onKeyMapChange?()
        }
        for controller in controllers { controller.applyPreferences() }
    }

    // MARK: - Settings

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Made anew each time, so it shows the shortcuts as they are now.
    func showSortingGuide() {
        let frame = guideWindow?.isVisible == true ? guideWindow?.frame : nil
        guideWindow?.close()
        guideWindow = GuideWindow.make(keyMap: keyMap)
        if let frame { guideWindow?.setFrame(frame, display: false) }
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Memory

    /// Under memory pressure every window keeps only the photos next to the current one.
    func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.controllers.forEach { $0.trimMemory() }
            }
        }
        source.activate()
        memoryPressure = source
    }
}

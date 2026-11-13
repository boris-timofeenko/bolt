import AppKit
import BoltCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let session = Session()
    private var keyMonitor: Any?
    private var debugControl: DebugControl?

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTimeline.mark("will finish launching")
        Preferences.registerDefaults()
        FolderAccess.restore()
        session.onKeyMapChange = { [weak self] in self?.rebuildMenu() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTimeline.mark("did finish launching")
        // Opened from Finder, the photo is already on screen by now: the menu (~10 ms) doesn't delay it.
        rebuildMenu()
        installKeyMonitor()
        session.startMemoryPressureMonitoring()
        NSApp.servicesProvider = self
        if DebugControl.isEnabled { debugControl = DebugControl(session: session) }
        PresentProbe.install(session: session)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.preferencesDidChange() }
        }
        // Launched by double-clicking a photo, the open request has already made a window by now.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.controllers.isEmpty else { return }
            self.session.newWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        LaunchTimeline.mark("open request")
        session.open(urls)
    }

    /// Stay running with no windows: the next double-click in Finder then opens instantly.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { session.newWindow() }
        return true
    }

    /// In the background the app keeps only the photos next to the current one: idle memory stays small.
    func applicationDidResignActive(_ notification: Notification) {
        session.controllers.forEach { $0.trimMemory() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Let file operations that are already running finish rather than leave half-written files:
        // batches stop taking new photos, and the ones in progress complete.
        session.controllers.compactMap(\.batchJob).forEach { $0.cancelAndWait() }
        session.history.drain()
    }

    /// Finder's Services menu: "Open in Bolt" for a selected folder or photo.
    @objc func openFolderService(_ pasteboard: NSPasteboard, userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        session.open(urls ?? [])
    }

    // MARK: - Keys

    /// Every shortcut goes through here, matched by physical key so it works on any keyboard layout.
    /// Text fields (rename, search) get keys untouched.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard event.type == .keyDown else { return self?.handleKeyUp(event) ?? false }
                PresentProbe.mark("keyDown")
                defer { PresentProbe.handlerEnd() }
                return self?.handleKeyDown(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        session.controllers.first { $0.owns(event.window) }?.handleKeyUp(event) ?? false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !Self.isEditingText, event.window?.attachedSheet == nil,
              let controller = session.controllers.first(where: { $0.owns(event.window) }) else { return false }
        return controller.handleKeyDown(event)
    }

    private static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private func rebuildMenu() {
        NSApp.mainMenu = MainMenu.build(keyMap: session.keyMap)
    }

    // MARK: - Menu actions

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? CommandBox)?.command else { return }
        if let controller = session.activeController {
            controller.perform(command)
        } else if command == .open {
            session.showOpenPanel(for: nil)
        } else if command == .settings {
            session.showSettings()
        } else if command == .sortingGuide {
            session.showSortingGuide()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        session.showOpenPanel(for: session.activeController)
    }

    @objc func showSettings(_ sender: Any?) {
        session.showSettings()
    }

    @objc func closeViewer(_ sender: Any?) {
        if let controller = session.activeController, controller.owns(NSApp.keyWindow) {
            controller.closeViewer()
        } else {
            NSApp.keyWindow?.performClose(sender)
        }
    }

    @objc func newViewerWindow(_ sender: Any?) {
        session.newWindow()
    }

    /// Cmd+Z undoes typing while renaming, and file operations otherwise.
    @objc func undoAction(_ sender: Any?) {
        if Self.isEditingText {
            NSApp.keyWindow?.firstResponder?.undoManager?.undo()
        } else {
            session.activeController?.undo()
        }
    }

    @objc func redoAction(_ sender: Any?) {
        if Self.isEditingText {
            NSApp.keyWindow?.firstResponder?.undoManager?.redo()
        } else {
            session.activeController?.redo()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoAction(_:)):
            if Self.isEditingText { return NSApp.keyWindow?.firstResponder?.undoManager?.canUndo ?? false }
            menuItem.title = session.history.undoLabel.map { L("Undo %@", $0) } ?? L("Undo")
            return session.history.undoLabel != nil && session.activeController != nil
        case #selector(redoAction(_:)):
            if Self.isEditingText { return NSApp.keyWindow?.firstResponder?.undoManager?.canRedo ?? false }
            menuItem.title = session.history.redoLabel.map { L("Redo %@", $0) } ?? L("Redo")
            return session.history.redoLabel != nil && session.activeController != nil
        case #selector(performCommand(_:)):
            guard let command = (menuItem.representedObject as? CommandBox)?.command else { return false }
            // Disabled while typing, so single-letter shortcuts in menus don't swallow keystrokes.
            if Self.isEditingText { return false }
            switch command {
            case .moveToBucket, .copyToBucket, .openInEditor, .export:
                menuItem.title = command.title
            default:
                break
            }
            guard let controller = session.activeController else {
                return command == .open || command == .settings || command == .sortingGuide
            }
            menuItem.state = controller.isChecked(command) ? .on : .off
            return controller.isEnabled(command)
        default:
            return true
        }
    }
}

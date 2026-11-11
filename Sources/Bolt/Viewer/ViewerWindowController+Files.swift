import AppKit
import BoltCore
import UniformTypeIdentifiers

/// Trash, buckets, rename, rotate, undo: everything that changes files.
///
/// Moves and deletions are optimistic: the photo leaves the list and the next one is on screen
/// before the disk is touched. If the operation fails the photo comes back and a toast says why.
extension ViewerWindowController {
    // MARK: - Trash and buckets

    func trashTargets() {
        let targets = gallery.targets
        guard !targets.isEmpty else { return }
        removeFromList(targets)
        showToast(withUndoHint(countSuffix(L("Moved to Trash"), targets.count)))
        session.history.perform(targets.map { .trash($0.url) }, label: L("history.trash")) { [weak self] outcome in
            self?.finish(outcome)
        }
    }

    func sendToBucket(_ number: Int, copying: Bool) {
        guard let folder = Preferences.bucket(number) else {
            // First press of an unassigned digit: pick the folder, remember it, then do the action.
            pickFolder(title: L("Folder for key %d", number)) { [weak self] folder in
                Preferences.setBucket(number, to: folder)
                self?.send(to: folder, copying: copying)
            }
            return
        }
        send(to: folder, copying: copying)
    }

    func send(to folder: URL, copying: Bool) {
        let targets = gallery.targets
        guard !targets.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            showToast(error.localizedDescription, isError: true)
            return
        }
        Preferences.noteRecentFolder(folder)
        let name = folder.lastPathComponent

        if copying {
            showToast(withUndoHint(countSuffix(L("Copied to “%@”", name), targets.count)))
            session.history.perform(targets.map { .copy($0.url, into: folder) }, label: L("history.copy %@", name)) {
                [weak self] outcome in self?.finish(outcome)
            }
            advanceAfterNonRemovingAction()
            return
        }

        guard !(gallery.folder.map(folder.isSameLocation(as:)) ?? false) else {
            showToast(L("The photo is already in “%@”", name))
            return
        }
        removeFromList(targets)
        showToast(withUndoHint(countSuffix(L("Moved to “%@”", name), targets.count)))
        session.history.perform(targets.map { .move($0.url, into: folder) }, label: L("history.move %@", name)) {
            [weak self] outcome in self?.finish(outcome)
        }
    }

    /// Takes photos out of the list before the files move, so the next photo shows at once.
    private func removeFromList(_ items: [PhotoItem]) {
        let urls = Set(items.map(\.url))
        let currentLeaves = gallery.current.map { urls.contains($0.url) } ?? false
        let survivorsBefore = gallery.items[..<gallery.currentIndex].filter { !urls.contains($0.url) }.count
        gallery.remove(urls)
        // Going backwards, the photo "after" a deleted one is the previous one. At the end of the list
        // the gallery already fell back to it.
        if currentLeaves, direction < 0, survivorsBefore > 0, gallery.currentIndex == survivorsBefore {
            gallery.step(by: -1)
        }
        displayCurrent()
    }

    /// Copy, flag and rating leave the photo in place; move on unless the user prefers to stay.
    func advanceAfterNonRemovingAction() {
        gallery.clearSelection()
        if Preferences.afterAction == .next {
            go(by: direction)
        } else {
            updateChrome()
        }
    }

    /// The end of every file action: all windows learn what changed, a failure shows its reason,
    /// and a success shows `success` if given (optimistic actions show theirs up front).
    func report(_ outcome: FileHistory.Outcome, success: String? = nil) {
        session.broadcast(outcome.changes)
        if let failure = outcome.failures.first {
            let others = outcome.failures.count - 1
            showToast(others > 0 ? L("%@ (and %d more)", failure.message, others) : failure.message, isError: true)
        } else if let success, !outcome.changes.isEmpty {
            showToast(withUndoHint(success))
        }
    }

    /// Like `report`, and puts back photos that left the list before their move failed.
    private func finish(_ outcome: FileHistory.Outcome) {
        for failure in outcome.failures {
            if let item = PhotoItem(url: failure.url), isInFolder(item.url) { gallery.insert(item) }
        }
        if !outcome.failures.isEmpty { displayCurrent() }
        report(outcome)
    }

    // MARK: - Folder picker

    /// M / Shift+M: any folder, chosen with fuzzy search.
    func moveOrCopyToChosenFolder(copying: Bool) {
        pickFolder(title: copying ? L("Copy to…") : L("Move to…")) { [weak self] folder in
            self?.send(to: folder, copying: copying)
        }
    }

    /// Cmd+Shift+digit: choose the folder for a key without doing anything else.
    func assignBucket(_ number: Int) {
        pickFolder(title: L("Folder for key %d", number)) { [weak self] folder in
            Preferences.setBucket(number, to: folder)
            self?.showToast(L("Key %d → “%@”", number, folder.lastPathComponent))
        }
    }

    func pickFolder(title: String, then action: @escaping (URL) -> Void) {
        let base = gallery.folder
        let candidates = FolderPicker.candidates(near: base)
        presentPicker(title: title, placeholder: L("Folder name")) { [weak self] query in
            FolderPicker.items(query: query, candidates: candidates, base: base, choose: action) {
                self?.browseForFolder(then: action)
            }
        }
    }

    private func browseForFolder(then action: @escaping (URL) -> Void) {
        guard let window = visibleWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = gallery.folder
        panel.prompt = L("Choose")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            action(url)
        }
    }

    // MARK: - Rename

    func beginRename() {
        guard let item = gallery.current, !statusBar.isRenaming else { return }
        root.forceStatusBar = true
        statusBar.beginRename(item.name) { [weak self] newName in
            guard let self else { return }
            self.root.forceStatusBar = false
            self.visibleWindow?.makeFirstResponder(self.canvas)
            guard var newName = newName?.trimmingCharacters(in: .whitespaces), newName != item.name,
                  !newName.isEmpty else { return }
            // Dropping the extension by accident would hide the photo from every viewer; keep it.
            let ext = item.url.pathExtension
            if (newName as NSString).pathExtension.isEmpty, !ext.isEmpty { newName += "." + ext }
            self.session.history.perform([.rename(item.url, to: newName)], label: L("history.rename")) { [weak self] outcome in
                self?.finish(outcome)
            }
        }
    }

    // MARK: - Rotate and flip

    func transformTargets(_ transform: OrientationTransform) {
        let targets = gallery.targets
        guard !targets.isEmpty else { return }
        let label = transform == .flipHorizontal ? L("history.flip") : L("history.rotate")
        session.history.perform(targets.map { .transform($0.url, transform) }, label: label) { [weak self] outcome in
            self?.finish(outcome)
        }
    }

    // MARK: - Undo

    func undo() {
        guard let label = session.history.undoLabel else {
            showToast(L("Nothing to undo"))
            return
        }
        session.history.undo { [weak self] outcome in self?.finishUndo(outcome) }
        showToast(L("Undone: %@", label))
    }

    func redo() {
        guard let label = session.history.redoLabel else {
            showToast(L("Nothing to redo"))
            return
        }
        session.history.redo { [weak self] outcome in self?.finishUndo(outcome) }
        showToast(L("Redone: %@", label))
    }

    /// After undo the photo that came back is shown: that's what the user wanted to see again.
    private func finishUndo(_ outcome: FileHistory.Outcome) {
        report(outcome)
        if let restored = outcome.changes.compactMap(\.addedURL).first(where: isInFolder), gallery.move(to: restored) {
            displayCurrent()
        }
    }

    // MARK: - Changes from any window

    /// Applies finished file operations to this window's list. Safe to call twice with the same change.
    func apply(_ changes: [FileChange]) {
        guard gallery.folder != nil else { return }
        let results = changes.map(apply)
        if results.contains(true) { displayCurrent() }
    }

    /// Returns true when the list or the photo on screen changed.
    private func apply(_ change: FileChange) -> Bool {
        switch change {
        case .moved(let from, let to) where gallery.contains(from) && isInFolder(to):
            // A rename: keep the place in the list and the decoded frames.
            guard let item = PhotoItem(url: to) else { return false }
            loader.rename(from, to: to)
            labels[to] = labels.removeValue(forKey: from)
            gallery.replace(from, with: item)
            return true
        case .relabeled(let url, _, let new) where gallery.contains(url):
            applyLabelChange(url, to: new)
            return false
        case .reoriented(let url, _, let new) where gallery.contains(url):
            loader.reorient(url, to: new)
            if let item = PhotoItem(url: url) { gallery.replace(url, with: item) }
            return true
        default:
            let removed = dropFromList(change.removedURL)
            let added = addToList(change.addedURL)
            return removed || added
        }
    }

    private func dropFromList(_ url: URL?) -> Bool {
        guard let url, gallery.contains(url) else { return false }
        // Another file may later appear under this name; it must not inherit these pixels.
        loader.invalidate(url)
        gallery.remove([url])
        return true
    }

    private func addToList(_ url: URL?) -> Bool {
        guard let url, isInFolder(url), FolderScanner.isListed(url), let item = PhotoItem(url: url) else { return false }
        // The path may be reused by a different file, e.g. a crop that replaced its original.
        loader.invalidate(url)
        let found = LabelStorage.read(url)
        if !found.isEmpty { labels[url] = found }
        gallery.insert(item)
        return true
    }

    func isInFolder(_ url: URL) -> Bool {
        gallery.folder.map(url.deletingLastPathComponent().isSameLocation(as:)) ?? false
    }

    // MARK: - Clipboard, Finder, sharing

    func copyImage() {
        guard let item = gallery.current else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([ImagePasteboardItem.make(for: item.url)])
        showToast(L("Image copied"))
    }

    func copyPath() {
        let paths = gallery.targets.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        showToast(paths.count == 1 ? L("Path copied") : L("Paths copied: %d", paths.count))
    }

    func revealInFinder() {
        let urls = gallery.targets.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func share() {
        let urls = gallery.targets.map(\.url)
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = NSRect(x: canvas.bounds.midX - 1, y: canvas.bounds.maxY - 40, width: 2, height: 2)
        picker.show(relativeTo: anchor, of: canvas, preferredEdge: .maxY)
    }

    func openInEditor() {
        let urls = gallery.targets.map(\.url)
        guard !urls.isEmpty, let editor = Preferences.externalEditor else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Toast text

    private func countSuffix(_ text: String, _ count: Int) -> String {
        count > 1 ? text + " · " + L("%d photos", count) : text
    }

    func withUndoHint(_ text: String) -> String {
        guard let chord = session.keyMap.chord(for: .undo) else { return text }
        return text + " · " + chord.symbol
    }
}

/// Puts a photo on the pasteboard as a file (Finder, mail), as its original bytes (apps that read JPEG or HEIC)
/// and, only when an app asks, as PNG and TIFF.
private final class ImagePasteboardItem: NSObject, NSPasteboardItemDataProvider {
    private let url: URL
    /// The pasteboard doesn't retain its data providers.
    @MainActor private static var live: [ImagePasteboardItem] = []

    private init(url: URL) {
        self.url = url
    }

    @MainActor
    static func make(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let type = UTType(filenameExtension: url.pathExtension),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        let provider = ImagePasteboardItem(url: url)
        live = [provider]
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        return item
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let frame = ImageDecoder.full(at: url) else { return }
        let bitmap = NSBitmapImageRep(cgImage: frame.image)
        let data = type == .png ? bitmap.representation(using: .png, properties: [:]) : bitmap.tiffRepresentation
        if let data { item.setData(data, forType: type) }
    }
}

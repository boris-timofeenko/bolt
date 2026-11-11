import AppKit
import BoltCore
import Carbon.HIToolbox

/// The thumbnail grid (G) and strip (T).
extension ViewerWindowController: PhotoGridDelegate {
    var showsGrid: Bool { root.showsGrid }

    func toggleGrid() {
        setGridVisible(!showsGrid)
    }

    func setGridVisible(_ visible: Bool) {
        guard visible != showsGrid else { return }
        root.showsGrid = visible
        if visible {
            loader.schedule([])
            subfolders = gallery.folder.map(FolderScanner.subfolders(of:)) ?? []
            root.layoutSubtreeIfNeeded()
            updateChrome()
        } else {
            displayCurrent()
        }
    }

    /// Cmd+Up: the enclosing folder, as a grid with its subfolders on top.
    func openParentFolder() {
        guard let folder = gallery.folder else { return }
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return }
        open(parent)
        setGridVisible(true)
    }

    /// Grid mode moves by rows with Up and Down, and Return opens the photo instead of renaming it.
    func handleGridKey(_ event: NSEvent) -> Bool {
        guard showsGrid, event.hasNoModifiers else { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            go(by: -root.grid.columns)
        case kVK_DownArrow:
            go(by: root.grid.columns)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            setGridVisible(false)
        default:
            return false
        }
        return true
    }

    func updateThumbnails() {
        if showsGrid {
            root.grid.update(gallery: gallery, folders: subfolders, labels: labels, labelsRevision: labelsRevision)
        }
        if root.showsStrip { root.strip.update(gallery: gallery, labels: labels, labelsRevision: labelsRevision) }
    }

    func resizeGridTiles(larger: Bool) {
        root.grid.setTileSize(root.grid.tileSize * (larger ? 1.25 : 0.8))
    }

    // MARK: - PhotoGridDelegate

    func grid(_ grid: PhotoGridView, didClickPhotoAt index: Int, extendingSelection: Bool) {
        if extendingSelection {
            gallery.extendSelection(to: index)
            updateChrome()
        } else {
            go(to: index)
            if !showsGrid { displayCurrent() }
        }
    }

    func grid(_ grid: PhotoGridView, didOpenPhotoAt index: Int) {
        go(to: index)
        setGridVisible(false)
    }

    func grid(_ grid: PhotoGridView, didOpenFolder url: URL) {
        open(url)
        setGridVisible(true)
    }
}

import AppKit
import BoltCore

@MainActor
protocol PhotoGridDelegate: AnyObject {
    func grid(_ grid: PhotoGridView, didClickPhotoAt index: Int, extendingSelection: Bool)
    func grid(_ grid: PhotoGridView, didOpenPhotoAt index: Int)
    func grid(_ grid: PhotoGridView, didOpenFolder url: URL)
}

/// Thumbnails of the folder, either as a full-window grid (G) or as a one-row strip under the photo (T).
/// The gallery owns the current photo and the selection; this view only shows them.
final class PhotoGridView: NSScrollView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    enum Style {
        case grid, strip
    }

    weak var delegate: PhotoGridDelegate?
    let style: Style
    static let stripHeight: CGFloat = 78

    private let collection = GridCollectionView()
    private var folders: [URL] = []
    private var items: [PhotoItem] = []
    private var currentIndex = 0
    private var selection: Set<URL> = []
    private var revision = -1
    private var labels: [URL: PhotoLabels] = [:]
    private var labelsRevision = -1
    private(set) var tileSize: CGFloat = 150

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        let layout = NSCollectionViewFlowLayout()
        switch style {
        case .grid:
            layout.minimumInteritemSpacing = 10
            layout.minimumLineSpacing = 14
            layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        case .strip:
            layout.scrollDirection = .horizontal
            layout.minimumInteritemSpacing = 4
            layout.minimumLineSpacing = 4
            layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            hasHorizontalScroller = true
            scrollerStyle = .overlay
        }
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(ThumbnailTile.self, forItemWithIdentifier: ThumbnailTile.identifier)
        collection.onClick = { [weak self] point, clickCount, modifiers in
            self?.handleClick(at: point, clickCount: clickCount, modifiers: modifiers)
        }
        documentView = collection
        hasVerticalScroller = style == .grid
        autohidesScrollers = true
    }

    var background: NSColor = .windowBackgroundColor {
        didSet {
            backgroundColor = background
            collection.backgroundColors = [background]
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Reloads only when the list changed; otherwise just moves the highlight.
    func update(gallery: Gallery, folders newFolders: [URL] = [], labels newLabels: [URL: PhotoLabels],
                labelsRevision newLabelsRevision: Int) {
        labels = newLabels
        if gallery.revision != revision || newFolders != folders || newLabelsRevision != labelsRevision {
            revision = gallery.revision
            labelsRevision = newLabelsRevision
            items = gallery.items
            folders = style == .grid ? newFolders : []
            currentIndex = gallery.currentIndex
            selection = gallery.selection
            collection.reloadData()
        } else {
            let toggled = selection.symmetricDifference(gallery.selection).compactMap(gallery.index(of:))
            let changed = Set([currentIndex, gallery.currentIndex] + toggled)
            currentIndex = gallery.currentIndex
            selection = gallery.selection
            for index in changed where items.indices.contains(index) {
                (collection.item(at: photoPath(index)) as? ThumbnailTile)?.setHighlight(highlight(for: index))
            }
        }
        scrollToCurrent()
    }

    /// Brings the current photo into view, centring it only if it was out of sight,
    /// so stepping through a visible row doesn't make the grid jump.
    func scrollToCurrent() {
        guard items.indices.contains(currentIndex) else { return }
        collection.layoutSubtreeIfNeeded()
        let path = photoPath(currentIndex)
        guard let frame = collection.layoutAttributesForItem(at: path)?.frame else { return }
        if !contentView.documentVisibleRect.contains(frame) {
            collection.scrollToItems(at: [path], scrollPosition: style == .grid ? .centeredVertically : .centeredHorizontally)
        }
    }

    func setTileSize(_ size: CGFloat) {
        tileSize = min(max(size, 80), 400)
        collection.collectionViewLayout?.invalidateLayout()
        scrollToCurrent()
    }

    /// How many photos fit in one grid row: Up and Down move by this much.
    var columns: Int {
        let usable = contentSize.width - 28 + 10
        return max(Int(usable / (tileSize + 10)), 1)
    }

    private func photoPath(_ index: Int) -> IndexPath {
        IndexPath(item: index, section: 1)
    }

    private func highlight(for index: Int) -> ThumbnailTile.Highlight {
        if index == currentIndex { return .current }
        return selection.contains(items[index].url) ? .selected : .none
    }

    private func handleClick(at point: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        guard let path = collection.indexPathForItem(at: point) else { return }
        if path.section == 0 {
            if clickCount == 2 { delegate?.grid(self, didOpenFolder: folders[path.item]) }
            return
        }
        if clickCount == 2 {
            delegate?.grid(self, didOpenPhotoAt: path.item)
        } else {
            delegate?.grid(self, didClickPhotoAt: path.item,
                           extendingSelection: modifiers.contains(.shift) || modifiers.contains(.command))
        }
    }

    // MARK: - Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 2 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? folders.count : items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: ThumbnailTile.identifier, for: indexPath) as! ThumbnailTile
        tile.showsName = style == .grid
        tile.fillsTile = style == .strip
        if indexPath.section == 0 {
            tile.showFolder(folders[indexPath.item])
        } else {
            let item = items[indexPath.item]
            tile.showPhoto(item, labels: labels[item.url] ?? PhotoLabels())
            tile.setHighlight(highlight(for: indexPath.item))
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        switch style {
        case .grid: NSSize(width: tileSize, height: tileSize + 22)
        case .strip: NSSize(width: Self.stripHeight - 12, height: Self.stripHeight - 12)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? ThumbnailTile)?.stopLoading()
    }
}

/// Reports clicks with their position instead of using NSCollectionView's own selection,
/// which would compete with the gallery's.
private final class GridCollectionView: NSCollectionView {
    var onClick: ((NSPoint, Int, NSEvent.ModifierFlags) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), event.clickCount, event.modifierFlags)
    }

    override var acceptsFirstResponder: Bool { false }
}

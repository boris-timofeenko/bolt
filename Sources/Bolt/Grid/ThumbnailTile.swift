import AppKit
import BoltCore

/// One cell of the grid or strip: the thumbnail, and in the grid the file name under it.
final class ThumbnailTile: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailTile")

    enum Highlight {
        case none, selected, current
    }

    var showsName = true
    /// The strip crops to squares; the grid shows whole photos.
    var fillsTile = false

    private let imageLayer = CALayer()
    private let frameLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private var item: PhotoItem?

    override func loadView() {
        view = TileView()
        view.wantsLayer = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        imageLayer.masksToBounds = true
        frameLayer.cornerRadius = 4
        frameLayer.borderWidth = 0
        frameLayer.actions = ["borderWidth": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull()]
        view.layer?.addSublayer(frameLayer)
        view.layer?.addSublayer(imageLayer)

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        view.addSubview(nameLabel)
        (view as? TileView)?.onLayout = { [weak self] in self?.layoutTile() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopLoading()
        imageLayer.contents = nil
        setHighlight(.none)
    }

    func stopLoading() {
        if let item { ThumbnailLoader.shared.cancel(item) }
        item = nil
    }

    func showPhoto(_ newItem: PhotoItem, labels: PhotoLabels) {
        item = newItem
        let name = NSMutableAttributedString(attributedString: labels.badge(font: nameLabel.font ?? .systemFont(ofSize: 11)))
        name.append(NSAttributedString(string: newItem.name, attributes: [.font: nameLabel.font ?? .systemFont(ofSize: 11),
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingMiddle
        name.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: name.length))
        nameLabel.attributedStringValue = name
        nameLabel.isHidden = !showsName
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(newItem.name)
        // Rejected photos fade back, like in Lightroom.
        imageLayer.opacity = labels.flag == .reject ? 0.35 : 1
        imageLayer.contentsGravity = fillsTile ? .resizeAspectFill : .resizeAspect
        let image = ThumbnailLoader.shared.image(for: newItem) { [weak self] image in
            guard let self, self.item == newItem else { return }
            self.imageLayer.contents = image
        }
        imageLayer.contents = image
        layoutTile()
    }

    func showFolder(_ url: URL) {
        item = nil
        imageLayer.opacity = 1
        nameLabel.stringValue = url.lastPathComponent
        nameLabel.isHidden = false
        imageLayer.contentsGravity = .resizeAspect
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        imageLayer.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layoutTile()
    }

    func setHighlight(_ highlight: Highlight) {
        // A thin accent frame for the current photo, a tint for the rest of the selection.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            frameLayer.borderWidth = highlight == .current ? 2 : 0
            frameLayer.borderColor = accent.cgColor
            frameLayer.backgroundColor = highlight == .none ? nil : accent.withAlphaComponent(0.25).cgColor
        }
    }

    private func layoutTile() {
        let bounds = view.bounds
        let nameHeight: CGFloat = showsName && !nameLabel.isHidden ? 18 : 0
        let imageArea = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - nameHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = imageArea
        imageLayer.frame = imageArea.insetBy(dx: 4, dy: 4)
        CATransaction.commit()
        nameLabel.frame = NSRect(x: 2, y: bounds.height - nameHeight, width: bounds.width - 4, height: nameHeight)
    }
}

private final class TileView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

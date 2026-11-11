import AppKit
import BoltCore

@MainActor
protocol CompareViewDelegate: AnyObject {
    func compareView(_ view: CompareView, didActivate index: Int)
    /// Zoom changed: update the status bar and fetch sharper frames if the panes need them.
    func compareViewDidChangeViewport(_ view: CompareView)
}

/// Two to four photos side by side. Zoom and pan in any pane apply to all of them,
/// so the same spot of every frame in a burst can be checked for sharpness.
final class CompareView: NSView, ImageCanvasDelegate {
    weak var delegate: CompareViewDelegate?

    private(set) var urls: [URL] = []
    private(set) var active = 0
    private var panes: [ImageCanvasView] = []
    private var captions: [NSTextField] = []
    private var isSyncing = false

    var background: NSColor = .windowBackgroundColor {
        didSet { panes.forEach { $0.background = background } }
    }

    override var isFlipped: Bool { true }

    func setPhotos(_ newURLs: [URL], active newActive: Int) {
        if newURLs != urls {
            urls = newURLs
            panes.forEach { $0.removeFromSuperview() }
            captions.forEach { $0.removeFromSuperview() }
            panes = newURLs.map { _ in
                let pane = ImageCanvasView()
                pane.delegate = self
                pane.background = background
                pane.wantsLayer = true
                pane.layer?.borderWidth = 0
                addSubview(pane)
                return pane
            }
            captions = newURLs.map { url in
                let caption = NSTextField(labelWithString: url.lastPathComponent)
                caption.font = .systemFont(ofSize: 11, weight: .medium)
                caption.textColor = .white
                caption.drawsBackground = true
                caption.backgroundColor = NSColor.black.withAlphaComponent(0.55)
                addSubview(caption)
                return caption
            }
            needsLayout = true
        }
        active = min(newActive, max(urls.count - 1, 0))
        for (index, pane) in panes.enumerated() {
            pane.layer?.borderWidth = index == active && panes.count > 1 ? 2 : 0
            pane.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    func show(_ frame: DecodedFrame, for url: URL) {
        guard let index = urls.firstIndex(of: url) else { return }
        let pane = panes[index]
        if pane.currentURL != url || frame.isSharper(than: pane.currentFrame) {
            pane.show(frame, for: url)
        }
    }

    func showMessage(_ text: String, for url: URL) {
        guard let index = urls.firstIndex(of: url) else { return }
        panes[index].showMessage(text, for: url)
    }

    /// URLs whose pane is blurrier than the screen at the current zoom.
    var urlsNeedingSharperFrames: [URL] {
        zip(urls, panes).filter { $0.1.needsSharperFrame }.map(\.0)
    }

    var activePane: ImageCanvasView? {
        panes.indices.contains(active) ? panes[active] : nil
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let count = panes.count
        guard count > 0 else { return }
        let columns = count == 4 ? 2 : count
        let rows = count == 4 ? 2 : 1
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (index, pane) in panes.enumerated() {
            let column = index % columns
            let row = index / columns
            pane.frame = NSRect(x: CGFloat(column) * (width + gap), y: CGFloat(row) * (height + gap),
                                width: width, height: height)
            let caption = captions[index]
            let size = caption.intrinsicContentSize
            caption.frame = NSRect(x: pane.frame.minX + 8, y: pane.frame.minY + 8, width: size.width + 8, height: size.height)
        }
    }

    // MARK: - Panes

    func canvasWasClicked(_ canvas: ImageCanvasView) {
        guard let index = panes.firstIndex(where: { $0 === canvas }), index != active else { return }
        delegate?.compareView(self, didActivate: index)
    }

    func canvas(_ canvas: ImageCanvasView, navigateBy delta: Int) {
        let index = min(max(active + delta, 0), panes.count - 1)
        if index != active { delegate?.compareView(self, didActivate: index) }
    }

    /// One pane zoomed or panned: the rest follow.
    func canvasViewportDidChange(_ canvas: ImageCanvasView) {
        guard !isSyncing else { return }
        isSyncing = true
        for pane in panes where pane !== canvas { pane.viewport = canvas.viewport }
        isSyncing = false
        delegate?.compareViewDidChangeViewport(self)
    }

    func canvasContextMenu(_ canvas: ImageCanvasView) -> NSMenu? {
        nil
    }
}

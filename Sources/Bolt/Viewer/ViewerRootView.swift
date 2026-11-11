import AppKit

@MainActor
protocol ViewerRootViewDelegate: AnyObject {
    func rootView(_ view: ViewerRootView, didReceive urls: [URL])
}

/// Lays out the photo, the status bar and whatever floats above them, and accepts dropped files.
final class ViewerRootView: NSView {
    weak var delegate: ViewerRootViewDelegate?

    let canvas = ImageCanvasView()
    let grid = PhotoGridView(style: .grid)
    let strip = PhotoGridView(style: .strip)
    let info = InfoPanelView()
    let compare = CompareView()
    let statusBar = StatusBarView()
    let toast = ToastView()
    private let performanceLabel = NSTextField(labelWithString: "")

    var showsStatusBar = true {
        didSet { needsLayout = true }
    }
    /// The grid replaces the photo; the strip sits under it.
    var showsGrid = false {
        didSet { needsLayout = true }
    }
    var showsStrip = false {
        didSet { needsLayout = true }
    }
    var showsInfo = false {
        didSet { needsLayout = true }
    }
    /// The comparison replaces the single photo.
    var showsCompare = false {
        didSet { needsLayout = true }
    }
    /// Shows the status bar even when the interface is hidden, e.g. while renaming in full screen.
    var forceStatusBar = false {
        didSet { needsLayout = true }
    }
    /// A full-size layer over the photo, such as the shortcut sheet.
    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay, positioned: .below, relativeTo: toast) }
            needsLayout = true
        }
    }
    var performanceText: String? {
        didSet {
            performanceLabel.stringValue = performanceText ?? ""
            performanceLabel.isHidden = performanceText == nil
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(canvas)
        addSubview(grid)
        addSubview(strip)
        addSubview(info)
        addSubview(compare)
        addSubview(statusBar)
        addSubview(performanceLabel)
        addSubview(toast)

        performanceLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        performanceLabel.textColor = .white
        performanceLabel.drawsBackground = true
        performanceLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        performanceLabel.isHidden = true
        performanceLabel.maximumNumberOfLines = 0

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let barVisible = showsStatusBar || forceStatusBar
        let barHeight = barVisible ? StatusBarView.height : 0
        statusBar.isHidden = !barVisible
        let infoWidth = showsInfo ? InfoPanelView.width : 0
        info.isHidden = !showsInfo
        info.frame = NSRect(x: bounds.width - infoWidth, y: 0, width: InfoPanelView.width, height: bounds.height - barHeight)
        let content = NSRect(x: 0, y: 0, width: bounds.width - infoWidth, height: bounds.height - barHeight)
        let stripHeight = showsStrip && !showsGrid ? PhotoGridView.stripHeight : 0
        grid.isHidden = !showsGrid
        canvas.isHidden = showsGrid || showsCompare
        compare.isHidden = showsGrid || !showsCompare
        strip.isHidden = stripHeight == 0
        grid.frame = content
        canvas.frame = NSRect(x: 0, y: 0, width: content.width, height: content.height - stripHeight)
        compare.frame = canvas.frame
        strip.frame = NSRect(x: 0, y: content.maxY - stripHeight, width: content.width, height: PhotoGridView.stripHeight)
        statusBar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: StatusBarView.height)
        // Overlays cover the photo; in the grid there's no photo, so they take the whole area.
        overlay?.frame = showsGrid ? content : canvas.frame
        toast.place(in: showsGrid ? content : canvas.frame)
        let size = performanceLabel.sizeThatFits(NSSize(width: 400, height: 200))
        performanceLabel.frame = NSRect(x: 8, y: 8, width: size.width + 6, height: size.height + 4)
        for case let picker as QuickPicker in subviews { picker.layoutInContainer() }
    }

    // MARK: - Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A photo dragged out of this window and dropped back is not a request to open it.
        guard sender.draggingSource as? ImageCanvasView !== canvas, !fileURLs(from: sender).isEmpty else { return [] }
        return .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        delegate?.rootView(self, didReceive: urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

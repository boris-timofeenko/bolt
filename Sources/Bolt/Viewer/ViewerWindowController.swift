import AppKit
import AVKit
import BoltCore
import os

/// One viewer window: a folder, the photo on screen, and everything the keys do to it.
///
/// Display path: a key press moves `gallery`, `displayCurrent` puts the best cached frame on the layer
/// (or the embedded preview), and `scheduleFrames` asks the loader for the current photo and its
/// neighbours. Decoded frames come back through `frameDidArrive`.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let gallery = Gallery()
    let session: Session
    let loader: FrameLoader
    let root = ViewerRootView()

    var canvas: ImageCanvasView { root.canvas }
    var statusBar: StatusBarView { root.statusBar }

    /// +1 when moving forward, -1 backward. Decides prefetch direction and which photo follows a deletion.
    var direction = 1
    var lastRepeatable: Command?
    var fullscreenWindow: NSWindow?
    var interfaceHidden = false
    var showsPerformance = false
    var picker: QuickPicker?
    var cheatSheet: CheatSheetView?
    /// Folder tiles at the top of the grid.
    var subfolders: [URL] = []
    var labels: [URL: PhotoLabels] = [:]
    /// Bumped on every label change, so the grid knows to redraw badges.
    var labelsRevision = 0
    var labelFilter = LabelFilter.all
    /// Photos in the side-by-side comparison, in the order they were added.
    var compareURLs: [URL] = []
    var batchJob: BatchJob?
    /// The crop frame on screen and the photo it was drawn for.
    var crop: CropSession?
    var slideshowTimer: Timer?
    var infoPanelUpdatePending = false
    var playerView: AVPlayerView?
    var livePhotoLayer: AVPlayerLayer?

    private var isFolderLocal = true
    private var watcher: FolderWatcher?
    private var settleWork: DispatchWorkItem?
    private var scanGeneration = 0
    /// Main-thread time of the last photo change, for the speed overlay.
    private(set) var lastDisplayDuration: Duration = .zero
    private let signposter = OSSignposter(subsystem: "org.boltviewer.Bolt", category: "Display")

    init(session: Session) {
        self.session = session
        loader = FrameLoader(budget: Preferences.cacheBytes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 300)
        // Our own full screen: the native one slides into a new Space, which is slow.
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "Bolt"
        window.contentView = root
        super.init(window: window)
        window.delegate = self

        canvas.delegate = self
        root.delegate = self
        root.grid.delegate = self
        root.strip.delegate = self
        root.compare.delegate = self
        statusBar.onSortClick = { [weak self] view in self?.showSortMenu(from: view) }
        loader.onFrame = { [weak self] url, frame in self?.frameDidArrive(url, frame) }
        loader.onFailure = { [weak self] url in self?.frameDidFail(url) }
        gallery.sort(by: Preferences.sortOrder)
        applyPreferences()
        displayCurrent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// True for both the normal window and the full-screen one.
    func owns(_ window: NSWindow?) -> Bool {
        window != nil && (window === self.window || window === fullscreenWindow)
    }

    var visibleWindow: NSWindow? { fullscreenWindow ?? window }

    // MARK: - Opening

    /// Opens a photo (its whole folder, starting at it) or a folder (from the first photo).
    func open(_ url: URL) {
        let isFolder = url.isFolder
        let folder = isFolder ? url : url.deletingLastPathComponent()
        let focus = isFolder ? nil : url
        if folder != gallery.folder {
            loader.clear()
            labels = [:]
            labelFilter = .all
            gallery.setFilter(nil)
        }

        // Show the photo first, read the folder after: a big folder must not delay the first frame.
        if let focus, let item = PhotoItem(url: focus) {
            gallery.load([item], folder: folder, focus: focus)
        } else {
            gallery.load([], folder: folder, focus: nil)
        }
        direction = 1
        displayCurrent()
        scanFolder(folder, focus: focus)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func scanFolder(_ folder: URL, focus: URL?) {
        scanGeneration += 1
        let generation = scanGeneration
        inBackground({
            (listing: Result { try FolderScanner.photos(in: folder) },
             isLocal: (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true)
        }, then: { controller, scan in
            // A newer scan (another folder, a later rescan) wins.
            guard controller.scanGeneration == generation else { return }
            controller.folderDidLoad(folder, result: scan.listing, focus: focus, isLocal: scan.isLocal)
        })
    }

    private func folderDidLoad(_ folder: URL, result: Result<[PhotoItem], any Error>, focus: URL?, isLocal: Bool) {
        isFolderLocal = isLocal
        switch result {
        case .success(let items) where gallery.folder == folder && !gallery.isEmpty && focus == nil:
            // A rescan of the folder already on screen: merge, don't reload.
            let result = gallery.merge(items)
            (result.changed + result.added + result.removed).forEach(loader.invalidate)
            if !result.added.isEmpty { loadLabels() }
            if !result.isEmpty { displayCurrent() }
        case .success(let items):
            gallery.load(items, folder: folder, focus: gallery.current?.url ?? focus)
            watcher = FolderWatcher(folder: folder) { [weak self] in self?.rescan() }
            if showsGrid { subfolders = FolderScanner.subfolders(of: folder) }
            if gallery.order.key == .dateTaken { loadCaptureDates() }
            loadLabels()
            displayCurrent()
        case .failure(let error):
            showToast(L("Can't read the folder: %@", error.localizedDescription), isError: true)
            displayCurrent()
        }
    }

    /// Re-reads the folder after the watcher saw files come or go.
    func rescan() {
        guard let folder = gallery.folder else { return }
        scanFolder(folder, focus: nil)
    }

    /// EXIF dates are read only when sorting needs them; a plain listing never opens the files.
    func loadCaptureDates() {
        let urls = gallery.items.map(\.url).filter { gallery.captureDates[$0] == nil }
        guard !urls.isEmpty, let folder = gallery.folder else { return }
        inBackground(qos: .utility, { ImageDecoder.captureDates(of: urls) }, then: { controller, dates in
            guard controller.gallery.folder == folder else { return }
            controller.gallery.updateCaptureDates(dates)
            controller.displayCurrent()
        })
    }

    /// Does `work` off the main thread and hands the result back on it, unless the window closed meanwhile.
    func inBackground<Result: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                        _ work: @escaping @Sendable () -> Result,
                                        then finish: @escaping @MainActor (ViewerWindowController, Result) -> Void) {
        DispatchQueue.global(qos: qos).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self { finish(self, result) }
                }
            }
        }
    }

    // MARK: - Display

    func displayCurrent(fastScroll: Bool = false) {
        measureDisplay {
            cancelCropIfAnotherPhoto()
            stopLivePhoto()
            defer { updateVideoPlayer() }
            // The grid shows thumbnails; frames are decoded once a photo is opened.
            if showsGrid { return }
            if showsCompare {
                displayComparison()
                return
            }
            guard let item = gallery.current else {
                showEmptyState()
                return
            }
            showBestFrame(for: item)
            if fastScroll {
                scheduleAfterFastScroll()
            } else {
                scheduleFrames()
            }
        }
    }

    /// Times the display path for the speed overlay and Instruments, then refreshes the chrome.
    private func measureDisplay(_ body: () -> Void) {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("display")
        body()
        signposter.endInterval("display", state)
        lastDisplayDuration = start.duration(to: .now)
        updateChrome()
    }

    /// The sharpest frame already decoded, else the embedded preview read right now, else blank until one arrives.
    private func showBestFrame(for item: PhotoItem) {
        let url = item.url
        if let frame = loader.bestFrame(for: url) {
            canvas.show(frame, for: url)
        } else if loader.hasFailed(url) {
            canvas.showMessage(L("Can't open “%@”", item.name), for: url)
        } else if isFolderLocal, let preview = loader.previewNow(url) {
            canvas.show(preview, for: url)
        } else {
            canvas.showLoading(for: url)
        }
    }

    private func showEmptyState() {
        loader.schedule([])
        canvas.showMessage(gallery.folder == nil ? L("Drop a photo or a folder here, or press ⌘O")
                                                 : L("No photos in this folder"), for: nil)
    }

    /// Asks for the current photo and its neighbours, most urgent first. Replaces the previous request.
    func scheduleFrames() {
        settleWork?.cancel()
        settleWork = nil
        guard !gallery.isEmpty else { return }
        let plan = PrefetchPlan.indices(around: gallery.currentIndex, count: gallery.count, direction: direction)
        let priorities: [FrameLoader.Priority] = [.current, .next, .previous]
        var wanted = plan.enumerated().map { rank, index in
            (FrameLoader.Request(url: gallery.items[index].url, kind: .screen),
             rank < priorities.count ? priorities[rank] : .background)
        }
        if case .fit = canvas.viewport.mode {} else {
            // Zoomed in, e.g. checking sharpness across a burst: have the next photo's pixels ready too.
            if canvas.needsSharperFrame, let url = gallery.current?.url {
                wanted.insert((FrameLoader.Request(url: url, kind: .full), .current), at: 1)
            }
            if plan.count > 1 {
                wanted.append((FrameLoader.Request(url: gallery.items[plan[1]].url, kind: .full), .background))
            }
        }
        loader.schedule(wanted)
        loader.retain(around: Set(retentionWindow()))
    }

    /// Frames worth keeping: a little more than the prefetch window, so stepping back a few photos is free
    /// without holding the whole folder in memory.
    private func retentionWindow() -> [URL] {
        let lower = max(gallery.currentIndex - 8, 0)
        let upper = min(gallery.currentIndex + 12, gallery.count - 1)
        guard lower <= upper else { return [] }
        return gallery.items[lower...upper].map(\.url)
    }

    /// While an arrow key is held only embedded previews are shown, read a few photos ahead, so no backlog
    /// builds up. Real decoding starts when the key is released (`finishFastScroll`), or 80 ms after the
    /// last repeat if the release never comes.
    private func scheduleAfterFastScroll() {
        let ahead = (1...8).map { gallery.currentIndex + direction * $0 }.filter { gallery.items.indices.contains($0) }
        loader.schedule(ahead.map { (FrameLoader.Request(url: gallery.items[$0].url, kind: .preview), .next) })
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduleFrames() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// The held key was released: decode the photo it stopped on now instead of waiting out the pause.
    func finishFastScroll() {
        guard settleWork != nil else { return }
        scheduleFrames()
    }

    private func frameDidArrive(_ url: URL, _ frame: DecodedFrame) {
        if showsCompare {
            root.compare.show(frame, for: url)
            return
        }
        guard url == gallery.current?.url else { return }
        if canvas.currentURL != url || frame.isSharper(than: canvas.currentFrame) {
            canvas.show(frame, for: url)
            updateChrome()
        }
    }

    /// Zooming past what the screen-sized frame can show asks for the full image.
    /// Not while an arrow key is held: then only previews are wanted.
    fileprivate func requestSharperFrameIfNeeded() {
        if canvas.needsSharperFrame, settleWork == nil { scheduleFrames() }
    }

    private func frameDidFail(_ url: URL) {
        if showsCompare {
            root.compare.showMessage(L("Can't open “%@”", url.lastPathComponent), for: url)
            return
        }
        guard url == gallery.current?.url, canvas.currentFrame == nil || canvas.currentURL != url else { return }
        canvas.showMessage(L("Can't open “%@”", url.lastPathComponent), for: url)
        updateChrome()
    }

    // MARK: - Navigation

    func go(by delta: Int, isRepeat: Bool = false) {
        direction = delta < 0 ? -1 : 1
        gallery.clearSelection()
        guard gallery.step(by: delta) else {
            updateChrome()
            return
        }
        hideCursorInFullscreen()
        displayCurrent(fastScroll: isRepeat)
    }

    func go(to index: Int) {
        direction = index >= gallery.currentIndex ? 1 : -1
        gallery.clearSelection()
        if gallery.move(to: index) { displayCurrent() }
    }

    func extendSelection(by delta: Int) {
        direction = delta < 0 ? -1 : 1
        gallery.extendSelection(by: delta)
        displayCurrent()
    }

    /// Cmd+arrows: the neighbouring folder with photos in it, in Finder order.
    func openSiblingFolder(_ delta: Int) {
        guard let folder = gallery.folder?.standardizedFileURL else { return }
        let siblings = FolderScanner.subfolders(of: folder.deletingLastPathComponent())
        guard var index = siblings.firstIndex(where: { $0.isSameLocation(as: folder) }) else { return }
        while true {
            index += delta
            guard siblings.indices.contains(index) else {
                showToast(delta > 0 ? L("No more folders after this one") : L("No folders before this one"))
                return
            }
            if let photos = try? FolderScanner.photos(in: siblings[index]), !photos.isEmpty {
                open(siblings[index])
                showToast(siblings[index].lastPathComponent)
                return
            }
        }
    }

    // MARK: - Sorting

    func setSort(_ key: SortKey) {
        var order = gallery.order
        if order.key == key { return }
        order.key = key
        applySort(order)
    }

    func reverseSort() {
        var order = gallery.order
        order.ascending.toggle()
        applySort(order)
    }

    private func applySort(_ order: Sorting) {
        Preferences.sortOrder = order
        gallery.sort(by: order)
        if order.key == .dateTaken { loadCaptureDates() }
        displayCurrent()
    }

    // MARK: - Preferences

    func applyPreferences() {
        canvas.background = Preferences.background.color
        root.compare.background = Preferences.background.color
        root.grid.background = Preferences.background.color
        root.strip.background = Preferences.background.color
        loader.setBudget(Preferences.cacheBytes)
        applyChromeVisibility()
    }

    func trimMemory() {
        let around = PrefetchPlan.indices(around: gallery.currentIndex, count: gallery.count, direction: direction,
                                          ahead: 1, behind: 1)
        loader.trim(keeping: Set(around.map { gallery.items[$0].url }))
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        loader.clear()
        removeVideoPlayer()
        session.windowDidClose(self)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateScreenTarget()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateScreenTarget()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateScreenTarget()
        window?.makeFirstResponder(canvas)
    }

    /// Frames are decoded for the whole screen, so resizing the window or going full screen costs nothing.
    func updateScreenTarget() {
        guard let screen = visibleWindow?.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let target = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        loader.decodesHDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        guard target != loader.screenTarget else { return }
        loader.screenTarget = target
        scheduleFrames()
    }
}

extension ViewerWindowController: ImageCanvasDelegate {
    func canvas(_ canvas: ImageCanvasView, navigateBy delta: Int) {
        go(by: delta)
    }

    func canvasViewportDidChange(_ canvas: ImageCanvasView) {
        crop?.overlay.updateImageRect(canvas.imageFrame)
        updateChrome()
        requestSharperFrameIfNeeded()
    }

    func canvasContextMenu(_ canvas: ImageCanvasView) -> NSMenu? {
        guard gallery.current != nil else { return nil }
        return contextMenu()
    }
}

extension ViewerWindowController: ViewerRootViewDelegate {
    func rootView(_ view: ViewerRootView, didReceive urls: [URL]) {
        guard let first = urls.first else { return }
        open(first)
    }
}

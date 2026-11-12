import AppKit
import BoltCore

@MainActor
protocol ImageCanvasDelegate: AnyObject {
    func canvas(_ canvas: ImageCanvasView, navigateBy delta: Int)
    func canvasViewportDidChange(_ canvas: ImageCanvasView)
    func canvasContextMenu(_ canvas: ImageCanvasView) -> NSMenu?
    func canvasWasClicked(_ canvas: ImageCanvasView)
}

extension ImageCanvasDelegate {
    func canvasWasClicked(_ canvas: ImageCanvasView) {}
}

/// Shows one photo in a CALayer. Showing a new frame is a single `contents` swap with animations off;
/// nothing here decodes or draws pixels.
final class ImageCanvasView: NSView, NSDraggingSource {
    weak var delegate: ImageCanvasDelegate?

    private(set) var currentURL: URL?
    private(set) var currentFrame: DecodedFrame?
    var viewport = Viewport() {
        didSet { if viewport != oldValue { layoutImage() } }
    }
    var background: NSColor = .windowBackgroundColor {
        didSet { needsDisplay = true }
    }

    private let imageLayer = CALayer()
    private let messageLabel = NSTextField(labelWithString: "")

    private enum Drag {
        case none, pan, pendingFileDrag(NSPoint)
    }
    private var drag = Drag.none
    private var animationGeneration = 0
    private var swipeDistance: CGFloat = 0
    private var swipeHandled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.isHidden = true
        addSubview(messageLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateLayer() {
        layer?.backgroundColor = background.cgColor
    }

    // MARK: - Content

    var imageSize: CGSize { currentFrame?.info.pixelSize ?? .zero }
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Image pixels per screen pixel right now.
    var zoomRatio: Double {
        viewport.ratio(image: imageSize, view: bounds.size, backingScale: backingScale)
    }

    var fitRatio: Double {
        viewport.fitRatio(image: imageSize, view: bounds.size, backingScale: backingScale)
    }

    /// Where the image is drawn, in this view's coordinates.
    var imageFrame: CGRect {
        viewport.imageFrame(image: imageSize, view: bounds.size, backingScale: backingScale)
    }

    var imageOverflows: Bool {
        currentFrame != nil && viewport.overflows(image: imageSize, view: bounds.size, backingScale: backingScale)
    }

    /// True when the frame on screen is blurrier than the display at this zoom.
    var needsSharperFrame: Bool {
        guard let frame = currentFrame, !frame.isFullResolution else { return false }
        return max(imageFrame.width, imageFrame.height) * backingScale > CGFloat(frame.longSide) * 1.05
    }

    func show(_ newFrame: DecodedFrame, for newURL: URL) {
        PresentProbe.mark("show")
        if window?.isVisible == true { LaunchTimeline.frameShown(sharp: newFrame.kind != .preview) }
        currentURL = newURL
        currentFrame = newFrame
        messageLabel.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = newFrame.image
        imageLayer.isHidden = false
        setHighDynamicRange(newFrame.isHDR)
        placeImage()
        PresentProbe.presentMarker(in: layer)
        CATransaction.commit()
        // The photo goes to the window server in a commit of its own. The title, the status bar and whatever
        // else the delegate changes follow in the next one, a frame later at most: committed together, the
        // photo waited for their text to be laid out and drawn and usually missed a frame.
        // If something earlier in this event already opened an implicit transaction, the commit above only
        // nested in it; flushing sends the photo now anyway.
        if window?.isVisible == true { CATransaction.flush() }
        PresentProbe.mark("shown")
        setAccessibilityLabel(newURL.lastPathComponent)
        delegate?.canvasViewportDidChange(self)
        if newFrame.info.isAnimated, newFrame.kind != .preview {
            animate(newURL)
        } else {
            animationGeneration += 1
        }
    }

    private func setHighDynamicRange(_ enabled: Bool) {
        if #available(macOS 26, *) {
            imageLayer.preferredDynamicRange = enabled ? .high : .standard
        } else {
            imageLayer.wantsExtendedDynamicRangeContent = enabled
        }
    }

    /// Plays GIFs and other animations with ImageIO's own timing. Stops by itself when another photo shows up.
    private func animate(_ url: URL) {
        animationGeneration += 1
        let generation = animationGeneration
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation, self.currentURL == url else {
                    stop.pointee = true
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageLayer.contents = image
                CATransaction.commit()
            }
        }
    }

    /// Clears the image and shows a short line instead, e.g. for a file that can't be decoded.
    func showMessage(_ text: String, for newURL: URL?) {
        animationGeneration += 1
        currentURL = newURL
        currentFrame = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        imageLayer.isHidden = true
        CATransaction.commit()
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        layoutMessage()
    }

    /// Blank until the first frame of `newURL` arrives. Never leaves the previous photo up:
    /// pressing Delete on what looks like one photo must not trash another.
    func showLoading(for newURL: URL) {
        showMessage("", for: newURL)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutImage()
        layoutMessage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutImage()
    }

    private func layoutImage() {
        guard currentFrame != nil else { return }
        placeImage()
        delegate?.canvasViewportDidChange(self)
    }

    /// Size, position and filtering of the image layer for the current frame and viewport.
    private func placeImage() {
        guard let frame = currentFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = imageFrame
        imageLayer.frame = backingAligned(rect)
        imageLayer.contentsScale = backingScale
        // Past 150% show real pixels, not a smoothed guess: that's the point of checking sharpness.
        let screenPixelsPerBitmapPixel = rect.width * backingScale / CGFloat(frame.image.width)
        imageLayer.magnificationFilter = screenPixelsPerBitmapPixel > 1.5 && frame.isFullResolution ? .nearest : .linear
        CATransaction.commit()
    }

    private func backingAligned(_ rect: CGRect) -> CGRect {
        let scale = backingScale
        return CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
                      width: (rect.width * scale).rounded() / scale, height: (rect.height * scale).rounded() / scale)
    }

    private func layoutMessage() {
        let size = messageLabel.sizeThatFits(NSSize(width: bounds.width - 40, height: 200))
        messageLabel.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                    width: size.width, height: size.height)
    }

    // MARK: - Zoom

    /// Where zooming should centre: the cursor if it's over the view, the middle otherwise.
    var zoomAnchor: CGPoint {
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { return point }
        }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func zoom(to ratio: Double, anchor: CGPoint? = nil) {
        guard currentFrame != nil else { return }
        let limited = min(max(ratio, min(fitRatio, Viewport.zoomSteps[0])), Viewport.zoomSteps.last!)
        updateViewport {
            $0.zoom(to: limited, anchor: anchor ?? zoomAnchor, image: imageSize, view: bounds.size,
                    backingScale: backingScale)
        }
    }

    /// Z, double-click and the two-finger double tap: fit ⇄ 100% at the cursor.
    func toggleZoom(at anchor: CGPoint? = nil) {
        if case .fit = viewport.mode, abs(fitRatio - 1) > 0.01 {
            zoom(to: 1, anchor: anchor)
        } else {
            viewport = Viewport(mode: .fit)
        }
    }

    /// Changes the viewport in one go, so layout and the delegate see a single update.
    private func updateViewport(_ change: (inout Viewport) -> Void) {
        var updated = viewport
        change(&updated)
        viewport = updated
    }

    private func pan(by delta: CGSize) {
        updateViewport { $0.pan(by: delta, image: imageSize, view: bounds.size, backingScale: backingScale) }
    }

    func zoomStep(in zoomingIn: Bool) {
        zoom(to: Viewport.nextStep(after: zoomRatio, zoomingIn: zoomingIn))
    }

    // MARK: - Trackpad and mouse

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        zoom(to: zoomRatio * (1 + event.magnification), anchor: anchor)
        if event.phase == .ended, zoomRatio <= fitRatio * 1.01 {
            viewport = Viewport(mode: .fit)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            trackpadScroll(event)
        } else {
            mouseWheel(event)
        }
    }

    /// Two fingers pan a zoomed photo and flip through photos otherwise, one photo per swipe.
    private func trackpadScroll(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(to: zoomRatio * (1 + event.scrollingDeltaY / 200), anchor: convert(event.locationInWindow, from: nil))
            return
        }
        if imageOverflows {
            pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            return
        }
        if event.phase == .began {
            swipeDistance = 0
            swipeHandled = false
        }
        guard event.momentumPhase == [], !swipeHandled, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            return
        }
        swipeDistance += event.scrollingDeltaX
        guard abs(swipeDistance) > 40 else { return }
        swipeHandled = true
        // With natural scrolling the delta follows the fingers; fingers moving left means "next".
        let fingersMovedLeft = event.isDirectionInvertedFromDevice ? swipeDistance < 0 : swipeDistance > 0
        delegate?.canvas(self, navigateBy: fingersMovedLeft ? 1 : -1)
    }

    private func mouseWheel(_ event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        let wantsZoom = (Preferences.wheelAction == .zoom) != event.modifierFlags.contains(.command)
        if wantsZoom {
            zoom(to: Viewport.nextStep(after: zoomRatio, zoomingIn: delta > 0),
                 anchor: convert(event.locationInWindow, from: nil))
        } else {
            delegate?.canvas(self, navigateBy: delta > 0 ? -1 : 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        delegate?.canvasWasClicked(self)
        if event.clickCount == 2 {
            toggleZoom(at: convert(event.locationInWindow, from: nil))
            drag = .none
            return
        }
        if imageOverflows {
            drag = .pan
            NSCursor.closedHand.push()
        } else {
            drag = .pendingFileDrag(event.locationInWindow)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch drag {
        case .pan:
            pan(by: CGSize(width: event.deltaX, height: event.deltaY))
        case .pendingFileDrag(let start):
            let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
            if distance > 4 {
                drag = .none
                beginFileDrag(with: event)
            }
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .pan = drag { NSCursor.pop() }
        drag = .none
    }

    override func otherMouseDown(with event: NSEvent) {
        // Side buttons on most mice: 3 is back, 4 is forward.
        switch event.buttonNumber {
        case 3: delegate?.canvas(self, navigateBy: -1)
        case 4: delegate?.canvas(self, navigateBy: 1)
        default: super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.canvasContextMenu(self)
    }

    // MARK: - Dragging the file out

    private func beginFileDrag(with event: NSEvent) {
        guard let url = currentURL, let frame = currentFrame else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: frame.image, size: .zero)
        let longSide: CGFloat = 160
        let scale = longSide / max(CGFloat(frame.image.width), CGFloat(frame.image.height))
        let size = NSSize(width: CGFloat(frame.image.width) * scale, height: CGFloat(frame.image.height) * scale)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: if another app moved the file away, the list here would go stale.
        context == .outsideApplication ? .copy : []
    }
}

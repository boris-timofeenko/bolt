import AppKit
import Carbon.HIToolbox

@MainActor
protocol CropOverlayDelegate: AnyObject {
    func cropOverlay(_ overlay: CropOverlayView, didApply rect: CGRect)
    func cropOverlayDidCancel(_ overlay: CropOverlayView)
}

/// C: a crop frame over the photo. Return applies, Esc cancels, X turns the aspect ratio sideways.
/// The result is a rectangle in fractions of the displayed image, origin at the top left.
final class CropOverlayView: NSView {
    enum Aspect: Int, CaseIterable {
        case free, square, fourByFive, nineBySixteen, threeByTwo, original

        var title: String {
            switch self {
            case .free: L("Free")
            case .square: "1:1"
            case .fourByFive: "4:5"
            case .nineBySixteen: "9:16"
            case .threeByTwo: "3:2"
            case .original: L("Original")
            }
        }

        /// Width over height in pixels, before the portrait/landscape swap.
        func ratio(for imageSize: CGSize) -> CGFloat? {
            switch self {
            case .free: nil
            case .square: 1
            case .fourByFive: 4.0 / 5
            case .nineBySixteen: 9.0 / 16
            case .threeByTwo: 3.0 / 2
            case .original: imageSize.width / imageSize.height
            }
        }
    }

    private enum Handle {
        case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right
    }

    weak var delegate: CropOverlayDelegate?

    /// Where the image sits in this view, and its size in pixels for aspect ratios.
    private var imageRect: CGRect = .zero
    private var imageSize: CGSize = .zero
    private var crop: CGRect = .zero
    private var aspect = Aspect.free
    private var swapped = false
    private var handle: Handle?
    private var dragStart: CGPoint = .zero
    private var cropAtDragStart: CGRect = .zero

    private let aspectControl = NSSegmentedControl()
    private let hint = NSTextField(labelWithString: L("↩ Crop   Esc Cancel   X Rotate frame"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        aspectControl.segmentCount = Aspect.allCases.count
        for aspect in Aspect.allCases {
            aspectControl.setLabel(aspect.title, forSegment: aspect.rawValue)
            aspectControl.setWidth(0, forSegment: aspect.rawValue)
        }
        aspectControl.selectedSegment = 0
        aspectControl.target = self
        aspectControl.action = #selector(aspectChanged)
        aspectControl.controlSize = .small
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .white
        addSubview(aspectControl)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Starts with the whole image selected.
    func begin(imageRect rect: CGRect, imageSize size: CGSize) {
        imageRect = rect
        imageSize = size
        crop = rect
        needsDisplay = true
    }

    /// The window resized: keep the same part of the image selected.
    func updateImageRect(_ rect: CGRect) {
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        let fraction = normalizedCrop
        imageRect = rect
        crop = CGRect(x: rect.minX + fraction.minX * rect.width, y: rect.minY + fraction.minY * rect.height,
                      width: fraction.width * rect.width, height: fraction.height * rect.height)
        needsDisplay = true
    }

    var normalizedCrop: CGRect {
        CGRect(x: (crop.minX - imageRect.minX) / imageRect.width, y: (crop.minY - imageRect.minY) / imageRect.height,
               width: crop.width / imageRect.width, height: crop.height / imageRect.height)
    }

    override func layout() {
        super.layout()
        let size = aspectControl.fittingSize
        aspectControl.frame = NSRect(x: (bounds.width - size.width) / 2, y: 12, width: size.width, height: size.height)
        let hintSize = hint.intrinsicContentSize
        hint.frame = NSRect(x: (bounds.width - hintSize.width) / 2, y: bounds.height - hintSize.height - 12,
                            width: hintSize.width, height: hintSize.height)
    }

    // MARK: - Keys

    /// Return, Esc and X belong to the crop while it's open; everything else is ignored.
    func handleKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: delegate?.cropOverlay(self, didApply: normalizedCrop)
        case kVK_Escape: delegate?.cropOverlayDidCancel(self)
        case kVK_ANSI_X:
            swapped.toggle()
            applyAspect()
        default: break
        }
    }

    @objc private func aspectChanged() {
        aspect = Aspect(rawValue: aspectControl.selectedSegment) ?? .free
        applyAspect()
    }

    /// Width over height in pixels, or nil for a free frame.
    private var ratio: CGFloat? {
        guard let ratio = aspect.ratio(for: imageSize) else { return nil }
        return swapped ? 1 / ratio : ratio
    }

    /// The same proportion in view points, which is what the frame is drawn in.
    private var viewRatio: CGFloat? {
        guard let ratio, imageSize.width > 0, imageSize.height > 0 else { return nil }
        return ratio * (imageRect.width / imageSize.width) / (imageRect.height / imageSize.height)
    }

    /// Fits the largest frame of the chosen proportions around the current frame's centre.
    private func applyAspect() {
        guard let viewRatio else {
            needsDisplay = true
            return
        }
        var width = imageRect.width
        var height = width / viewRatio
        if height > imageRect.height {
            height = imageRect.height
            width = height * viewRatio
        }
        let center = CGPoint(x: crop.midX, y: crop.midY)
        crop = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        crop.origin.x = min(max(crop.minX, imageRect.minX), imageRect.maxX - width)
        crop.origin.y = min(max(crop.minY, imageRect.minY), imageRect.maxY - height)
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handle = handle(at: point)
        dragStart = point
        cropAtDragStart = crop
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        var rect = cropAtDragStart
        let minimum: CGFloat = 24

        switch handle {
        case .move:
            rect.origin.x = min(max(rect.minX + dx, imageRect.minX), imageRect.maxX - rect.width)
            rect.origin.y = min(max(rect.minY + dy, imageRect.minY), imageRect.maxY - rect.height)
        default:
            var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
            if [.topLeft, .bottomLeft, .left].contains(handle) { left = min(max(left + dx, imageRect.minX), right - minimum) }
            if [.topRight, .bottomRight, .right].contains(handle) { right = max(min(right + dx, imageRect.maxX), left + minimum) }
            if [.topLeft, .topRight, .top].contains(handle) { top = min(max(top + dy, imageRect.minY), bottom - minimum) }
            if [.bottomLeft, .bottomRight, .bottom].contains(handle) { bottom = max(min(bottom + dy, imageRect.maxY), top + minimum) }
            rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            if let viewRatio { rect = constrained(rect, to: viewRatio, anchor: handle) }
        }
        crop = rect
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        handle = nil
    }

    /// Keeps the proportions by shrinking whichever side overshoots, pinned at the corner opposite the drag.
    private func constrained(_ rect: CGRect, to viewRatio: CGFloat, anchor: Handle) -> CGRect {
        var width = rect.width
        var height = rect.height
        if width / height > viewRatio { width = height * viewRatio } else { height = width / viewRatio }
        let pinRight = [.topLeft, .bottomLeft, .left].contains(anchor)
        let pinBottom = [.topLeft, .topRight, .top].contains(anchor)
        return CGRect(x: pinRight ? rect.maxX - width : rect.minX, y: pinBottom ? rect.maxY - height : rect.minY,
                      width: width, height: height)
    }

    private func handle(at point: CGPoint) -> Handle? {
        let reach: CGFloat = 12
        let nearLeft = abs(point.x - crop.minX) < reach, nearRight = abs(point.x - crop.maxX) < reach
        let nearTop = abs(point.y - crop.minY) < reach, nearBottom = abs(point.y - crop.maxY) < reach
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        // With fixed proportions only corners resize; edges would have to move two sides at once.
        if ratio == nil, crop.insetBy(dx: -reach, dy: -reach).contains(point) {
            if nearLeft { return .left }
            if nearRight { return .right }
            if nearTop { return .top }
            if nearBottom { return .bottom }
        }
        return crop.contains(point) ? .move : nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: crop))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        outside.fill()

        NSColor.white.withAlphaComponent(0.35).setStroke()
        let thirds = NSBezierPath()
        for step in 1...2 {
            let x = crop.minX + crop.width * CGFloat(step) / 3
            let y = crop.minY + crop.height * CGFloat(step) / 3
            thirds.move(to: CGPoint(x: x, y: crop.minY))
            thirds.line(to: CGPoint(x: x, y: crop.maxY))
            thirds.move(to: CGPoint(x: crop.minX, y: y))
            thirds.line(to: CGPoint(x: crop.maxX, y: y))
        }
        thirds.lineWidth = 1
        thirds.stroke()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: crop.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let corners = NSBezierPath()
        let arm: CGFloat = 16
        for (x, y, sx, sy) in [(crop.minX, crop.minY, 1.0, 1.0), (crop.maxX, crop.minY, -1.0, 1.0),
                               (crop.minX, crop.maxY, 1.0, -1.0), (crop.maxX, crop.maxY, -1.0, -1.0)] {
            corners.move(to: CGPoint(x: x + arm * sx, y: y))
            corners.line(to: CGPoint(x: x, y: y))
            corners.line(to: CGPoint(x: x, y: y + arm * sy))
        }
        corners.lineWidth = 3
        corners.stroke()
    }
}

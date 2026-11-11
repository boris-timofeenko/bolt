import CoreGraphics

public enum ZoomMode: Equatable, Sendable {
    /// Whole image visible. Small images are not blown up past one image pixel per point.
    case fit
    /// Image width matches the view; scroll vertically.
    case fitWidth
    /// Fixed ratio of image pixels to screen pixels: 1 is 100%, "1:1 pixel".
    case ratio(Double)
}

/// Zoom and pan state. Pure geometry, so it survives switching photos: the same mode and the same
/// relative spot apply to the next frame of a burst.
///
/// View coordinates have their origin at the top left; sizes are in points, image sizes in pixels.
public struct Viewport: Equatable, Sendable {
    public var mode: ZoomMode
    /// The point of the image shown at the centre of the view, as a fraction of the image size.
    public var focus: CGPoint

    public static let zoomSteps: [Double] = [0.05, 0.0625, 0.083, 0.125, 0.167, 0.25, 0.333, 0.5, 0.667,
                                             1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]

    public init(mode: ZoomMode = .fit, focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.mode = mode
        self.focus = focus
    }

    /// Points per image pixel.
    public func scale(image: CGSize, view: CGSize, backingScale: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        switch mode {
        case .fit:
            return min(view.width / image.width, view.height / image.height, 1)
        case .fitWidth:
            return view.width / image.width
        case .ratio(let ratio):
            return ratio / backingScale
        }
    }

    /// Image pixels per screen pixel, the number shown as a percentage.
    public func ratio(image: CGSize, view: CGSize, backingScale: CGFloat) -> Double {
        scale(image: image, view: view, backingScale: backingScale) * backingScale
    }

    public func fitRatio(image: CGSize, view: CGSize, backingScale: CGFloat) -> Double {
        Viewport(mode: .fit).ratio(image: image, view: view, backingScale: backingScale)
    }

    /// Where the image goes in the view.
    public func imageFrame(image: CGSize, view: CGSize, backingScale: CGFloat) -> CGRect {
        let scale = scale(image: image, view: view, backingScale: backingScale)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let focus = Self.clamp(focus, displayed: size, view: view)
        return CGRect(x: view.width / 2 - focus.x * size.width,
                      y: view.height / 2 - focus.y * size.height,
                      width: size.width, height: size.height)
    }

    /// True when part of the image is outside the view, so dragging pans instead of navigating.
    public func overflows(image: CGSize, view: CGSize, backingScale: CGFloat) -> Bool {
        let frame = imageFrame(image: image, view: view, backingScale: backingScale)
        return frame.width > view.width + 0.5 || frame.height > view.height + 0.5
    }

    /// Zooms to `ratio` keeping the image point under `anchor` where it is.
    public mutating func zoom(to ratio: Double, anchor: CGPoint, image: CGSize, view: CGSize, backingScale: CGFloat) {
        let old = imageFrame(image: image, view: view, backingScale: backingScale)
        guard old.width > 0, old.height > 0 else { return }
        let anchorInImage = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)

        mode = .ratio(ratio)
        let scale = scale(image: image, view: view, backingScale: backingScale)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let unclamped = CGPoint(x: (view.width / 2 - anchor.x) / size.width + anchorInImage.x,
                                y: (view.height / 2 - anchor.y) / size.height + anchorInImage.y)
        focus = Self.clamp(unclamped, displayed: size, view: view)
    }

    /// Moves the image by `delta` points, stopping at its edges.
    public mutating func pan(by delta: CGSize, image: CGSize, view: CGSize, backingScale: CGFloat) {
        let frame = imageFrame(image: image, view: view, backingScale: backingScale)
        guard frame.width > 0, frame.height > 0 else { return }
        let current = Self.clamp(focus, displayed: frame.size, view: view)
        focus = Self.clamp(CGPoint(x: current.x - delta.width / frame.width, y: current.y - delta.height / frame.height),
                           displayed: frame.size, view: view)
    }

    /// Fit width starts at the top of the photo.
    public mutating func fitWidth() {
        mode = .fitWidth
        focus = CGPoint(x: 0.5, y: 0)
    }

    public static func nextStep(after ratio: Double, zoomingIn: Bool) -> Double {
        if zoomingIn {
            return zoomSteps.first { $0 > ratio * 1.01 } ?? zoomSteps[zoomSteps.count - 1]
        }
        return zoomSteps.last { $0 < ratio * 0.99 } ?? zoomSteps[0]
    }

    /// Along each axis: centred when the image is smaller than the view, otherwise kept so no gap opens at an edge.
    static func clamp(_ point: CGPoint, displayed size: CGSize, view: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, _ length: CGFloat, _ viewLength: CGFloat) -> CGFloat {
            guard length > viewLength else { return 0.5 }
            let half = viewLength / 2 / length
            return min(max(value, half), 1 - half)
        }
        return CGPoint(x: axis(point.x, size.width, view.width), y: axis(point.y, size.height, view.height))
    }
}

/// Which frames to decode ahead of time, most urgent first:
/// current, next, previous, then further along the direction of travel, then further back.
public enum PrefetchPlan {
    public static func indices(around center: Int, count: Int, direction: Int,
                               ahead: Int = 4, behind: Int = 2) -> [Int] {
        guard count > 0, (0..<count).contains(center) else { return [] }
        let step = direction < 0 ? -1 : 1
        var order = [center, center + step, center - step]
        if ahead >= 2 { order += (2...ahead).map { center + step * $0 } }
        if behind >= 2 { order += (2...behind).map { center - step * $0 } }
        if behind < 1 { order.removeAll { $0 == center - step } }
        return order.filter { (0..<count).contains($0) }
    }
}

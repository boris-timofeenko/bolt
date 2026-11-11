import BoltCore
import CoreImage

/// Rotates an already decoded frame in memory, so a rotated photo updates without reading the file again.
@MainActor
enum FrameRotation {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ relative: Orientation, to frame: DecodedFrame) -> DecodedFrame? {
        guard relative != Orientation() else { return frame }
        guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(relative.exifValue)) else { return nil }
        let rotated = CIImage(cgImage: frame.image).oriented(orientation)
        let space = frame.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = context.createCGImage(rotated, from: rotated.extent, format: .BGRA8, colorSpace: space) else {
            return nil
        }
        var info = frame.info
        if relative.quarterTurns % 2 == 1 {
            swap(&info.pixelWidth, &info.pixelHeight)
        }
        info.orientation = relative.composed(after: Orientation(exif: frame.info.orientation)).exifValue
        return DecodedFrame(image: image, kind: frame.kind, info: info, decodeTime: frame.decodeTime)
    }
}

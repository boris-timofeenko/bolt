import BoltCore
import CoreImage

/// Rotates an already decoded frame in memory, so a rotated photo updates without reading the file again.
enum FrameRotation {
    static func apply(_ relative: Orientation, to frame: DecodedFrame) -> DecodedFrame? {
        guard relative != Orientation() else { return frame }
        guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(relative.exifValue)) else { return nil }
        var info = frame.info
        if relative.quarterTurns % 2 == 1 {
            swap(&info.pixelWidth, &info.pixelHeight)
        }
        info.orientation = relative.composed(after: Orientation(exif: frame.info.orientation)).exifValue
        return frame.turned(orientation, info: info)
    }
}

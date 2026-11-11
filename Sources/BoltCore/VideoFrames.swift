import AVFoundation
import CoreGraphics
import Foundation

/// Poster frames and basic facts about videos, so they sit in the same list and grid as photos.
public enum VideoFrames {
    /// The first frame, scaled to fit `maxPixelSize`. Blocks; call off the main thread.
    public static func poster(at url: URL, maxPixelSize: Int) -> CGImage? {
        wait {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            return try await generator.image(at: .zero).image
        }
    }

    /// Size as displayed (rotation applied), duration and recording date.
    public static func info(at url: URL) -> ImageInfo? {
        wait {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = size.applying(transform)
            var info = ImageInfo(properties: [:], typeIdentifier: nil)
            info.pixelWidth = Int(abs(shown.width).rounded())
            info.pixelHeight = Int(abs(shown.height).rounded())
            info.duration = try await asset.load(.duration).seconds
            info.captureDate = try await asset.load(.creationDate)?.load(.dateValue)
            return info
        }
    }

    /// AVFoundation only offers async loading now; decoding runs on background queues anyway.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T?) -> T? {
        let result = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.value = try? await work()
            done.signal()
        }
        done.wait()
        return result.value
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

import CoreGraphics
import Foundation
import ImageIO

/// The metadata Bolt shows or sorts by, parsed from ImageIO's property dictionary.
public struct ImageInfo: Equatable, Sendable {
    /// Pixel dimensions as displayed, with EXIF orientation applied.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// EXIF orientation, 1...8.
    public var orientation: Int
    public var captureDate: Date?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Int?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var focalLength: Double?
    public var focalLength35mm: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var colorProfile: String?
    public var bitDepth: Int?
    public var frameCount: Int
    public var typeIdentifier: String?
    /// Seconds, for videos.
    public var duration: Double?

    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    public var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }
    /// GIF, APNG, animated WebP and HEIC sequences; a multi-page TIFF is not an animation.
    public var isAnimated: Bool {
        guard frameCount > 1, let typeIdentifier else { return false }
        return ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics"].contains(typeIdentifier)
    }

    public var camera: String? {
        guard let model else { return make }
        // Canon writes "Canon" and "Canon EOS R5"; don't say the brand twice.
        guard let make, let brand = make.split(separator: " ").first?.lowercased(),
              !model.lowercased().hasPrefix(brand) else { return model }
        return "\(make) \(model)"
    }

    public init(properties: [String: Any], frameCount: Int = 1, typeIdentifier: String? = nil) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        orientation = (properties[kCGImagePropertyOrientation as String] as? Int).flatMap { (1...8).contains($0) ? $0 : nil } ?? 1
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let swapsAxes = orientation >= 5
        pixelWidth = swapsAxes ? height : width
        pixelHeight = swapsAxes ? width : height

        captureDate = ExifDate.parse(
            exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
                ?? tiff[kCGImagePropertyTIFFDateTime as String] as? String,
            subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
            offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String)

        make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmed
        model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmed
        lens = (exif[kCGImagePropertyExifLensModel as String] as? String)?.trimmed
        iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double
        focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
        focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int

        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            latitude = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -lat : lat
            longitude = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -lon : lon
        }

        colorProfile = properties[kCGImagePropertyProfileName as String] as? String
        bitDepth = properties[kCGImagePropertyDepth as String] as? Int
        self.frameCount = frameCount
        self.typeIdentifier = typeIdentifier
    }
}

/// EXIF dates look like "2026:10:12 14:03:00" and carry no time zone unless OffsetTime is set.
public enum ExifDate {
    public static func parse(_ text: String?, subseconds: String? = nil, offset: String? = nil) -> Date? {
        guard let text else { return nil }
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count >= 6, numbers[0] > 0, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2],
                                        hour: numbers[3], minute: numbers[4], second: numbers[5])
        guard var date = calendar.date(from: components) else { return nil }
        if let subseconds, let fraction = Double("0." + subseconds.trimmed) {
            date += fraction
        }
        return date
    }

    /// "+03:00" → UTC+3.
    static func timeZone(fromOffset offset: String) -> TimeZone? {
        let trimmed = offset.trimmed
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let seconds = (parts[0] * 3600 + parts[1] * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
}

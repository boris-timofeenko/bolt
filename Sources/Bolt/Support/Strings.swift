import Foundation

/// Looks up interface text. Keys are the English strings, so a missing translation still reads fine.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

@MainActor
enum Format {
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func fileSize(_ value: Int64) -> String {
        bytes.string(fromByteCount: value)
    }

    static func dateTime(_ value: Date) -> String {
        date.string(from: value)
    }

    static func dimensions(_ width: Int, _ height: Int) -> String {
        "\(width) × \(height)"
    }

    static func percent(_ ratio: Double) -> String {
        let value = ratio * 100
        return value >= 10 || value.rounded() == value ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }

    static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration.milliseconds)
    }

    /// "~/Pictures/Trip" instead of "/Users/name/Pictures/Trip".
    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func exposure(_ seconds: Double) -> String {
        L("%@ s", seconds >= 0.5 ? number(seconds) : "1/\(Int((1 / seconds).rounded()))")
    }

    /// "1:05", "1:02:03".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// One decimal at most, with the locale's decimal separator: "6,9".
    static func number(_ value: Double) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

extension FileManager {
    /// "Просмотр" rather than "Preview" on a Russian system.
    func applicationName(_ url: URL) -> String {
        (displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

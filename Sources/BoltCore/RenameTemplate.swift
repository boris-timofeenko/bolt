import Foundation

/// Batch rename patterns such as `{date:yyyy-MM-dd_HHmmss}_{counter}`.
///
/// Tokens: `{name}` original name without extension, `{counter}` or `{counter:3}` (zero-padded),
/// `{date}` or `{date:FORMAT}` capture date (file date if there's none), `{folder}` enclosing folder.
/// The extension is always kept.
public struct RenameTemplate: Sendable {
    public let pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    public struct Input: Sendable {
        public let url: URL
        public let date: Date

        public init(url: URL, date: Date) {
            self.url = url
            self.date = date
        }
    }

    /// New names for `inputs`, in order. Two inputs that would get the same name get " (2)", " (3)"…
    public func names(for inputs: [Input], startingAt start: Int = 1) -> [String] {
        var used: [String: Int] = [:]
        return inputs.enumerated().map { index, input in
            let ext = input.url.pathExtension
            var stem = render(input, counter: start + index)
            if stem.isEmpty { stem = input.url.deletingPathExtension().lastPathComponent }
            let key = (stem + "." + ext).lowercased()
            used[key, default: 0] += 1
            if let count = used[key], count > 1 { stem += " (\(count))" }
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
    }

    private func render(_ input: Input, counter: Int) -> String {
        var result = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                result += rest[open...]
                return sanitized(result)
            }
            result += value(of: rest[rest.index(after: open)..<close], input: input, counter: counter)
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return sanitized(result)
    }

    private func value(of token: Substring, input: Input, counter: Int) -> String {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : nil
        switch parts.first?.lowercased() {
        case "name":
            return input.url.deletingPathExtension().lastPathComponent
        case "folder":
            return input.url.deletingLastPathComponent().lastPathComponent
        case "counter":
            let width = argument.flatMap(Int.init) ?? 1
            let digits = String(counter)
            return String(repeating: "0", count: max(width - digits.count, 0)) + digits
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = argument ?? "yyyy-MM-dd"
            return formatter.string(from: input.date)
        default:
            return "{\(token)}"
        }
    }

    /// File names can't contain "/" or ":" and shouldn't start with a dot.
    private func sanitized(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

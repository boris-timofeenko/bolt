import Foundation

/// Where "sort into date folders" puts a photo: `2026/2026-10/` inside the given folder.
public enum DateFolders {
    public static func folder(for date: Date, in base: URL, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%@-%02d", year, parts.month ?? 0)
        return base.appendingPathComponent(year, isDirectory: true).appendingPathComponent(month, isDirectory: true)
    }
}

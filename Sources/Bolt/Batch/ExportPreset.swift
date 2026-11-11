import BoltCore
import Foundation

/// Named export settings, e.g. "Telegram: JPEG 85%, 2560 px, no location". E exports with the last one used.
struct ExportPreset: Codable, Equatable {
    var name: String
    var settings: ExportSettings

    static var builtIn: [ExportPreset] {
        [
            ExportPreset(name: "Telegram", settings: ExportSettings(format: .jpeg, quality: 0.85, maxLongSide: 2560,
                                                                   metadata: .removePrivate)),
            ExportPreset(name: L("Full Size JPEG"), settings: ExportSettings(format: .jpeg, quality: 0.92)),
            ExportPreset(name: L("Web"), settings: ExportSettings(format: .jpeg, quality: 0.8, maxLongSide: 1600,
                                                                 metadata: .removeAll)),
        ]
    }

    /// "JPEG 85% · 2560 px · no location"
    var summary: String {
        var parts = [settings.format?.displayName ?? L("Same format")]
        if settings.format?.isLossy ?? true { parts[0] += " \(Int((settings.quality * 100).rounded()))%" }
        parts.append(settings.maxLongSide.map { L("%d px", $0) } ?? L("full size"))
        switch settings.metadata {
        case .keep: break
        case .removePrivate: parts.append(L("no location"))
        case .removeAll: parts.append(L("no metadata"))
        }
        return parts.joined(separator: " · ")
    }
}

extension ExportFormat {
    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .png: "PNG"
        case .tiff: "TIFF"
        }
    }
}

extension Preferences {
    private static let presetsKey = "exportPresets"
    private static let lastPresetKey = "lastExportPreset"

    static var exportPresets: [ExportPreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: presetsKey),
                  let presets = try? JSONDecoder().decode([ExportPreset].self, from: data), !presets.isEmpty
            else { return ExportPreset.builtIn }
            return presets
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: presetsKey)
        }
    }

    static var lastExportPreset: ExportPreset {
        get {
            let name = UserDefaults.standard.string(forKey: lastPresetKey)
            return exportPresets.first { $0.name == name } ?? exportPresets[0]
        }
        set { UserDefaults.standard.set(newValue.name, forKey: lastPresetKey) }
    }

    /// Saves under the preset's name, replacing one with the same name.
    static func savePreset(_ preset: ExportPreset) {
        var presets = exportPresets
        presets.removeAll { $0.name == preset.name }
        presets.append(preset)
        exportPresets = presets
    }
}

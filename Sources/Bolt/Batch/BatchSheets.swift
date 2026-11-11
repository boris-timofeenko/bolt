import AppKit
import BoltCore
import Observation
import SwiftUI

/// Convert (B1, B3) and Rename (B2) dialogs, shown as sheets on the viewer window.
@MainActor
enum BatchSheet {
    static func present(_ view: some View, on window: NSWindow) -> NSWindow {
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet.styleMask = [.titled]
        window.beginSheet(sheet)
        return sheet
    }

    static func close(_ sheet: NSWindow?) {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}

// MARK: - Convert

@Observable @MainActor
final class ConvertModel {
    let count: Int

    static let sizes = [0, 4096, 2560, 2048, 1600, 1080, -1]

    var format: ExportFormat?
    var quality = 0.85
    var sizeChoice = 0
    var customSize = 3000
    var metadata = MetadataPolicy.keep
    var folderName = ""
    var presetName = ""

    init(count: Int, preset: ExportPreset) {
        self.count = count
        apply(preset)
    }

    func apply(_ preset: ExportPreset) {
        format = preset.settings.format
        quality = preset.settings.quality
        metadata = preset.settings.metadata
        let size = preset.settings.maxLongSide ?? 0
        sizeChoice = Self.sizes.contains(size) ? size : -1
        if size > 0 { customSize = size }
        folderName = preset.name
    }

    var settings: ExportSettings {
        let size = sizeChoice == -1 ? customSize : sizeChoice
        return ExportSettings(format: format, quality: quality, maxLongSide: size > 0 ? size : nil, metadata: metadata)
    }
}

struct ConvertSheetView: View {
    @Bindable var model: ConvertModel
    let onConvert: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Convert %d photos", model.count)).font(.headline)
            Form {
                Picker(L("Preset:"), selection: Binding(get: { "" }, set: { name in
                    if let preset = Preferences.exportPresets.first(where: { $0.name == name }) { model.apply(preset) }
                })) {
                    Text(L("Choose…")).tag("")
                    ForEach(Preferences.exportPresets, id: \.name) { Text($0.name).tag($0.name) }
                }
                Picker(L("Format:"), selection: $model.format) {
                    Text(L("Same as original")).tag(ExportFormat?.none)
                    ForEach(ExportFormat.available, id: \.self) { Text($0.displayName).tag(ExportFormat?.some($0)) }
                }
                if model.format?.isLossy ?? true {
                    LabeledContent(L("Quality:")) {
                        HStack {
                            Slider(value: $model.quality, in: 0.5...1, step: 0.01)
                            Text("\(Int((model.quality * 100).rounded()))%").monospacedDigit().frame(width: 40)
                        }
                    }
                }
                Picker(L("Long side:"), selection: $model.sizeChoice) {
                    Text(L("Original size")).tag(0)
                    ForEach(ConvertModel.sizes.filter { $0 > 0 }, id: \.self) { Text(L("%d px", $0)).tag($0) }
                    Text(L("Other…")).tag(-1)
                }
                if model.sizeChoice == -1 {
                    TextField(L("Pixels:"), value: $model.customSize, format: .number)
                }
                Picker(L("Metadata:"), selection: $model.metadata) {
                    Text(L("Keep")).tag(MetadataPolicy.keep)
                    Text(L("Remove location and serial numbers")).tag(MetadataPolicy.removePrivate)
                    Text(L("Remove all")).tag(MetadataPolicy.removeAll)
                }
                TextField(L("Into folder:"), text: $model.folderName)
                Text(L("The folder is created next to the photos. Originals stay as they are."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(L("Preset name"), text: $model.presetName).frame(width: 200)
                Button(L("Save Preset")) {
                    Preferences.savePreset(ExportPreset(name: model.presetName, settings: model.settings))
                    model.folderName = model.presetName
                }
                .disabled(model.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Convert"), action: onConvert).keyboardShortcut(.defaultAction)
                    .disabled(model.folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Rename

@Observable @MainActor
final class RenameModel {
    let urls: [URL]
    var pattern = "{date:yyyy-MM-dd_HHmmss}"
    var start = 1
    /// Capture dates, filled in the background when the sheet opens.
    var dates: [URL: Date]?

    init(urls: [URL]) {
        self.urls = urls
    }

    var newNames: [String] {
        let inputs = urls.map { url in
            RenameTemplate.Input(url: url, date: dates?[url] ?? PhotoItem(url: url)?.modified ?? Date())
        }
        return RenameTemplate(pattern).names(for: inputs, startingAt: start)
    }
}

struct RenameSheetView: View {
    @Bindable var model: RenameModel
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let names = model.newNames
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Rename %d photos", model.urls.count)).font(.headline)
            TextField(L("Template"), text: $model.pattern).font(.system(.body, design: .monospaced))
            Text("{name}  {counter:3}  {date:yyyy-MM-dd}  {folder}")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Stepper(L("Counter starts at %d", model.start), value: $model.start, in: 0...99_999)
            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(zip(model.urls, names).prefix(8).enumerated()), id: \.offset) { _, pair in
                        HStack {
                            Text(pair.0.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                            Text("→")
                            Text(pair.1).lineLimit(1)
                        }
                        .font(.caption.monospaced())
                    }
                    if model.urls.count > 8 {
                        Text(L("and %d more", model.urls.count - 8)).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.dates == nil {
                        Text(L("Reading shooting dates…")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Rename"), action: onRename).keyboardShortcut(.defaultAction)
                    .disabled(model.dates == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

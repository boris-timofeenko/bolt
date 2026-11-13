import AppKit
import BoltCore
import Carbon.HIToolbox
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum SettingsWindow {
    static func make() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: SettingsModel())))
        window.title = L("Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// Settings that aren't plain UserDefaults values. Those use @AppStorage directly.
@Observable @MainActor
private final class SettingsModel {
    var editorName = Preferences.externalEditor.map(FileManager.default.applicationName) ?? "—"
    var defaultViewerMessage: String?
    var buckets: [URL?] = (1...9).map(Preferences.bucket)
    var language = InterfaceLanguage.chosen {
        didSet { InterfaceLanguage.chosen = language }
    }
}

private struct KeyRow: View {
    let model: KeysModel
    let command: Command

    var body: some View {
        HStack {
            Text(command.paletteTitle)
            Spacer()
            Button(model.recording == command ? L("Press keys…") : model.shortcut(for: command)) {
                model.record(command)
            }
            .font(.system(.body, design: .monospaced))
            .buttonStyle(.borderless)
            .foregroundStyle(model.recording == command ? Color.accentColor : .primary)
            if model.isCustom(command) {
                Button(L("Reset")) { model.reset(command) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

/// The key list in Settings. Recording grabs the next key press before anything else sees it.
@Observable @MainActor
final class KeysModel {
    private(set) var keyMap = KeyMap.current()
    private(set) var recording: Command?
    @ObservationIgnored private var monitor: Any?

    func commands(in group: Command.Group) -> [Command] {
        Command.all.filter { $0.group == group && !$0.isHidden }
    }

    func shortcut(for command: Command) -> String {
        keyMap.chord(for: command)?.symbol ?? "—"
    }

    func isCustom(_ command: Command) -> Bool {
        Preferences.keyOverrides[command.id] != nil
    }

    func record(_ command: Command) {
        stopRecording()
        recording = command
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.finishRecording(KeyChord(event: event)) }
            return nil
        }
    }

    /// Esc cancels. Any other key becomes the command's only shortcut and is taken away from whatever had it.
    private func finishRecording(_ chord: KeyChord) {
        guard let command = recording else { return }
        stopRecording()
        guard Int(chord.keyCode) != kVK_Escape || !chord.modifiers.isEmpty else { return }
        var overrides = Preferences.keyOverrides
        if let previous = keyMap.command(for: chord), previous != command {
            overrides[previous.id] = KeyMap.current().bindings.filter { $0.value == previous && $0.key != chord }
                .map(\.key.storage)
        }
        overrides[command.id] = [chord.storage]
        Preferences.keyOverrides = overrides
        refresh()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    func reset(_ command: Command) {
        Preferences.keyOverrides[command.id] = nil
        refresh()
    }

    func resetAll() {
        Preferences.keyOverrides = [:]
        refresh()
    }

    func refresh() {
        keyMap = KeyMap.current()
    }
}

private struct SettingsView: View {
    let model: SettingsModel
    let keys = KeysModel()

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Text(L("General")) }
            FolderSettings(model: model).tabItem { Text(L("Folders")) }
            KeySettings(model: keys).tabItem { Text(L("Keys")) }
        }
        .frame(width: 500)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.background) private var background = CanvasBackground.system.rawValue
    @AppStorage(Preferences.Key.afterAction) private var afterAction = AfterAction.next.rawValue
    @AppStorage(Preferences.Key.wheelAction) private var wheelAction = WheelAction.navigate.rawValue
    @AppStorage(Preferences.Key.editSaveMode) private var editSaveMode = EditSaveMode.copy.rawValue
    @AppStorage(Preferences.Key.cacheMegabytes) private var cacheMegabytes = 1024
    @AppStorage(Preferences.Key.slideshowSeconds) private var slideshowSeconds = 3
    let model: SettingsModel

    var body: some View {
        Form {
            LabeledContent(L("Language:")) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(get: { model.language }, set: { model.language = $0 })) {
                        Text(L("Same as System")).tag("")
                        Divider()
                        ForEach(InterfaceLanguage.available, id: \.self) { Text(InterfaceLanguage.name($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.language != InterfaceLanguage.atLaunch {
                        HStack {
                            Text(L("Takes effect after a restart.")).font(.caption).foregroundStyle(.secondary)
                            Button(L("Restart Now"), action: InterfaceLanguage.restart).controlSize(.small)
                        }
                    }
                }
            }
            Picker(L("Background:"), selection: $background) {
                ForEach(CanvasBackground.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Picker(L("After copying:"), selection: $afterAction) {
                Text(L("Show the next photo")).tag(AfterAction.next.rawValue)
                Text(L("Stay on this photo")).tag(AfterAction.stay.rawValue)
            }
            Picker(L("Mouse wheel:"), selection: $wheelAction) {
                Text(L("Flips through photos")).tag(WheelAction.navigate.rawValue)
                Text(L("Zooms")).tag(WheelAction.zoom.rawValue)
            }
            Picker(L("Edited photos:"), selection: $editSaveMode) {
                Text(L("Save a copy next to the original")).tag(EditSaveMode.copy.rawValue)
                Text(L("Replace the original")).tag(EditSaveMode.replace.rawValue)
            }
            Picker(L("Slideshow:"), selection: $slideshowSeconds) {
                ForEach([2, 3, 5, 10, 30], id: \.self) { Text(L("every %d s", $0)).tag($0) }
            }
            Picker(L("Memory for photos:"), selection: $cacheMegabytes) {
                ForEach([512, 1024, 2048, 4096], id: \.self) { Text(Format.fileSize(Int64($0) * 1_048_576)).tag($0) }
            }
            LabeledContent(L("O opens in:")) {
                HStack {
                    Text(model.editorName)
                    Button(L("Choose…"), action: chooseEditor)
                }
            }
            LabeledContent(L("Default viewer:")) {
                VStack(alignment: .leading, spacing: 4) {
                    Button(L("Open photos in Bolt by default"), action: makeDefaultViewer)
                    if let message = model.defaultViewerMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.externalEditor = url
        model.editorName = FileManager.default.applicationName(url)
    }

    private func makeDefaultViewer() {
        let app = Bundle.main.bundleURL
        let types: [UTType] = [.jpeg, .heic, .heif, .png, .gif, .tiff, .webP, .rawImage, .bmp]
            + ["public.avif", "public.jpeg-xl", "com.adobe.raw-image", "com.apple.protected-mpeg-4-image"]
                .compactMap { UTType($0) }
        Task {
            var failed = 0
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                } catch {
                    failed += 1
                }
            }
            model.defaultViewerMessage = failed == 0 ? L("Photos now open in Bolt.")
                                               : L("Some formats stayed with their old app.")
        }
    }
}

private struct FolderSettings: View {
    let model: SettingsModel
    private var buckets: [URL?] { model.buckets }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Keys 1–9 move the photo to these folders, ⌥1–9 copy it there."))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, verticalSpacing: 6) {
                ForEach(1...9, id: \.self) { number in
                    GridRow {
                        Text("\(number)").monospacedDigit().foregroundStyle(.secondary)
                        Text(buckets[number - 1].map(Format.path) ?? L("not set"))
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(buckets[number - 1] == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L("Choose…")) { choose(number) }
                        Button(L("Clear")) { set(number, nil) }.disabled(buckets[number - 1] == nil)
                    }
                }
            }
        }
    }

    private func choose(_ number: Int) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderAccess.remember(url)
        set(number, url)
    }

    private func set(_ number: Int, _ url: URL?) {
        Preferences.setBucket(number, to: url)
        model.buckets[number - 1] = url
    }
}

private struct KeySettings: View {
    @AppStorage(Preferences.Key.keyProfile) private var profile = KeyProfile.bolt.rawValue
    let model: KeysModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker(L("Shortcuts:"), selection: $profile) {
                    ForEach(KeyProfile.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
            }
            Text(profileNote + " " + L("Keys are tied to their place on the keyboard and work with any layout."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(Command.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(model.commands(in: group), id: \.id) { command in
                            KeyRow(model: model, command: command)
                        }
                    }
                }
            }
            .frame(height: 300)
            HStack {
                Text(L("Click a shortcut, then press the new keys. Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Reset All"), action: model.resetAll).disabled(Preferences.keyOverrides.isEmpty)
            }
        }
        .onChange(of: profile) { model.refresh() }
    }

    private var profileNote: String {
        switch KeyProfile(rawValue: profile) ?? .bolt {
        case .bolt: L("Bolt: arrows flip through photos, 1–9 sort them into folders.")
        case .irfanView: L("IrfanView: L and R rotate, F7 and F8 move and copy.")
        case .lightroom: L("Lightroom: ⌘[ and ⌘] rotate, ⌥1–9 move to folders.")
        }
    }
}

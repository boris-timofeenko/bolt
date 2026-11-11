import AppKit
import BoltCore

/// Export presets (E, Shift+E), batch conversion and renaming, removing private metadata.
/// Everything here writes new files and lands in the undo history.
extension ViewerWindowController {
    /// What a batch dialog works on: the selection, or every photo in the list when nothing is selected.
    var batchTargets: [PhotoItem] {
        gallery.selection.count > 1 ? gallery.targets : gallery.items
    }

    // MARK: - Export

    func exportWithLastPreset() {
        export(gallery.targets, preset: Preferences.lastExportPreset)
    }

    func chooseExportPreset() {
        let targets = gallery.targets
        presentPicker(title: L("Export with…"), placeholder: L("Preset")) { [weak self] query in
            Preferences.exportPresets
                .filter { query.isEmpty || FuzzyMatch.score(query, in: $0.name) != nil }
                .map { preset in
                    PickerItem(title: preset.name, subtitle: preset.summary, accessory: nil) {
                        self?.export(targets, preset: preset)
                    }
                }
        }
    }

    /// Writes re-encoded copies into a folder named after the preset, next to the photos.
    func export(_ items: [PhotoItem], preset: ExportPreset) {
        guard let folder = gallery.folder, !items.isEmpty else { return }
        Preferences.lastExportPreset = preset
        let destination = folder.appendingPathComponent(preset.name, isDirectory: true)
        runBatch(items.map { .export($0.url, preset.settings, into: destination) },
                 label: L("history.export %@", preset.name), verb: L("Exporting"),
                 done: L("Saved to “%@”", preset.name))
    }

    // MARK: - Convert

    func showConvertSheet() {
        let targets = batchTargets
        guard let window = visibleWindow, let folder = gallery.folder, !targets.isEmpty else { return }
        let model = ConvertModel(count: targets.count, preset: Preferences.lastExportPreset)
        var sheet: NSWindow?
        let view = ConvertSheetView(model: model, onConvert: { [weak self] in
            BatchSheet.close(sheet)
            let name = model.folderName.trimmingCharacters(in: .whitespaces)
            let destination = folder.appendingPathComponent(name, isDirectory: true)
            self?.runBatch(targets.map { .export($0.url, model.settings, into: destination) },
                           label: L("history.convert"), verb: L("Converting"), done: L("Saved to “%@”", name))
        }, onCancel: { BatchSheet.close(sheet) })
        sheet = BatchSheet.present(view, on: window)
    }

    // MARK: - Rename

    func showRenameSheet() {
        let urls = batchTargets.map(\.url)
        guard let window = visibleWindow, !urls.isEmpty else { return }
        let model = RenameModel(urls: urls)
        inBackground({ ImageDecoder.captureDates(of: urls) }, then: { _, dates in model.dates = dates })
        var sheet: NSWindow?
        let view = RenameSheetView(model: model, onRename: { [weak self] in
            BatchSheet.close(sheet)
            self?.rename(urls, to: model.newNames)
        }, onCancel: { BatchSheet.close(sheet) })
        sheet = BatchSheet.present(view, on: window)
    }

    /// Renames as one step that succeeds or fails as a whole. A new name already used by a file outside
    /// the batch gets " (2)", like everywhere else; names within the batch may swap freely.
    private func rename(_ urls: [URL], to names: [String]) {
        guard let folder = gallery.folder else { return }
        let renaming = Set(urls.map { $0.lastPathComponent.lowercased() })
        var taken = Set(((try? FolderScanner.entries(in: folder)) ?? []).map { $0.name.lowercased() })
            .subtracting(renaming)
        let pairs = zip(urls, names).compactMap { url, name -> RenamePair? in
            guard url.lastPathComponent != name else { return nil }
            let free = FileOperations.availableURL(for: name, in: folder) { taken.contains($0.lastPathComponent.lowercased()) }
            taken.insert(free.lastPathComponent.lowercased())
            return RenamePair(url: url, name: free.lastPathComponent)
        }
        guard !pairs.isEmpty else { return }
        session.history.perform([.renameAll(pairs)], label: L("history.batchRename")) { [weak self] outcome in
            self?.report(outcome, success: L("Renamed: %d", pairs.count))
        }
    }

    // MARK: - Date folders

    /// Moves photos into `2026/2026-10/` folders by shooting date (file date when there's none).
    func sortIntoDateFolders() {
        let items = batchTargets
        guard let folder = gallery.folder, !items.isEmpty else { return }
        statusBar.setProgress(L("Reading shooting dates…"))
        inBackground({ ImageDecoder.captureDates(of: items.map(\.url)) }, then: { controller, dates in
            let requests = items.map { item in
                FileRequest.move(item.url, into: DateFolders.folder(for: dates[item.url] ?? item.modified, in: folder))
            }
            controller.runBatch(requests, label: L("history.dateFolders"), verb: L("Moving"),
                                done: L("Sorted into date folders"))
        })
    }

    // MARK: - Private data

    /// Removes GPS and serial numbers without re-encoding. Saves a copy or replaces the original,
    /// as set in Settings; the original goes to the Trash either way, never just overwritten.
    func removePrivateData() {
        let targets = gallery.targets
        guard !targets.isEmpty else { return }
        let replacing = Preferences.editSaveMode == .replace
        runBatch(targets.map { .edit($0.url, .removePrivateData, replacingOriginal: replacing) },
                 label: L("history.clean"), verb: L("Cleaning"),
                 done: replacing ? L("Location removed") : L("Saved a copy without location"))
    }

    // MARK: - Running

    /// A few photos run like any other file action; more run in the background with progress in the
    /// status bar, while browsing continues. Esc stops a running batch.
    func runBatch(_ requests: [FileRequest], label: String, verb: String, done: String) {
        let finish: FileHistory.Completion = { [weak self] outcome in
            self?.batchJob = nil
            self?.statusBar.setProgress(nil)
            self?.report(outcome, success: done)
        }
        guard requests.count > 3 else {
            session.history.perform(requests, label: label, completion: finish)
            return
        }
        statusBar.setProgress("\(verb) 0 / \(requests.count)")
        batchJob = session.history.performBatch(requests, label: label, progress: { [weak self] done, total in
            self?.statusBar.setProgress("\(verb) \(done) / \(total)")
        }, completion: finish)
    }
}

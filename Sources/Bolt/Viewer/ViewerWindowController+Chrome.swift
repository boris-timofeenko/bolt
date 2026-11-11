import AppKit
import BoltCore

/// Commands, the status bar, overlays and full screen.
extension ViewerWindowController {
    // MARK: - Keys and commands

    /// Called for every key press while this window is key and no text field is being edited.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if cheatSheet != nil {
            closeCheatSheet()
            return true
        }
        if let crop {
            crop.overlay.handleKey(event)
            return true
        }
        if handleGridKey(event) || handleCompareKey(event) { return true }
        guard let command = session.keyMap.command(for: KeyChord(event: event)) else { return false }
        // Holding a key repeats it; for Live Photos the hold itself is the point, not the repeats.
        if command == .livePhoto, event.isARepeat { return true }
        perform(command, isRepeat: event.isARepeat)
        return true
    }

    /// Releasing V stops a Live Photo.
    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard livePhotoLayer != nil, session.keyMap.command(for: KeyChord(event: event)) == .livePhoto else { return false }
        stopLivePhoto()
        return true
    }

    func perform(_ command: Command, isRepeat: Bool = false) {
        if slideshowTimer != nil, command.group == .navigation || command == .exitFullscreen { stopSlideshow() }
        switch command {
        case .next: go(by: 1, isRepeat: isRepeat)
        case .previous: go(by: -1, isRepeat: isRepeat)
        case .first: go(to: 0)
        case .last: go(to: gallery.count - 1)
        case .forward10: go(by: 10)
        case .back10: go(by: -10)
        case .extendNext: extendSelection(by: 1)
        case .extendPrevious: extendSelection(by: -1)
        case .selectAll: selectAllPhotos()
        case .nextFolder: openSiblingFolder(1)
        case .previousFolder: openSiblingFolder(-1)
        case .parentFolder: openParentFolder()

        case .toggleGrid: toggleGrid()
        case .toggleStrip: toggleStrip()
        case .toggleInfo: toggleInfoPanel()
        case .toggleFullscreen: fullscreenWindow == nil ? enterFullscreen() : exitFullscreen()
        case .exitFullscreen: escape()
        case .toggleInterface: toggleInterface()

        case .zoomToggle: activeCanvas.toggleZoom()
        case .zoomIn: showsGrid ? resizeGridTiles(larger: true) : activeCanvas.zoomStep(in: true)
        case .zoomOut: showsGrid ? resizeGridTiles(larger: false) : activeCanvas.zoomStep(in: false)
        case .fitWindow: activeCanvas.viewport = Viewport(mode: .fit)
        case .fitWidth: fitToWidth()
        case .actualSize: activeCanvas.zoom(to: 1)

        case .trash: trashTargets()
        case .moveToBucket(let number): sendToBucket(number, copying: false)
        case .copyToBucket(let number): sendToBucket(number, copying: true)
        case .assignBucket(let number): assignBucket(number)
        case .flag(let flag): setLabel(.flag(flag))
        case .rate(let stars): setLabel(.rating(stars))
        case .colorLabel(let number): setLabel(.color(number))
        case .filter(let filter): setFilter(filter)
        case .moveToFolder: moveOrCopyToChosenFolder(copying: false)
        case .copyToFolder: moveOrCopyToChosenFolder(copying: true)
        case .compare: toggleCompare()
        case .repeatLast: repeatLastAction()
        case .undo: undo()
        case .redo: redo()

        case .rename: beginRename()
        case .copyImage: copyImage()
        case .copyPath: copyPath()
        case .revealInFinder: revealInFinder()
        case .share: share()
        case .openInEditor: openInEditor()
        case .open: session.showOpenPanel(for: self)

        case .rotateLeft: transformTargets(.rotateLeft)
        case .rotateRight: transformTargets(.rotateRight)
        case .flipHorizontal: transformTargets(.flipHorizontal)
        case .export: exportWithLastPreset()
        case .exportWithPreset: chooseExportPreset()
        case .convert: showConvertSheet()
        case .batchRename: showRenameSheet()
        case .dateFolders: sortIntoDateFolders()
        case .removePrivateData: removePrivateData()
        case .crop: beginCrop()
        case .playPause: togglePlayback()
        case .livePhoto: startLivePhoto()
        case .slideshow: toggleSlideshow()

        case .sort(let key): setSort(key)
        case .reverseSort: reverseSort()
        case .background(let background): Preferences.background = background

        case .commandPalette: showCommandPalette()
        case .cheatSheet: cheatSheet == nil ? showCheatSheet() : closeCheatSheet()
        case .performanceOverlay: togglePerformanceOverlay()
        case .settings: session.showSettings()
        }
        if command.isRepeatable { lastRepeatable = command }
    }

    private func selectAllPhotos() {
        gallery.selectAll()
        updateChrome()
    }

    private func toggleStrip() {
        Preferences.showStrip.toggle()
        applyChromeVisibility()
        updateChrome()
    }

    private func toggleInfoPanel() {
        Preferences.showInfo.toggle()
        applyChromeVisibility()
        updateChrome()
    }

    private func toggleInterface() {
        interfaceHidden.toggle()
        applyChromeVisibility()
    }

    private func togglePerformanceOverlay() {
        showsPerformance.toggle()
        updateChrome()
    }

    private func fitToWidth() {
        var viewport = Viewport()
        viewport.fitWidth()
        activeCanvas.viewport = viewport
    }

    private func repeatLastAction() {
        guard let last = lastRepeatable else {
            showToast(L("Nothing to repeat yet"))
            return
        }
        perform(last)
    }

    /// Esc backs out one step at a time: a running batch, an open overlay, the comparison, the selection,
    /// the grid, full screen, and last the zoom.
    private func escape() {
        if let batchJob {
            batchJob.cancel()
            showToast(L("Stopped. What's done stays done."))
        } else if let picker {
            picker.dismiss()
        } else if cheatSheet != nil {
            closeCheatSheet()
        } else if showsCompare {
            closeCompare()
        } else if !gallery.selection.isEmpty {
            gallery.clearSelection()
            updateChrome()
        } else if showsGrid {
            setGridVisible(false)
        } else if fullscreenWindow != nil {
            exitFullscreen()
        } else if canvas.viewport.mode != .fit {
            canvas.viewport = Viewport(mode: .fit)
        }
    }

    func isChecked(_ command: Command) -> Bool {
        switch command {
        case .sort(let key): gallery.order.key == key
        case .reverseSort: !gallery.order.ascending
        case .background(let background): Preferences.background == background
        case .toggleFullscreen: fullscreenWindow != nil
        case .toggleInterface: interfaceHidden
        case .toggleGrid: showsGrid
        case .toggleStrip: Preferences.showStrip
        case .toggleInfo: Preferences.showInfo
        case .compare: showsCompare
        case .slideshow: slideshowTimer != nil
        case .filter(let filter): labelFilter == filter
        case .flag(let flag): gallery.current.map { labels(of: $0).flag == flag && flag != .none } ?? false
        case .rate(let stars): gallery.current.map { labels(of: $0).rating == stars && stars > 0 } ?? false
        case .colorLabel(let number): gallery.current.map { labels(of: $0).color == number && number > 0 } ?? false
        case .performanceOverlay: showsPerformance
        default: false
        }
    }

    func isEnabled(_ command: Command) -> Bool {
        switch command {
        case .open, .settings, .commandPalette, .cheatSheet, .toggleFullscreen, .toggleInterface, .performanceOverlay,
             .background, .sort, .reverseSort, .undo, .redo, .assignBucket, .toggleStrip, .toggleInfo, .filter:
            true
        case .toggleGrid, .parentFolder, .nextFolder, .previousFolder: gallery.folder != nil
        case .repeatLast: lastRepeatable != nil && gallery.current != nil
        default: gallery.current != nil
        }
    }

    // MARK: - Status bar and title

    func updateChrome() {
        let title = gallery.current?.name ?? gallery.folder?.lastPathComponent ?? "Bolt"
        window?.title = title
        window?.representedURL = gallery.current?.url ?? gallery.folder
        statusBar.update(statusContent())
        root.performanceText = showsPerformance ? performanceText() : nil
        updateThumbnails()
        scheduleInfoPanelUpdate()
    }

    private func statusContent() -> StatusBarView.Content {
        var content = StatusBarView.Content()
        content.sort = gallery.order.key.title + (gallery.order.ascending ? " ↑" : " ↓")
        guard let item = gallery.current else { return content }

        content.position = gallery.isFiltered
            ? L("%d / %d of %d", gallery.currentIndex + 1, gallery.count, gallery.totalCount)
            : "\(gallery.currentIndex + 1) / \(gallery.count)"
        if gallery.selection.count > 1 {
            content.position += "  " + L("%d selected", gallery.selection.count)
        }
        content.name = item.name
        content.labels = labels(of: item).badge(font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        let shown = activeCanvas
        let info = !showsGrid && shown.currentURL == item.url ? shown.currentFrame?.info : nil
        if let info { content.details.append(Format.dimensions(info.pixelWidth, info.pixelHeight)) }
        if let duration = info?.duration { content.details.append(Format.duration(duration)) }
        content.details.append(Format.fileSize(item.fileSize))
        content.details.append(Format.dateTime(info?.captureDate ?? gallery.captureDates[item.url] ?? item.modified))
        if info != nil { content.zoom = Format.percent(shown.zoomRatio) }
        return content
    }

    private func performanceText() -> String {
        let stats = loader.stats
        let lookups = max(stats.hits + stats.misses, 1)
        let kind = canvas.currentFrame.map { "\($0.kind)" } ?? "—"
        let memory = ProcessInfo.processInfo.residentMegabytes
        return [
            "show \(Format.milliseconds(lastDisplayDuration)) ms (\(kind))",
            "decode \(Format.milliseconds(stats.lastDecode)) ms (\(stats.lastDecodeKind))",
            "cache hits \(stats.hits * 100 / lookups)%",
            "cache \(loader.cachedBytes / 1_048_576) / \(Preferences.cacheBytes / 1_048_576) MB",
            "memory \(memory) MB",
        ].joined(separator: "\n")
    }

    /// The panel follows a moment after the photo, so its text layout never delays the frame.
    private func scheduleInfoPanelUpdate() {
        guard root.showsInfo, !infoPanelUpdatePending else { return }
        infoPanelUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.infoPanelUpdatePending = false
                self?.updateInfoPanel()
            }
        }
    }

    /// Fills the info panel from the decoded frame's metadata, or reads it from the file when only
    /// the list entry is known (grid mode, a photo still loading).
    private func updateInfoPanel() {
        guard root.showsInfo else { return }
        guard let item = gallery.current else {
            root.info.show(item: nil, info: nil)
            return
        }
        if activeCanvas.currentURL == item.url, let info = activeCanvas.currentFrame?.info {
            root.info.show(item: item, info: info)
            return
        }
        root.info.show(item: item, info: nil)
        inBackground({ ImageDecoder.info(at: item.url) }, then: { controller, info in
            guard controller.gallery.current?.url == item.url else { return }
            controller.root.info.show(item: item, info: info)
        })
    }

    func showToast(_ text: String, isError: Bool = false) {
        root.toast.show(text, isError: isError)
    }

    func showSortMenu(from view: NSView) {
        let menu = NSMenu()
        for key in SortKey.allCases {
            menu.addItem(menuItem(.sort(key)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(.reverseSort))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: - Context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let groups: [[Command]] = [
            [.flag(.pick), .flag(.reject), .flag(.none)],
            [.rotateLeft, .rotateRight, .flipHorizontal],
            [.rename, .revealInFinder, .copyImage, .copyPath, .share, .openInEditor],
            [.moveToFolder, .copyToFolder, .trash],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in group { menu.addItem(menuItem(command)) }
        }
        return menu
    }

    private func menuItem(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(command: command, keyMap: session.keyMap, action: #selector(menuCommand(_:)), target: self)
        item.state = isChecked(command) ? .on : .off
        return item
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? CommandBox)?.command else { return }
        perform(command)
    }

    /// Edit > Copy reaches the window controller through the responder chain when no text is selected.
    @objc func copy(_ sender: Any?) {
        copyImage()
    }

    // MARK: - Overlays

    func presentPicker(title: String, placeholder: String, provider: @escaping (String) -> [PickerItem]) {
        picker?.dismiss()
        closeCheatSheet()
        let newPicker = QuickPicker(title: title, placeholder: placeholder, provider: provider)
        newPicker.onClose = { [weak self] in
            guard let self else { return }
            self.picker = nil
            self.visibleWindow?.makeFirstResponder(self.canvas)
        }
        picker = newPicker
        root.forceStatusBar = false
        newPicker.present(in: root)
    }

    func showCommandPalette() {
        let commands = Command.all.filter { command in
            if case .moveToBucket(let number) = command { return Preferences.bucket(number) != nil }
            if case .copyToBucket(let number) = command { return Preferences.bucket(number) != nil }
            return command != .commandPalette && isEnabled(command)
        }
        let keyMap = session.keyMap
        presentPicker(title: L("All Commands"), placeholder: L("Type a command")) { [weak self] query in
            let ranked: [Command] = query.isEmpty ? commands : commands
                .compactMap { command in FuzzyMatch.score(query, in: command.paletteTitle).map { ($0, command) } }
                .sorted { $0.0 > $1.0 }
                .map(\.1)
            return ranked.map { command in
                PickerItem(title: command.paletteTitle, subtitle: command.group.title,
                           accessory: keyMap.chord(for: command)?.symbol) { self?.perform(command) }
            }
        }
    }

    func showCheatSheet() {
        let sheet = CheatSheetView(keyMap: session.keyMap)
        sheet.onClose = { [weak self] in self?.closeCheatSheet() }
        cheatSheet = sheet
        root.overlay = sheet
    }

    func closeCheatSheet() {
        guard cheatSheet != nil else { return }
        cheatSheet = nil
        root.overlay = nil
    }

    // MARK: - Full screen

    /// A borderless window over the whole screen, shown instantly. The native full screen
    /// animates into a separate Space, which is exactly the delay a viewer shouldn't have.
    func enterFullscreen() {
        guard fullscreenWindow == nil, let window, let screen = window.screen ?? NSScreen.main else { return }
        let fullscreen = FullscreenWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                                          defer: false)
        fullscreen.isReleasedWhenClosed = false
        fullscreen.delegate = self
        fullscreen.backgroundColor = .black
        fullscreen.hasShadow = false
        fullscreen.acceptsMouseMovedEvents = true

        window.contentView = NSView()
        fullscreen.contentView = root
        fullscreen.setFrame(screen.frame, display: false)
        fullscreenWindow = fullscreen
        interfaceHidden = true
        applyChromeVisibility()

        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        fullscreen.makeKeyAndOrderFront(nil)
        fullscreen.makeFirstResponder(canvas)
        window.orderOut(nil)
        updateScreenTarget()
    }

    func exitFullscreen() {
        guard let fullscreen = fullscreenWindow, let window else { return }
        fullscreenWindow = nil
        NSApp.presentationOptions = []
        fullscreen.contentView = NSView()
        window.contentView = root
        interfaceHidden = false
        applyChromeVisibility()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        fullscreen.orderOut(nil)
        updateScreenTarget()
    }

    /// Closes the window, leaving full screen first.
    func closeViewer() {
        exitFullscreen()
        window?.close()
    }

    func applyChromeVisibility() {
        root.showsStatusBar = !interfaceHidden
        root.showsStrip = Preferences.showStrip && !interfaceHidden
        root.showsInfo = Preferences.showInfo && !interfaceHidden
    }

    func hideCursorInFullscreen() {
        if fullscreenWindow != nil { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}

final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension ProcessInfo {
    /// Physical memory the app is using right now, as Activity Monitor's "Memory" column shows it.
    var residentMegabytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}

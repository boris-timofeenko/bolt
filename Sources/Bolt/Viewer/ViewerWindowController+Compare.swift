import AppKit
import BoltCore
import Carbon.HIToolbox

/// K: compare two to four photos side by side. The active pane is the gallery's current photo,
/// so every action key (Delete, 1–9, P, X) works on it as usual.
extension ViewerWindowController: CompareViewDelegate {
    var showsCompare: Bool { root.showsCompare }

    /// The view zoom keys act on: the active pane while comparing, the single photo otherwise.
    var activeCanvas: ImageCanvasView {
        showsCompare ? root.compare.activePane ?? canvas : canvas
    }

    /// With 2–4 photos selected, compares them. Otherwise adds or removes the current photo;
    /// the comparison opens as soon as it has two.
    func toggleCompare() {
        if gallery.selection.count >= 2 {
            compareURLs = Array(gallery.targets.prefix(4).map(\.url))
            gallery.clearSelection()
        } else if let current = gallery.current {
            if let index = compareURLs.firstIndex(of: current.url) {
                compareURLs.remove(at: index)
            } else {
                compareURLs.append(current.url)
                if compareURLs.count > 4 { compareURLs.removeFirst() }
            }
        }
        if compareURLs.count >= 2 {
            root.showsCompare = true
            displayCurrent()
        } else {
            root.showsCompare = false
            if compareURLs.count == 1 { showToast(L("Added to comparison. Press K on another photo")) }
            displayCurrent()
        }
    }

    func closeCompare() {
        compareURLs = []
        root.showsCompare = false
        displayCurrent()
    }

    /// Left and right switch panes instead of photos.
    func handleCompareKey(_ event: NSEvent) -> Bool {
        guard showsCompare, event.hasNoModifiers else { return false }
        switch Int(event.keyCode) {
        case kVK_LeftArrow: activateComparePane(root.compare.active - 1)
        case kVK_RightArrow: activateComparePane(root.compare.active + 1)
        default: return false
        }
        return true
    }

    /// Called from `displayCurrent` while comparing: shows the best frames and asks for the rest.
    func displayComparison() {
        compareURLs = compareURLs.filter { gallery.index(of: $0) != nil }
        guard compareURLs.count >= 2 else {
            closeCompare()
            return
        }
        if let current = gallery.current?.url, !compareURLs.contains(current) {
            gallery.move(to: compareURLs[0])
        }
        let active = gallery.current.flatMap { compareURLs.firstIndex(of: $0.url) } ?? 0
        root.compare.setPhotos(compareURLs, active: active)
        for url in compareURLs {
            if let frame = loader.bestFrame(for: url) ?? loader.previewNow(url) {
                root.compare.show(frame, for: url)
            }
        }
        scheduleComparisonFrames()
    }

    func scheduleComparisonFrames() {
        let sharper = Set(root.compare.urlsNeedingSharperFrames)
        loader.schedule(compareURLs.flatMap { url in
            [(FrameLoader.Request(url: url, kind: .screen), FrameLoader.Priority.current)]
                + (sharper.contains(url) ? [(FrameLoader.Request(url: url, kind: .full), .next)] : [])
        })
    }

    private func activateComparePane(_ index: Int) {
        guard compareURLs.indices.contains(index) else { return }
        gallery.move(to: compareURLs[index])
        displayCurrent()
    }

    // MARK: - CompareViewDelegate

    func compareView(_ view: CompareView, didActivate index: Int) {
        activateComparePane(index)
    }

    func compareViewDidChangeViewport(_ view: CompareView) {
        updateChrome()
        if !view.urlsNeedingSharperFrames.isEmpty { scheduleComparisonFrames() }
    }
}

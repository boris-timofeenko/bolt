import AppKit
import BoltCore

/// Flags, ratings and color labels, and the filter that shows only some of them.
extension ViewerWindowController {
    func labels(of item: PhotoItem) -> PhotoLabels {
        labels[item.url] ?? PhotoLabels()
    }

    /// Reads the Finder tags of every photo in the background; xattrs are cheap, so this takes
    /// a fraction of a second even for thousands of files.
    func loadLabels() {
        let urls = gallery.items.map(\.url)
        guard !urls.isEmpty, let folder = gallery.folder else { return }
        inBackground(qos: .utility, { concurrentMap(urls) { LabelStorage.read($0) } }, then: { controller, read in
            guard controller.gallery.folder == folder else { return }
            for (url, labels) in zip(urls, read) where !labels.isEmpty { controller.labels[url] = labels }
            controller.labelsDidChange()
        })
    }

    func setLabel(_ change: LabelChange) {
        let targets = gallery.targets
        guard let current = gallery.current, !targets.isEmpty else { return }
        for item in targets { labels[item.url] = change.applied(to: labels(of: item)) }
        session.history.perform(targets.map { .label($0.url, change) }, label: L("history.label")) { [weak self] outcome in
            self?.finishLabeling(outcome)
        }
        labelsDidChange()
        // Under a filter the photo may just have left the list; then the next one is already on screen.
        if gallery.current?.url == current.url { advanceAfterNonRemovingAction() }
    }

    func setFilter(_ filter: LabelFilter) {
        labelFilter = filter
        if filter == .all {
            gallery.setFilter(nil)
        } else {
            gallery.setFilter { [weak self] item in
                filter.matches(self?.labels(of: item) ?? PhotoLabels())
            }
        }
        displayCurrent()
        if gallery.isEmpty, filter != .all { showToast(L("Nothing matches: %@", filter.title.lowercasedFirstLetter)) }
    }

    /// Picks up label changes made by undo or in another window.
    func applyLabelChange(_ url: URL, to new: PhotoLabels) {
        labels[url] = new
        labelsDidChange()
    }

    /// The labels were shown before they were written; where writing failed, show what's really there.
    private func finishLabeling(_ outcome: FileHistory.Outcome) {
        report(outcome)
        guard !outcome.failures.isEmpty else { return }
        for failed in outcome.failures { labels[failed.url] = LabelStorage.read(failed.url) }
        labelsDidChange()
    }

    private func labelsDidChange() {
        labelsRevision += 1
        if labelFilter != .all {
            gallery.refilter()
            displayCurrent()
        } else {
            updateChrome()
        }
    }
}

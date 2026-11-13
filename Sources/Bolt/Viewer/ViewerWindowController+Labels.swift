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
        if labelFilter == .all { showTip(after: change) }
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
        if gallery.isEmpty, filter != .all {
            showToast(L("Nothing matches: %@", filter.title.lowercasedFirstLetter))
        } else if filter != .all {
            showTipOnce("filter", L("Only these photos are shown now. %@ selects all of them, %@ copies them to a folder.",
                                    key(.selectAll), key(.copyToFolder)))
        }
    }

    /// The first flag or rating ever set leads on to the filter that makes it useful.
    private func showTip(after change: LabelChange) {
        switch change {
        case .flag(.pick):
            showTipOnce("pick", L("Picked. To show picks only: %@.", Guide.menuPath(.picks)) + "\n"
                + L("Step by step: %@.", Guide.guideMenuPath))
        case .flag(.reject):
            showTipOnce("reject", L("Rejected. To delete all rejected photos at once, choose %@, then press %@ and %@.",
                                    Guide.menuPath(.rejects), key(.selectAll), key(.trash)))
        case .rating(let stars) where stars > 0:
            showTipOnce("rating", L("Rating saved. To show the best only: %@.", Guide.menuPath(.rated(atLeast: 3))))
        default:
            break
        }
    }

    private func showTipOnce(_ name: String, _ text: String) {
        guard Preferences.takeTip(name) else { return }
        root.toast.showTip(text)
    }

    private func key(_ command: Command) -> String {
        Guide(keyMap: session.keyMap).key(command)
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

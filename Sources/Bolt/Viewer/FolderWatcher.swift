import Foundation

/// Calls back when files are added to, removed from or renamed in a folder, at most every 300 ms.
/// A vnode source on the directory: no polling, no CPU while nothing happens.
@MainActor
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(folder: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An import from a phone writes dozens of files in a burst; react once it settles.
                self.pending?.cancel()
                let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

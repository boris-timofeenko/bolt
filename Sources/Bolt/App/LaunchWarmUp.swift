import BoltCore
import Foundation

/// Work a double-click in Finder would otherwise wait for on the main thread. Started on other cores
/// before AppKit is even up: creating NSApplication alone takes ~45 ms.
enum LaunchWarmUp {
    static func start() {
        DispatchQueue.global(qos: .userInteractive).async {
            // The first HEIC decode in a process spends ~100 ms setting up the HEVC decoder. A tiny bundled
            // file takes that hit, so the photo the user opened doesn't.
            if let url = Bundle.main.url(forResource: "warmup", withExtension: "heic") {
                _ = ImageDecoder.screen(at: url, fitting: CGSize(width: 16, height: 16))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // While finishing launch, AppKit checks on the main thread whether Writing Tools are available,
            // and that loads their framework before the open request is handled (10–20 ms). Loaded here
            // first, it's already in memory by then. If the path ever changes, dlopen just returns nil.
            _ = dlopen("/System/Library/PrivateFrameworks/WritingToolsUI.framework/WritingToolsUI", RTLD_LAZY)
        }
    }
}

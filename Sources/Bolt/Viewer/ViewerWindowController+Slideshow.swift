import AppKit
import BoltCore

/// Slideshow: full screen, one photo every few seconds. Esc or any navigation key stops it.
extension ViewerWindowController {
    func toggleSlideshow() {
        if slideshowTimer != nil {
            stopSlideshow()
            return
        }
        if fullscreenWindow == nil { enterFullscreen() }
        let interval = TimeInterval(Preferences.slideshowSeconds)
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.gallery.currentIndex >= self.gallery.count - 1 {
                    self.stopSlideshow()
                } else {
                    self.go(by: 1)
                }
            }
        }
        showToast(L("Slideshow: every %d s. Esc stops", Preferences.slideshowSeconds))
    }

    func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }
}

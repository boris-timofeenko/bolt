import AppKit
import BoltCore

/// C: crop the current photo. The result is saved as set in Settings: a copy next to the original,
/// or in its place with the original in the Trash. Either way Cmd+Z takes it back.
extension ViewerWindowController: CropOverlayDelegate {
    func beginCrop() {
        guard let item = gallery.current, let frame = canvas.currentFrame, canvas.currentURL == item.url,
              !showsGrid, !showsCompare else { return }
        canvas.viewport = Viewport(mode: .fit)
        let overlay = CropOverlayView()
        overlay.delegate = self
        crop = CropSession(overlay: overlay, url: item.url)
        root.overlay = overlay
        root.layoutSubtreeIfNeeded()
        overlay.begin(imageRect: canvas.imageFrame, imageSize: frame.info.pixelSize)
    }

    func cropOverlay(_ overlay: CropOverlayView, didApply rect: CGRect) {
        guard let url = crop?.url else { return }
        endCrop()
        let replacing = Preferences.editSaveMode == .replace
        session.history.perform([.edit(url, .crop(rect), replacingOriginal: replacing)], label: L("history.crop")) {
            [weak self] outcome in
            guard let self else { return }
            self.report(outcome, success: replacing ? L("Cropped") : L("Cropped copy saved"))
            // Show the result: the new copy, or the photo now in the original's place.
            if let result = outcome.changes.compactMap(\.addedURL).last, self.gallery.move(to: result) {
                self.displayCurrent()
            }
        }
    }

    func cropOverlayDidCancel(_ overlay: CropOverlayView) {
        endCrop()
    }

    /// A click in the strip or a menu command can change the photo under the frame; the frame was drawn
    /// for the old one, so it goes away.
    func cancelCropIfAnotherPhoto() {
        if let crop, gallery.current?.url != crop.url { endCrop() }
    }

    private func endCrop() {
        crop = nil
        root.overlay = nil
        visibleWindow?.makeFirstResponder(canvas)
    }
}

struct CropSession {
    let overlay: CropOverlayView
    let url: URL
}

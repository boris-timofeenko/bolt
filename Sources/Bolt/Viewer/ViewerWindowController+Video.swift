import AppKit
import AVFoundation
import AVKit
import BoltCore

/// Videos in the list play inline, never on their own. Holding V plays a Live Photo's video over it.
extension ViewerWindowController {
    /// Puts a player over the canvas for videos and takes it away for everything else.
    func updateVideoPlayer() {
        guard let item = gallery.current, MediaTypes.isVideo(item.url), !showsGrid, !showsCompare else {
            removeVideoPlayer()
            return
        }
        if (playerView?.player?.currentItem?.asset as? AVURLAsset)?.url == item.url { return }
        removeVideoPlayer()
        let view = AVPlayerView(frame: canvas.bounds)
        view.autoresizingMask = [.width, .height]
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: item.url)
        canvas.addSubview(view)
        playerView = view
    }

    func removeVideoPlayer() {
        playerView?.player?.pause()
        playerView?.removeFromSuperview()
        playerView = nil
    }

    func togglePlayback() {
        guard let player = playerView?.player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    // MARK: - Live Photos

    /// Key down on V: plays the video half of a Live Photo, muted, until the key is released.
    func startLivePhoto() {
        guard livePhotoLayer == nil, let item = gallery.current, MediaTypes.isImage(item.url),
              let video = Companions.of(item.url).first(where: MediaTypes.isVideo) else { return }
        let player = AVPlayer(url: video)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = canvas.imageFrame
        canvas.layer?.addSublayer(layer)
        player.play()
        livePhotoLayer = layer
    }

    func stopLivePhoto() {
        livePhotoLayer?.player?.pause()
        livePhotoLayer?.removeFromSuperlayer()
        livePhotoLayer = nil
    }
}

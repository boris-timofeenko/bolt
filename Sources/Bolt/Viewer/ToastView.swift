import AppKit

/// A short line at the bottom of the photo that fades away: "Moved to Trash · ⌘Z".
/// Replaces confirmation dialogs; the hint says how to take the action back.
/// Also carries one-time tips ("Marked. To work with marked photos only: …"), which wrap and stay longer.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var wraps = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Shows `text` for 1.5 s, or 3 s for errors, which take longer to read and matter more.
    func show(_ text: String, isError: Bool = false) {
        show(text, isError: isError, wraps: false, seconds: isError ? 3 : 1.5)
    }

    /// A tip: up to a few lines, on screen long enough to read twice. The next toast replaces it.
    func showTip(_ text: String) {
        show(text, isError: false, wraps: true, seconds: 7)
    }

    private func show(_ text: String, isError: Bool, wraps: Bool, seconds: Double) {
        self.wraps = wraps
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingMiddle
        label.maximumNumberOfLines = wraps ? 0 : 1
        label.stringValue = text
        // VoiceOver reads toasts too: they're the only confirmation an action gets.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        label.textColor = isError ? NSColor(red: 1, green: 0.62, blue: 0.58, alpha: 1) : .white
        hideWork?.cancel()
        isHidden = false
        alphaValue = 1
        superview?.needsLayout = true

        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self?.alphaValue == 0 { self?.isHidden = true }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Positions the toast centred near the bottom of `container`.
    func place(in container: NSRect) {
        var size = label.intrinsicContentSize
        if wraps, let cell = label.cell {
            // Measured at the width it will get, so the frame holds every wrapped line.
            let bounds = NSRect(x: 0, y: 0, width: min(460, container.width - 56), height: .greatestFiniteMagnitude)
            size = cell.cellSize(forBounds: bounds)
            size = NSSize(width: ceil(size.width) + 1, height: ceil(size.height))
        }
        let width = min(size.width + 24, container.width - 32)
        let height = size.height + 10
        frame = NSRect(x: container.midX - width / 2, y: container.maxY - height - 18, width: width, height: height)
        label.frame = NSRect(x: 12, y: 5, width: width - 24, height: size.height)
    }
}

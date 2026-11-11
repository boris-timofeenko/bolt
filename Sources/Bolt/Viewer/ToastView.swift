import AppKit

/// A short line at the bottom of the photo that fades away: "Moved to Trash · ⌘Z".
/// Replaces confirmation dialogs; the hint says how to take the action back.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

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
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 3 : 1.5), execute: work)
    }

    /// Positions the toast centred near the bottom of `container`.
    func place(in container: NSRect) {
        let size = label.intrinsicContentSize
        let width = min(size.width + 24, container.width - 32)
        let height = size.height + 10
        frame = NSRect(x: container.midX - width / 2, y: container.maxY - height - 18, width: width, height: height)
        label.frame = NSRect(x: 12, y: 5, width: width - 24, height: size.height)
    }
}

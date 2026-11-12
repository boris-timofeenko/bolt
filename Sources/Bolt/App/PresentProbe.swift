import AppKit
import BoltCore
import Metal
import QuartzCore

/// Times an arrow key press from the event to the photo on screen. Off unless the app is launched with
/// `--present-probe <channel>`; it then listens for distributed notifications named
/// `org.boltviewer.Bolt.present.<channel>`, so copies of Bolt measured side by side don't hear each other:
///   flip 40 300 /path/out.json [back]   — posts N presses of → (or ←), one per M ms, and records each one
///   quit
/// Each press records, in milliseconds after the key event was posted: `keyDown` (the key monitor got it),
/// `show` and `shown` (around the commit that carries the photo), `handlerEnd`, `runLoopEnd` and `committed`
/// (around Core Animation's end-of-turn commit), and `presented`: a 2-point Metal layer in the corner of
/// the photo presents a drawable in the same transaction as the photo (`presentsWithTransaction`), and
/// its `presentedTime` is when that transaction reached the display. `--no-marker` leaves the layer out
/// (it costs ~0.3 ms in the transaction). See scripts/present-bench.sh.
@MainActor
enum PresentProbe {
    private(set) static var isEnabled = false
    private static var observer: NSObjectProtocol?
    private weak static var session: Session?
    private static var marker: PresentMarker?
    private static var runLoopObservers: [CFRunLoopObserver] = []

    /// Marks of the press being measured, as (stage, seconds of CACurrentMediaTime).
    private static var marks: [(String, Double)] = []
    private static var measuring = false
    private static var awaitingCommit = false
    private static var samples: [[String: Any]] = []

    static func install(session: Session) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--present-probe"), index + 1 < arguments.count else { return }
        isEnabled = true
        self.session = session
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("org.boltviewer.Bolt.present.\(arguments[index + 1])"), object: nil,
            queue: .main) { note in
            let line = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(line) }
        }
        if !arguments.contains("--no-marker") { marker = PresentMarker() }
        // Right before and right after Core Animation's own observer (order 2 000 000), which commits
        // whatever the turn of the run loop changed.
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        for (order, stage) in [(1_999_999, "runLoopEnd"), (Int.max, "committed")] {
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, order) { _, _ in
                MainActor.assumeIsolated { runLoopDidReach(stage) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            if let observer { runLoopObservers.append(observer) }
        }
    }

    // MARK: - Marks

    static func mark(_ stage: String) {
        guard isEnabled, measuring else { return }
        marks.append((stage, CACurrentMediaTime()))
    }

    static func handlerEnd() {
        guard isEnabled, measuring, marks.contains(where: { $0.0 == "keyDown" }) else { return }
        mark("handlerEnd")
        awaitingCommit = true
    }

    /// Called inside the transaction that carries the new photo.
    static func presentMarker(in layer: CALayer?) {
        guard isEnabled, measuring, let marker, let layer else { return }
        let index = samples.count
        marker.present(in: layer) { presented in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if index < samples.count, presented > 0 { samples[index]["presentedAt"] = presented }
                }
            }
        }
    }

    private static func runLoopDidReach(_ stage: String) {
        guard awaitingCommit else { return }
        mark(stage)
        if stage == "committed" { finishSample() }
    }

    private static func finishSample() {
        awaitingCommit = false
        measuring = false
        guard let posted = marks.first?.1 else { return }
        var sample: [String: Any] = [
            "postedAt": posted,
            "stages": marks.map { ["stage": $0.0, "ms": ($0.1 - posted) * 1000] },
        ]
        if let controller {
            let frame = controller.canvas.currentFrame
            sample["name"] = controller.gallery.current?.name ?? ""
            sample["index"] = controller.gallery.currentIndex
            sample["count"] = controller.gallery.count
            sample["kind"] = frame.map { "\($0.kind)" } ?? ""
            sample["hdr"] = frame?.isHDR ?? false
            sample["bytes"] = frame?.cost ?? 0
        }
        samples.append(sample)
    }

    // MARK: - Commands

    private static var controller: ViewerWindowController? {
        session?.activeController ?? session?.controllers.last
    }

    private static func handle(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        switch words.first {
        case "flip" where words.count >= 4:
            flip(count: Int(words[1]) ?? 0, interval: Int(words[2]) ?? 300,
                 output: URL(fileURLWithPath: words[3]), keyCode: words.contains("back") ? 123 : 124)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func flip(count: Int, interval: Int, output: URL, keyCode: UInt16) {
        samples = []
        func step(_ remaining: Int) {
            guard remaining > 0 else {
                // Presented times arrive a few frames after the commit; by now all of them are in.
                for index in samples.indices {
                    if let presented = samples[index]["presentedAt"] as? Double,
                       let posted = samples[index]["postedAt"] as? Double {
                        samples[index]["presentedMs"] = (presented - posted) * 1000
                    }
                }
                let screen = controller?.visibleWindow?.screen ?? NSScreen.main
                let summary: [String: Any] = [
                    "edrPotential": screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0,
                    "window": controller?.visibleWindow.map { NSStringFromRect($0.frame) } ?? "",
                    "samples": samples,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
                    try? data.write(to: output)
                }
                return
            }
            post(keyCode: keyCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(interval)) { step(remaining - 1) }
        }
        step(count)
    }

    /// Key down now, key up 80 ms later like a finger: a key up already waiting in the queue would be
    /// handled before the run loop gets to its commit, which no real press does.
    private static func post(keyCode: UInt16, isUp: Bool = false) {
        guard let window = controller?.visibleWindow else { return }
        let character = Keys.menuCharacter(for: keyCode) ?? ""
        guard let event = NSEvent.keyEvent(with: isUp ? .keyUp : .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: character,
                                           charactersIgnoringModifiers: character, isARepeat: false,
                                           keyCode: keyCode) else { return }
        if !isUp {
            marks = [("posted", CACurrentMediaTime())]
            measuring = true
            awaitingCommit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { post(keyCode: keyCode, isUp: true) }
        }
        NSApp.postEvent(event, atStart: false)
    }
}

/// A tiny Metal layer whose drawable is presented with the current Core Animation transaction.
@MainActor
private final class PresentMarker {
    private let queue: MTLCommandQueue?
    private let layer = CAMetalLayer()
    private var flip = false

    init() {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.presentsWithTransaction = true
        layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.drawableSize = CGSize(width: 4, height: 4)
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
    }

    func present(in host: CALayer, presented: @escaping @Sendable (Double) -> Void) {
        if layer.superlayer !== host { host.addSublayer(layer) }
        guard let queue, let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        // A different colour each time, so every drawable is a real change on screen.
        flip.toggle()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let grey = flip ? 0.5 : 0.45
        pass.colorAttachments[0].clearColor = MTLClearColor(red: grey, green: grey, blue: grey, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        drawable.addPresentedHandler { drawable in presented(drawable.presentedTime) }
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }
}

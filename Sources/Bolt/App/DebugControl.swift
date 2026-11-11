import AppKit
import BoltCore

/// A remote control for scripted UI checks, off unless the app is launched with `--debug-control`.
///
/// Commands arrive as distributed notifications named `org.boltviewer.Bolt.debug` whose object is a line:
///   key 124 [shift] [option] [command] [control] [repeat]   — posts a real key event through the event queue
///   type some text                                          — inserts text into the focused field
///   snapshot /path/out.png                                  — renders the front viewer window
///   state /path/out.json                                    — writes what the viewer shows
///   open /path                                              — opens a photo or folder
///   bench 200 120 /path/out.json [repeat]                    — steps forward N times, one step per M ms,
///                                                              and records how long each step took
///   convert /path/out.json                                   — converts the folder to JPEG and times it
///   command Convert…                                         — runs a command by its title
/// See scripts/boltctl.swift for the sending side.
@MainActor
final class DebugControl {
    static let notification = Notification.Name("org.boltviewer.Bolt.debug")
    private let session: Session
    private var observer: NSObjectProtocol?

    static var isEnabled: Bool { CommandLine.arguments.contains("--debug-control") }

    init(session: Session) {
        self.session = session
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.notification, object: nil,
                                                                       queue: .main) { [weak self] note in
            let line = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(line) }
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "key": postKey(argument)
        case "type": (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "snapshot": snapshot(to: URL(fileURLWithPath: argument))
        case "state": writeState(to: URL(fileURLWithPath: argument))
        case "open": session.open([URL(fileURLWithPath: argument)])
        case "bench": bench(argument)
        case "convert": convertAll(to: URL(fileURLWithPath: argument))
        case "command": runCommand(argument)
        default: break
        }
    }

    private var controller: ViewerWindowController? {
        session.activeController ?? session.controllers.last
    }

    private func postKey(_ argument: String) {
        let words = argument.split(separator: " ")
        guard let code = words.first.flatMap({ UInt16($0) }), let window = controller?.visibleWindow else { return }
        let names: [(Substring, KeyChord.Modifiers)] = [("shift", .shift), ("option", .option),
                                                        ("command", .command), ("control", .control)]
        let flags = names.reduce(into: KeyChord.Modifiers()) { result, pair in
            if words.contains(pair.0) { result.insert(pair.1) }
        }.eventFlags
        let characters = Keys.menuCharacter(for: code) ?? ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: words.contains("repeat"), keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func snapshot(to url: URL) {
        // A sheet, when one is open, is what the user is looking at.
        guard let front = controller?.visibleWindow, let window = front.attachedSheet ?? Optional(front),
              let view = window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        view.displayIfNeeded()
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Steps forward like a user culling a folder and records, per step, the time spent on the main thread
    /// and whether a screen-sized frame was already decoded (prefetch hit) or only the preview was shown.
    private func bench(_ argument: String) {
        let words = argument.split(separator: " ").map(String.init)
        guard words.count >= 3, let steps = Int(words[0]), let interval = Int(words[1]), let controller else { return }
        let output = URL(fileURLWithPath: words[2])
        let isRepeat = words.contains("repeat")
        var samples: [[String: Any]] = []

        func step(_ remaining: Int) {
            guard remaining > 0 else {
                let times = samples.compactMap { $0["ms"] as? Double }.sorted()
                let sharp = samples.filter { ($0["kind"] as? String) != "preview" && ($0["kind"] as? String) != "" }.count
                let summary: [String: Any] = [
                    "steps": samples.count,
                    "medianMs": times.isEmpty ? 0 : times[times.count / 2],
                    "p95Ms": times.isEmpty ? 0 : times[min(times.count - 1, times.count * 95 / 100)],
                    "maxMs": times.last ?? 0,
                    "sharpOnArrival": sharp,
                    "memoryMB": ProcessInfo.processInfo.residentMegabytes,
                    "samples": samples,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
                    try? data.write(to: output)
                }
                return
            }
            controller.perform(.next, isRepeat: isRepeat)
            samples.append(["ms": controller.lastDisplayDuration.milliseconds, "kind": controller.canvas.currentFrame.map { "\($0.kind)" } ?? "",
                            "name": controller.gallery.current?.name ?? ""])
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(interval)) { step(remaining - 1) }
        }
        step(steps)
    }

    /// Runs a palette command by its title, e.g. "command Convert…".
    private func runCommand(_ title: String) {
        guard let controller, let command = Command.all.first(where: { $0.title == title || $0.paletteTitle == title })
        else { return }
        controller.perform(command)
    }

    /// Converts every photo in the front window to JPEG 85% in a "Converted" folder and records how long it took.
    private func convertAll(to output: URL) {
        guard let controller, let folder = controller.gallery.folder else { return }
        let start = ContinuousClock.now
        let destination = folder.appendingPathComponent("Converted")
        let settings = ExportSettings(format: .jpeg, quality: 0.85)
        controller.session.history.performBatch(controller.gallery.items.map { .export($0.url, settings, into: destination) },
                                                label: "convert", progress: { _, _ in }) { outcome in
            let seconds = start.duration(to: .now).milliseconds / 1000
            let summary: [String: Any] = ["files": outcome.changes.count, "failures": outcome.failures.count,
                                          "seconds": seconds]
            if let data = try? JSONSerialization.data(withJSONObject: summary) { try? data.write(to: output) }
        }
    }

    private func writeState(to url: URL) {
        guard let controller else { return }
        let gallery = controller.gallery
        let canvas = controller.canvas
        let state: [String: Any] = [
            "folder": gallery.folder?.path ?? "",
            "count": gallery.count,
            "index": gallery.currentIndex,
            "name": gallery.current?.name ?? "",
            "selection": gallery.selection.map(\.lastPathComponent).sorted(),
            "shownURL": canvas.currentURL?.lastPathComponent ?? "",
            "frameKind": canvas.currentFrame.map { "\($0.kind)" } ?? "",
            "frameSize": canvas.currentFrame.map { "\($0.image.width)x\($0.image.height)" } ?? "",
            "zoom": canvas.zoomRatio,
            "fullscreen": controller.fullscreenWindow != nil,
            "grid": controller.showsGrid,
            "memoryMB": ProcessInfo.processInfo.residentMegabytes,
            "compare": controller.showsCompare,
            "statusBarVisible": !controller.statusBar.isHidden,
            "picker": controller.picker != nil,
            "cheatSheet": controller.cheatSheet != nil,
            "displayMilliseconds": Format.milliseconds(controller.lastDisplayDuration),
            "keyWindowIsViewer": controller.owns(NSApp.keyWindow),
            "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "undo": controller.session.history.undoLabel ?? "",
            "windows": controller.session.controllers.count,
            "gridVisibleRect": NSStringFromRect(controller.root.grid.contentView.documentVisibleRect),
            "launchToFirstFrameMs": LaunchTimeline.firstFrameMilliseconds ?? -1,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

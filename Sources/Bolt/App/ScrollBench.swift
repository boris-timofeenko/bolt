import AppKit
import BoltCore

/// The benchmark behind the debug commands `taps`, `hold` and `first`: it presses keys the way a keyboard does
/// and records, for every press, how long it took until the next photo was sharp in the layer.
///
///   taps <steps> <interval ms> <out.json> [pgdn] [turn=<n>] [back]
///       a key-down and, 40 ms later (at most half an interval), a key-up, every `interval`. `pgdn` presses
///       Page Down (ten photos) instead of the right arrow. `turn=<n>` goes forward n times, then back.
///   hold <steps> <interval ms> <out.json> [delay=<ms>] [back]
///       one key-down, the first auto-repeat `delay` later (default: one interval; a keyboard waits 375-500 ms),
///       then a repeat every `interval`, then the key-up half an interval after the last repeat
///   first <ms> <out.json>
///       one right-arrow press `ms` after the first frame of the photo the app was opened with was on screen
///
/// Key events are built like the ones the keyboard sends and go through `NSApp.postEvent`, so the key monitor
/// in `AppDelegate`, `handleKeyDown`/`handleKeyUp` and the key map all run exactly as for a real key. They are
/// posted at their scheduled time or, if the main thread was busy, right after it: like a keyboard, the
/// schedule does not wait for the app, so a slow step shows up as a lag and a burst of steps.
///
/// What is on screen comes from `ImageCanvasView.onShown`, called right before and after the canvas changes.
/// The first call for a new photo is the step; later calls for the same photo are frames arriving while it is
/// still the one on screen. Two run-loop observers around Core Animation's commit (order 2 000 000) say where
/// the rest of the loop turn went: after the handler, and in the commit.
@MainActor
final class ScrollBench {
    enum Mode: String {
        case hold, taps
    }

    private struct KeyPress {
        /// Seconds after the start.
        let due: Double
        let code: UInt16
        let isDown: Bool
        let isRepeat: Bool
    }

    private enum Phase {
        case running, settling, done
    }

    private static var active: ScrollBench?
    /// How long to wait for the last photo to get sharp after the key is released.
    private static let settleTimeout = 3.0
    private static let tapDuration = 0.04
    private static let rightArrow: UInt16 = 124, leftArrow: UInt16 = 123, pageDown: UInt16 = 121, pageUp: UInt16 = 116

    private let controller: ViewerWindowController
    private var run: ScrollRun
    private let output: URL
    private let startURL: URL?

    private let presses: [KeyPress]
    /// When each step's key is due, seconds after the start.
    private let stepDues: [Double]
    private var started = 0.0
    private var nextPress = 0
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var observers: [CFRunLoopObserver] = []
    private var phase = Phase.running

    private var recorded: [ScrollStep] = []
    private var currentIsSharp = false
    private var willShowAt = 0.0
    /// Steps shown since the run loop last went idle, and the one whose loop turn ended there.
    private var turnSteps: [Int] = []
    private var committingStep: Int?

    // MARK: - Starting

    static func start(_ mode: Mode, _ argument: String, in controller: ViewerWindowController?) {
        let words = argument.split(separator: " ").map(String.init)
        guard words.count >= 3, let requested = Int(words[0]), let interval = Int(words[1]),
              requested > 0, interval > 0 else { return }
        let output = URL(fileURLWithPath: words[2])
        let options = Array(words.dropFirst(3))
        func value(_ name: String) -> Int? {
            options.first { $0.hasPrefix(name + "=") }.flatMap { Int($0.dropFirst(name.count + 1)) }
        }
        guard active == nil else { return fail(output, "another scroll run is in progress") }
        guard let controller, controller.visibleWindow != nil else { return fail(output, "no viewer window") }

        let gallery = controller.gallery
        let jump = options.contains("pgdn")
        let backwards = options.contains("back")
        let perPress = jump ? 10 : 1
        let forwardRoom = (gallery.count - 1 - gallery.currentIndex) / perPress
        var keys: [UInt16]
        var turnAfter: Int?
        if mode == .taps, let turn = value("turn") {
            let forward = min(turn, forwardRoom)
            keys = (0..<min(requested, forward * 2)).map { $0 < forward ? rightArrow : leftArrow }
            turnAfter = forward
        } else {
            let room = backwards ? gallery.currentIndex / perPress : forwardRoom
            let key = jump ? (backwards ? pageUp : pageDown) : (backwards ? leftArrow : rightArrow)
            keys = Array(repeating: key, count: min(requested, room))
        }
        guard !keys.isEmpty else { return fail(output, "no photos to step to") }

        let scenario = ScrollRun(mode: mode.rawValue, requestedSteps: requested, steps: keys.count, intervalMs: interval,
                                 delayMs: mode == .hold ? value("delay") ?? interval : 0,
                                 keysDescription: options.filter { ["pgdn", "back"].contains($0) || $0.hasPrefix("turn=") }
                                     .joined(separator: " "),
                                 turnAfter: turnAfter, startIndex: gallery.currentIndex, folder: "", windowVisible: false,
                                 appActive: false, decodesHDR: false, memoryMB: 0, cacheMB: 0, started: 0, releaseAt: 0)
        let bench = ScrollBench(controller, scenario, keys: keys, output: output)
        active = bench
        bench.begin(at: nil)
    }

    /// `first <ms> <out.json>`: one press `ms` after the first frame was shown. If the command came too late
    /// for that, the press goes at once and the report says by how much it was late.
    static func startFirstPress(_ argument: String, in controller: ViewerWindowController?) {
        let words = argument.split(separator: " ").map(String.init)
        guard words.count >= 2, let delay = Int(words[0]) else { return }
        let output = URL(fileURLWithPath: words[1])
        guard active == nil else { return fail(output, "another scroll run is in progress") }
        guard let controller, controller.visibleWindow != nil else { return fail(output, "no viewer window") }
        guard let firstFrame = LaunchTimeline.firstFrameMilliseconds else { return fail(output, "no frame shown yet") }

        let remaining = firstFrame + Double(delay) - LaunchTimeline.now
        var scenario = ScrollRun(mode: "first", requestedSteps: 1, steps: 1, intervalMs: 1000, delayMs: 0,
                                 keysDescription: "", startIndex: controller.gallery.currentIndex, folder: "",
                                 windowVisible: false, appActive: false, decodesHDR: false, memoryMB: 0, cacheMB: 0,
                                 started: 0, releaseAt: 0)
        scenario.firstPressDelayMs = delay
        scenario.lateMs = max(-remaining, 0)
        // The folder may not be listed yet: then the press does nothing, as it would for a user, and the report says so.
        let bench = ScrollBench(controller, scenario, keys: [rightArrow], output: output)
        active = bench
        bench.begin(at: ProcessInfo.processInfo.systemUptime + max(remaining, 0) / 1000)
    }

    private static func fail(_ output: URL, _ message: String) {
        let data = try? JSONSerialization.data(withJSONObject: ["error": message])
        try? data?.write(to: output, options: .atomic)
    }

    private init(_ controller: ViewerWindowController, _ run: ScrollRun, keys: [UInt16], output: URL) {
        self.controller = controller
        self.run = run
        self.output = output
        startURL = controller.gallery.current?.url

        let interval = Double(run.intervalMs) / 1000
        var presses: [KeyPress] = []
        if run.mode == Mode.hold.rawValue {
            let delay = Double(run.delayMs) / 1000
            presses = keys.indices.map {
                KeyPress(due: $0 == 0 ? 0 : delay + Double($0 - 1) * interval, code: keys[$0], isDown: true, isRepeat: $0 > 0)
            }
            presses.append(KeyPress(due: presses.last!.due + interval / 2, code: keys[0], isDown: false, isRepeat: false))
        } else {
            let length = min(Self.tapDuration, interval / 2)
            for (index, code) in keys.enumerated() {
                let due = Double(index) * interval
                presses.append(KeyPress(due: due, code: code, isDown: true, isRepeat: false))
                presses.append(KeyPress(due: due + length, code: code, isDown: false, isRepeat: false))
            }
        }
        self.presses = presses
        stepDues = presses.filter(\.isDown).map(\.due)
    }

    private func begin(at start: Double?) {
        // A background app is throttled (App Nap), which would stretch the timers: ask not to be.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Bolt scroll benchmark")
        controller.canvas.onShown = { [weak self] phase, url, frame in self?.record(phase, url, frame) }
        installObservers()
        let now = ProcessInfo.processInfo.systemUptime
        started = start ?? now + 0.05
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        timer.schedule(deadline: .now() + .nanoseconds(Int(max(started - now, 0) * 1e9)), leeway: .nanoseconds(0))
        timer.resume()
        self.timer = timer
        // If something goes wrong (the window closed), don't hang forever.
        let limit = max(started - now, 0) + presses.last!.due + Self.settleTimeout + 10
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    // MARK: - Pressing keys

    /// Posts every key press that is due. Overdue ones go out together, in order.
    private func fire() {
        guard phase == .running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        while nextPress < presses.count, started + presses[nextPress].due <= now + 0.0005 {
            post(presses[nextPress])
            nextPress += 1
        }
        if nextPress < presses.count {
            let wait = max(started + presses[nextPress].due - ProcessInfo.processInfo.systemUptime, 0)
            timer?.schedule(deadline: .now() + .nanoseconds(Int(wait * 1e9)), leeway: .nanoseconds(0))
        } else {
            timer?.cancel()
            timer = nil
            beginSettling()
        }
    }

    private func post(_ press: KeyPress) {
        guard let window = controller.visibleWindow else { return }
        let characters = Keys.menuCharacter(for: press.code) ?? ""
        // What the key reports on a keyboard: arrows are also "numeric pad" keys.
        let flags: NSEvent.ModifierFlags = press.code == Self.leftArrow || press.code == Self.rightArrow
            ? [.numericPad, .function] : [.function]
        let event = NSEvent.keyEvent(with: press.isDown ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                                     timestamp: started + press.due, windowNumber: window.windowNumber, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: press.isRepeat, keyCode: press.code)
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    // MARK: - Watching the screen

    private func record(_ shownPhase: ImageCanvasView.ShownPhase, _ url: URL?, _ frame: DecodedFrame?) {
        guard phase != .done else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if shownPhase == .willShow {
            willShowAt = now
            return
        }
        guard let url else { return }
        let shown = frame.map { ShownFrame(at: now, kind: $0.kind, longSide: $0.longSide, isHDR: $0.isHDR, bytes: $0.cost) }
        if url != (recorded.last?.url ?? startURL) {
            // The display time of a step is only known once the next one starts, or at the end.
            if !recorded.isEmpty { recorded[recorded.count - 1].mainMs = controller.lastDisplayDuration.milliseconds }
            let index = recorded.count
            let due = started + (index < stepDues.count ? stepDues[index] : 0)
            recorded.append(ScrollStep(url: url, due: due, showStart: willShowAt, shownAt: now, frame: shown))
            turnSteps.append(index)
            currentIsSharp = shown?.isSharp ?? false
        } else if let shown, !recorded.isEmpty {
            recorded[recorded.count - 1].arrivals.append(shown)
            if shown.isSharp { currentIsSharp = true }
        }
        if phase == .settling, currentIsSharp { finishSoon() }
    }

    /// Core Animation commits the layer tree in a run-loop observer at the end of the turn (order 2 000 000).
    /// One observer just before it and one just after it split the end of a step into the handler's tail
    /// and the commit.
    private func installObservers() {
        func add(order: Int, _ action: @escaping @MainActor () -> Void) {
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, order) { _, _ in
                MainActor.assumeIsolated { action() }
            }
            if let observer {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }
        }
        add(order: 1) { [weak self] in self?.turnWillCommit() }
        add(order: 3_000_000) { [weak self] in self?.turnDidCommit() }
    }

    private func turnWillCommit() {
        defer { turnSteps = [] }
        // Two steps in one turn: the tail of the first would be the second's work.
        guard turnSteps.count == 1, let index = turnSteps.first else {
            committingStep = nil
            return
        }
        recorded[index].handlerEnd = ProcessInfo.processInfo.systemUptime
        committingStep = index
    }

    private func turnDidCommit() {
        guard let index = committingStep else { return }
        recorded[index].commitEnd = ProcessInfo.processInfo.systemUptime
        committingStep = nil
    }

    /// The key is up: wait for the photo it stopped on to get sharp, but not for ever.
    private func beginSettling() {
        phase = .settling
        if currentIsSharp {
            finishSoon()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    /// A moment later, so the loop turn of the last step has ended and its end is recorded.
    private func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard phase != .done else { return }
        phase = .done
        timer?.cancel()
        timer = nil
        controller.canvas.onShown = nil
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        if !recorded.isEmpty { recorded[recorded.count - 1].mainMs = controller.lastDisplayDuration.milliseconds }
        run.folder = controller.gallery.folder?.path ?? ""
        run.windowVisible = controller.visibleWindow?.occlusionState.contains(.visible) ?? false
        run.appActive = NSApp.isActive
        run.decodesHDR = controller.loader.decodesHDR
        run.memoryMB = ProcessInfo.processInfo.residentMegabytes
        run.cacheMB = controller.loader.cachedBytes / 1_048_576
        run.started = started
        run.releaseAt = started + (presses.last?.due ?? 0)
        let data = try? JSONSerialization.data(withJSONObject: ScrollReport.build(recorded, run),
                                               options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: output, options: .atomic)
        Self.active = nil
    }
}

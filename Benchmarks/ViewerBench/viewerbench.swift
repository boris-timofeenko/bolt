// viewerbench: how fast does a photo viewer show photos? Measured from a screen recording,
// so any app can be compared the same way: Bolt, XnView MP, Preview.
//
// Runs as a child of BoltBench.app, which holds the Screen Recording and Accessibility grants.
// Photos come from make-bench-photos.swift: photo i is filled with hue frac(i × 0.618) and fine stripes.
// A photo is "visible" when its hue covers part of the screen, and "sharp" when the stripes are there:
// the 320 px embedded thumbnail that viewers show first has none.
//
//   viewerbench --app /Applications/XnViewMP.app --folder DIR --out result.json
//               [--next-key 124] [--open-all] [--steps 25] [--runs 3] [--snapshots DIR] [--check]

import AppKit
import ApplicationServices
import CoreImage
import CoreMedia
import ScreenCaptureKit

// MARK: - Options

struct Options {
    var app = URL(fileURLWithPath: "/")
    var folder = URL(fileURLWithPath: "/")
    var output = URL(fileURLWithPath: "/dev/stdout")
    var nextKey: CGKeyCode = 124
    /// Preview only pages through files that were opened together.
    var openAll = false
    var steps = 25
    var openRuns = 3
    var snapshots: URL?
    var checkOnly = false
    /// Posts one press of the next key, to see whether key events reach other apps.
    var probeKey = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--app": app = URL(fileURLWithPath: iterator.next() ?? "")
            case "--folder": folder = URL(fileURLWithPath: iterator.next() ?? "")
            case "--out": output = URL(fileURLWithPath: iterator.next() ?? "")
            case "--next-key": nextKey = CGKeyCode(iterator.next().flatMap(Int.init) ?? 124)
            case "--open-all": openAll = true
            case "--steps": steps = iterator.next().flatMap(Int.init) ?? steps
            case "--runs": openRuns = iterator.next().flatMap(Int.init) ?? openRuns
            case "--snapshots": snapshots = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--check": checkOnly = true
            case "--probe-key": probeKey = true
            default: break
            }
        }
    }
}

// MARK: - Time

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func seconds(_ machTime: UInt64) -> Double {
    Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

func now() -> Double {
    seconds(mach_absolute_time())
}

func pause(_ duration: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
}

// MARK: - What a frame shows

/// The hue photo `index` is filled with; the same formula as make-bench-photos.swift.
func hue(ofPhoto index: Int) -> Float {
    Float((Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1))
}

func hueDistance(_ a: Float, _ b: Float) -> Float {
    let difference = abs(a - b)
    return min(difference, 1 - difference)
}

struct Sample {
    var hue: Float
    var saturation: Float
    /// Standard deviation of luminance in a 7×7 patch: high where the stripes are, near zero where blurred.
    var contrast: Float
}

struct Frame {
    let time: Double
    let samples: [Sample]

    static let minimumPoints = 25

    /// Grid points showing photo `index`, and how sharp they look.
    func photo(_ index: Int) -> (points: Int, contrast: Float) {
        let target = hue(ofPhoto: index)
        let matches = samples.filter { $0.saturation > 0.25 && hueDistance($0.hue, target) < 0.08 }
        guard !matches.isEmpty else { return (0, 0) }
        return (matches.count, matches.map(\.contrast).reduce(0, +) / Float(matches.count))
    }

    func shows(_ index: Int) -> Bool {
        photo(index).points >= Self.minimumPoints
    }

    /// How sharp the main photo on screen is, whichever it is: stripe contrast over the points of the
    /// dominant hue. Thumbnails in a strip or sidebar have other hues and don't count.
    var photoContrast: Float {
        guard let bin = dominantHueBin else { return 0 }
        let photo = samples.filter { $0.saturation > 0.25 && abs(Int($0.hue * 36) - bin) <= 1 }
        return photo.map(\.contrast).reduce(0, +) / Float(max(photo.count, 1))
    }

    /// The hue covering most of the colourful part of the screen, in 1/36 steps, or nil for a grey screen.
    var dominantHueBin: Int? {
        var bins = [Int](repeating: 0, count: 36)
        for sample in samples where sample.saturation > 0.25 { bins[min(Int(sample.hue * 36), 35)] += 1 }
        guard let best = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[best] >= Self.minimumPoints else {
            return nil
        }
        return best
    }
}

func rgb(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
    let h = hue * 6
    let c = value * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = value - c
    let (r, g, b): (Double, Double, Double) = switch Int(h) {
    case 0: (c, x, 0)
    case 1: (x, c, 0)
    case 2: (0, c, x)
    case 3: (0, x, c)
    case 4: (x, 0, c)
    default: (c, 0, x)
    }
    return (r + m, g + m, b + m)
}

// MARK: - Screen recording

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var snapshotRequest: URL?
    private let columns = 48
    private let rows = 30

    var all: [Frame] { lock.withLock { frames } }

    func snapshot(to url: URL) {
        lock.withLock { snapshotRequest = url }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init), status == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        let time = (info[.displayTime] as? UInt64).map(seconds) ?? now()

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)

        var samples: [Sample] = []
        samples.reserveCapacity(columns * rows)
        let margin = width / 40
        for row in 0..<rows {
            for column in 0..<columns {
                let x = margin + (width - 2 * margin) * column / (columns - 1)
                let y = margin * 2 + (height - 3 * margin) * row / (rows - 1)
                samples.append(sample(base, stride: stride, x: min(max(x, 3), width - 4), y: min(max(y, 3), height - 4)))
            }
        }
        let request: URL? = lock.withLock {
            frames.append(Frame(time: time, samples: samples))
            defer { snapshotRequest = nil }
            return snapshotRequest
        }
        if let request { save(pixels, to: request) }
    }

    private func sample(_ base: UnsafePointer<UInt8>, stride: Int, x: Int, y: Int) -> Sample {
        var red: Float = 0, green: Float = 0, blue: Float = 0
        var luminance: [Float] = []
        luminance.reserveCapacity(49)
        for dy in -3...3 {
            let row = base + (y + dy) * stride
            for dx in -3...3 {
                let pixel = row + (x + dx) * 4
                let b = Float(pixel[0]) / 255, g = Float(pixel[1]) / 255, r = Float(pixel[2]) / 255
                red += r
                green += g
                blue += b
                luminance.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }
        red /= 49
        green /= 49
        blue /= 49
        let mean = luminance.reduce(0, +) / 49
        let deviation = (luminance.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 49).squareRoot()
        let (hue, saturation) = hueAndSaturation(red, green, blue)
        return Sample(hue: hue, saturation: saturation, contrast: deviation)
    }

    private func hueAndSaturation(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float) {
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        guard high > 0, range > 0.0001 else { return (0, 0) }
        var hue: Float
        if high == r { hue = (g - b) / range } else if high == g { hue = 2 + (b - r) / range } else { hue = 4 + (r - g) / range }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, range / high)
    }

    private func save(_ pixels: CVPixelBuffer, to url: URL) {
        let image = CIImage(cvPixelBuffer: pixels)
        let context = CIContext()
        try? context.writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

// MARK: - Driving the viewer

@MainActor
final class Driver {
    let options: Options
    let recorder = Recorder()
    var stream: SCStream?
    var backdrop: NSWindow?
    let photos: [URL]
    let bundleID: String

    init(options: Options) {
        self.options = options
        photos = ((try? FileManager.default.contentsOfDirectory(at: options.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        bundleID = Bundle(url: options.app)?.bundleIdentifier ?? ""
    }

    /// A grey sheet behind everything, so a colourful wallpaper can't pass for a photo.
    func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.45, alpha: 1)
        // Below ordinary windows: a viewer that opens without becoming active is still on top of it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        backdrop = window
    }

    func startRecording() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 6
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "frames", qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    func quitViewer() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
        for _ in 0..<100 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            await pause(0.05)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.forceTerminate() }
        await pause(0.8)
    }

    /// Launches the viewer with the first photo, the way a double-click in Finder does. Returns the start time.
    func launchViewer() async throws -> Double {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Don't reopen whatever windows the previous run left: every run starts clean.
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let files = options.openAll ? photos : [photos[0]]
        let start = now()
        _ = try await NSWorkspace.shared.open(files, withApplicationAt: options.app, configuration: configuration)
        return start
    }

    var viewerPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// Same window size for every app, so each decodes for the same area.
    func resizeViewerWindow() -> Bool {
        guard let pid = viewerPID else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value else { return false }
        var position = CGPoint(x: 20, y: 40)
        var size = CGSize(width: 1400, height: 870)
        let element = window as! AXUIElement
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString,
                                                 AXValueCreate(.cgPoint, &position)!) == .success
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString,
                                                   AXValueCreate(.cgSize, &size)!) == .success
        return moved && resized
    }

    func activateViewer() async {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        await pause(0.4)
    }

    @discardableResult
    func press(_ key: CGKeyCode, autorepeat: Bool = false, release: Bool = true) -> Double {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!
        if autorepeat { down.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        let time = now()
        down.post(tap: .cghidEventTap)
        if release { CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!.post(tap: .cghidEventTap) }
        return time
    }

    func releaseKey(_ key: CGKeyCode) -> Double {
        let time = now()
        CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: false)!
            .post(tap: .cghidEventTap)
        return time
    }

    /// How long a change on screen takes to reach the recording: the backdrop turns a photo's colour at a
    /// known moment. Every app's numbers include this delay; it isn't the app's.
    func calibrate() async -> [Double] {
        guard let backdrop else { return [] }
        var delays: [Double] = []
        for step in 0..<10 {
            let index = 150 + step
            let (r, g, b) = rgb(hue: Double(hue(ofPhoto: index)), saturation: 0.7, value: 0.72)
            let start = now()
            backdrop.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            backdrop.display()
            CATransaction.flush()
            await pause(0.3)
            if let frame = recorder.all.first(where: { $0.time >= start && $0.shows(index) }) {
                delays.append((frame.time - start) * 1000)
            }
        }
        backdrop.backgroundColor = NSColor(white: 0.45, alpha: 1)
        backdrop.display()
        return delays
    }

    func snapshot(_ name: String) async {
        guard let folder = options.snapshots else { return }
        recorder.snapshot(to: folder.appendingPathComponent(name + ".png"))
        await pause(0.2)
    }
}

// MARK: - Measurements

/// Time from `start` until photo `index` is on screen, and until it's sharp (85% of the contrast it
/// settles at before `end`). Nil if it never showed up.
func latency(of index: Int, after start: Double, until end: Double, in frames: [Frame]) -> (visible: Double?, sharp: Double?) {
    let window = frames.filter { $0.time >= start && $0.time <= end }
    guard let firstShown = window.first(where: { $0.shows(index) }) else { return (nil, nil) }
    let settled = window.last(where: { $0.shows(index) })!.photo(index).contrast
    let sharp = window.first { $0.time >= firstShown.time && $0.shows(index) && $0.photo(index).contrast >= settled * 0.85 }
    return ((firstShown.time - start) * 1000, sharp.map { ($0.time - start) * 1000 })
}

func summary(_ values: [Double]) -> [String: Double] {
    guard !values.isEmpty else { return [:] }
    let sorted = values.sorted()
    return ["median": sorted[sorted.count / 2], "p95": sorted[min(sorted.count - 1, sorted.count * 95 / 100)],
            "max": sorted.last!, "min": sorted.first!]
}

@MainActor
func run(_ options: Options) async -> [String: Any] {
    if options.probeKey {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: options.nextKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: options.nextKey, keyDown: false)?.post(tap: .cghidEventTap)
        return ["posted": true, "accessibility": AXIsProcessTrusted()]
    }
    guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
        CGRequestScreenCaptureAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        return ["error": "permissions", "screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
    }
    if options.checkOnly { return ["ok": true] }

    let driver = Driver(options: options)
    guard driver.photos.count > options.steps * 2 + 100 else { return ["error": "not enough photos"] }
    driver.showBackdrop()
    do {
        try await driver.startRecording()
    } catch {
        return ["error": "recording: \(error)"]
    }
    await pause(0.5)
    await driver.quitViewer()
    let calibration = await driver.calibrate()

    // Opening: the app isn't running, a photo is double-clicked.
    var openVisible: [Double] = []
    var openSharp: [Double] = []
    for run in 1...options.openRuns {
        await driver.quitViewer()
        guard let start = try? await driver.launchViewer() else { return ["error": "launch failed"] }
        await pause(5)
        let measured = latency(of: 0, after: start, until: now(), in: driver.recorder.all)
        if let visible = measured.visible { openVisible.append(visible) }
        if let sharp = measured.sharp { openSharp.append(sharp) }
        await driver.snapshot("open-\(run)")
    }

    await driver.activateViewer()
    let resized = driver.resizeViewerWindow()
    await pause(3)
    await driver.snapshot("before-steps")

    // Stepping at a culling pace: one photo every 0.6 s.
    var index = 0
    var slow: [(Double?, Double?)] = []
    for _ in 0..<options.steps {
        index += 1
        let start = driver.press(options.nextKey)
        await pause(0.6)
        let frames = driver.recorder.all
        slow.append(latency(of: index, after: start, until: now(), in: frames))
    }

    // Skimming: one photo every 0.15 s.
    var fastStarts: [(index: Int, time: Double)] = []
    for _ in 0..<options.steps {
        index += 1
        fastStarts.append((index, driver.press(options.nextKey)))
        await pause(0.15)
    }
    await pause(1.5)
    let afterFast = driver.recorder.all
    let fast = fastStarts.map { latency(of: $0.index, after: $0.time, until: $0.time + 1.5, in: afterFast).visible }
    await driver.snapshot("after-steps")

    // Holding the key: one press, the usual 0.3 s before repeats, then a repeat every 33 ms for 3 s.
    let holdStart = driver.press(options.nextKey, release: false)
    await pause(0.3)
    var repeats = 1
    let repeatUntil = now() + 3
    while now() < repeatUntil {
        driver.press(options.nextKey, autorepeat: true, release: false)
        repeats += 1
        await pause(0.033)
    }
    let holdEnd = driver.releaseKey(options.nextKey)
    await pause(3)
    await driver.snapshot("after-hold")
    let holdFrames = driver.recorder.all.filter { $0.time >= holdStart }
    var changes: [Double] = []
    var previousBin: Int?
    for frame in holdFrames {
        guard let bin = frame.dominantHueBin else { continue }
        if let previous = previousBin, min(abs(bin - previous), 36 - abs(bin - previous)) >= 4 { changes.append(frame.time) }
        previousBin = bin
    }
    let changesWhileHeld = changes.filter { $0 <= holdEnd }.count
    let lastChange = changes.last ?? holdEnd
    // Sharp once the photo it stopped on reaches 85% of the contrast it settles at: hues differ in how
    // much contrast their stripes have, so each photo is compared with itself.
    let settledAfterHold = holdFrames.last?.photoContrast ?? 0
    let sharpAfterHold = holdFrames.first { $0.time >= lastChange && $0.photoContrast >= settledAfterHold * 0.85 }

    await driver.quitViewer()
    try? await driver.stream?.stopCapture()

    let slowVisible = slow.compactMap(\.0), slowSharp = slow.compactMap(\.1)
    let fastVisible = fast.compactMap { $0 }
    return [
        "app": options.app.deletingPathExtension().lastPathComponent,
        "version": Bundle(url: options.app)?.infoDictionary?["CFBundleShortVersionString"] ?? "",
        "windowResized": resized,
        "openVisibleMs": openVisible, "openSharpMs": openSharp,
        "slowVisible": summary(slowVisible), "slowSharp": summary(slowSharp), "slowMissed": slow.count - slowVisible.count,
        "fastVisible": summary(fastVisible), "fastMissed": fast.count - fastVisible.count,
        "captureDelayMs": summary(calibration),
        "holdKeyEvents": repeats,
        "holdPhotosShownPerSecond": Double(changesWhileHeld) / (holdEnd - holdStart),
        "holdSettleAfterReleaseMs": max(0, (lastChange - holdEnd) * 1000),
        "holdSharpAfterReleaseMs": sharpAfterHold.map { max(0, ($0.time - holdEnd) * 1000) } as Any? ?? NSNull(),
        "frames": driver.recorder.all.count,
    ]
}

// MARK: - Main

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = Options(CommandLine.arguments)
        Task { @MainActor in
            let result = await run(options)
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: options.output)
            exit(result["error"] == nil ? 0 : 2)
        }
    }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

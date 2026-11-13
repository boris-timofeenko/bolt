// viewerbench: how fast does a photo viewer show photos? Measured from a screen recording,
// so any app can be compared the same way: Bolt, XnView MP, Preview.
//
// Runs as a child of BoltBench.app, which holds the Screen Recording and Accessibility grants.
//
// Two ways to tell what is on screen:
//
// - By colour (default). Photos come from make-bench-photos.swift: photo i is filled with hue
//   frac(i × 0.618) and fine stripes. A photo is "visible" when its hue covers part of the screen, and
//   "sharp" when the stripes are there: the 320 px embedded thumbnail that viewers show first has none.
//
// - Generic (--generic), for any photos. Frames of the recording are compared with each other in the
//   middle of the viewer's window (no toolbars, title or status bar): each frame becomes a grid of cells,
//   each cell with its mean colour and its fine detail (mean luminance step between neighbouring pixels).
//   After a press at t0 the photo has "appeared" in the first frame that differs from the steady picture
//   before t0 by more than half of the difference between the old and the new photo, and is "sharp" from
//   the first frame on which it matches the new photo's settled picture and keeps at least 90% of its
//   detail: a blurred preview shown first doesn't count. The settled picture of every photo is recorded
//   at the end of the run, by walking the viewer back over all photos it showed and waiting on each.
//   Every frame's cells are saved to a trace, so the thresholds can be changed and the run re-timed:
//   `viewerbench --reanalyze run.trace --out run.json [--match 2 --sharp-detail 0.9 ...]`.
//
//   At the end of a generic run the next key is held (--hold-seconds, default 3) with the system's own
//   repeat delay and rate, on photos not shown before; then the run walks back over them one by one, so
//   each has its settled picture. Photos per second, how many were sharp while held and how soon the
//   picture is sharp after release come from those.
//
//   viewerbench --app /Applications/XnViewMP.app --folder DIR --out result.json
//               [--next-key 124] [--prev-key 123] [--open-all] [--steps 25] [--runs 3] [--snapshots DIR]
//               [--generic [--hue-check] [--trace FILE] [--hold-seconds 3]] [--check]
//   viewerbench --quicklook finder|qlmanage --folder DIR --out result.json --generic ...
//               Quick Look instead of an app: a Finder window, space, then arrows; or `qlmanage -p`
//   viewerbench --self-test        checks the generic analysis on a made-up recording

import AppKit
import ApplicationServices
import CoreImage
import CoreMedia
import CryptoKit
import ScreenCaptureKit

// MARK: - Options

struct Thresholds: Codable {
    /// "Appeared": the frame differs from the picture before the press by more than this share of the
    /// difference between the old and the new photo.
    var appear = 0.5
    /// "Sharp": at least this share of the settled picture's fine detail.
    var sharpDetail = 0.9
    /// "Sharp": mean colour difference from the settled picture, in 0–255 levels per channel, at most this.
    var match = 2.0
    /// Two photos closer than this look alike at the cells' resolution: such a step isn't timed.
    var minChange = 4.0
    /// A picture is settled when nothing in the measured area changed for this long, seconds.
    var settle = 0.25
}

struct Options {
    var app = URL(fileURLWithPath: "/")
    var folder = URL(fileURLWithPath: "/")
    var output = URL(fileURLWithPath: "/dev/stdout")
    var nextKey: CGKeyCode = 124
    var previousKeyOption: CGKeyCode?
    /// Preview only pages through files that were opened together.
    var openAll = false
    var stepsOption: Int?
    var openRuns = 3
    var snapshots: URL?
    var checkOnly = false
    /// Posts one press of the next key, to see whether key events reach other apps.
    var probeKey = false
    /// Only the cold-open runs, for tuning startup.
    var openOnly = false
    /// Environment for the launched viewer, e.g. BOLT_LAUNCH_TIMELINE=/tmp/timeline.
    var launchEnvironment: [String: String] = [:]
    /// Compares frames with each other instead of reading the synthetic photos' colours.
    var generic = false
    /// With --generic on synthetic photos: also time every step by colour and stripes, for comparison.
    var hueCheck = false
    var trace: URL?
    var reanalyze: URL?
    var thresholds = Thresholds()
    /// Quick Look instead of an app: "finder" (a Finder window, the space bar, then arrows, the way people
    /// use it) or "qlmanage" (`qlmanage -p` with all the photos, the fallback).
    var quickLook: String?
    /// Generic runs: how long the next key is held, seconds; 0 skips the held-key part.
    var holdSeconds = 3.0
    /// Checks the generic analysis on a made-up recording and exits.
    var selfTest = false
    /// Posts ⌘ ⇧ ⌥ ⌃ key-ups first (with --probe-key: before its key), to clear a modifier left down.
    var releaseModifiers = false
    /// Only saves one frame of the screen to this file (JPEG), to see what is on screen.
    var screenshot: URL?
    /// Parts of the viewer's window left out when timing the opening, as fractions of the window
    /// (x, y, width, height): ApolloOne's trial notice sits on the photo for a few seconds after launch.
    var openMasks: [CGRect] = []
    /// What the results call the viewer, instead of the app's name: two builds of one app.
    var label: String?
    /// Generic runs: each launch gets BOLT_LAUNCH_TIMELINE=<this>/open-<n>, Bolt's own startup timeline.
    var timeline: URL?
    /// Generic runs: seconds between the start of the recording and the first opening.
    var openDelay = 0.0
    /// Opens each of these photos of the folder on its own, waits --still-wait seconds and saves the
    /// screen as PNG into --snapshots: how each viewer shows the same photo.
    var stills: [String] = []
    var stillWait = 3.0

    var steps: Int { stepsOption ?? (generic ? 30 : 25) }

    /// What the results call the viewer.
    var viewerName: String {
        if let label { return label }
        return switch quickLook {
        case "finder": "QuickLook"
        case "qlmanage": "qlmanage"
        default: app.deletingPathExtension().lastPathComponent
        }
    }

    var previousKey: CGKeyCode {
        if let previousKeyOption { return previousKeyOption }
        switch nextKey {
        case 124: return 123 // → / ←
        case 125: return 126 // ↓ / ↑
        default: return nextKey
        }
    }

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--app": app = URL(fileURLWithPath: iterator.next() ?? "")
            case "--folder": folder = URL(fileURLWithPath: iterator.next() ?? "")
            case "--out": output = URL(fileURLWithPath: iterator.next() ?? "")
            case "--next-key": nextKey = CGKeyCode(iterator.next().flatMap(Int.init) ?? 124)
            case "--prev-key": previousKeyOption = iterator.next().flatMap(Int.init).map { CGKeyCode($0) }
            case "--open-all": openAll = true
            case "--steps": stepsOption = iterator.next().flatMap(Int.init)
            case "--runs": openRuns = iterator.next().flatMap(Int.init) ?? openRuns
            case "--snapshots": snapshots = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--check": checkOnly = true
            case "--probe-key": probeKey = true
            case "--open-only": openOnly = true
            case "--launch-env":
                let pair = (iterator.next() ?? "").split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { launchEnvironment[pair[0]] = pair[1] }
            case "--generic": generic = true
            case "--hue-check": hueCheck = true
            case "--trace": trace = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--reanalyze": reanalyze = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--appear": thresholds.appear = iterator.next().flatMap(Double.init) ?? thresholds.appear
            case "--sharp-detail": thresholds.sharpDetail = iterator.next().flatMap(Double.init) ?? thresholds.sharpDetail
            case "--match": thresholds.match = iterator.next().flatMap(Double.init) ?? thresholds.match
            case "--min-change": thresholds.minChange = iterator.next().flatMap(Double.init) ?? thresholds.minChange
            case "--settle": thresholds.settle = iterator.next().flatMap(Double.init) ?? thresholds.settle
            case "--quicklook": quickLook = iterator.next()
            case "--label": label = iterator.next()
            case "--timeline": timeline = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--open-delay": openDelay = iterator.next().flatMap(Double.init) ?? openDelay
            case "--stills": stills = (iterator.next() ?? "").split(separator: ",").map(String.init)
            case "--still-wait": stillWait = iterator.next().flatMap(Double.init) ?? stillWait
            case "--hold-seconds": holdSeconds = iterator.next().flatMap(Double.init) ?? holdSeconds
            case "--self-test": selfTest = true
            case "--release-modifiers": releaseModifiers = true
            case "--screenshot": screenshot = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--open-mask":
                let parts = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 { openMasks.append(CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])) }
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
    try? await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1e9))
}

// MARK: - What a frame shows: colour of the synthetic photos

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

// MARK: - What a frame shows: any photo (--generic)

/// A rectangle of the recording, in pixels from its top left corner, cut into square cells.
struct Region: Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var cell: Int
    /// Rows read per cell: every `rowStep`-th, to keep the cost per frame down.
    var rowStep: Int

    var columns: Int { width / cell }
    var rows: Int { height / cell }

    /// The middle of `rect` (pixels), `horizontal` and `vertical` as fractions of its size.
    init(middleOf rect: CGRect, horizontal: ClosedRange<Double>, vertical: ClosedRange<Double>,
         cell: Int, rowStep: Int, within bounds: CGSize) {
        let left = max(Int(rect.minX + rect.width * horizontal.lowerBound), 0)
        let top = max(Int(rect.minY + rect.height * vertical.lowerBound), 0)
        let right = min(Int(rect.minX + rect.width * horizontal.upperBound), Int(bounds.width) - 1)
        let bottom = min(Int(rect.minY + rect.height * vertical.upperBound), Int(bounds.height) - 2)
        x = left
        y = top
        width = max((right - left) / cell, 1) * cell
        height = max((bottom - top) / cell, 1) * cell
        self.cell = cell
        self.rowStep = rowStep
    }

    /// Cells lying wholly inside `rect` (pixels) and clear of every rectangle in `covered`.
    func cells(inside rect: CGRect, clearOf covered: [CGRect] = []) -> [Int] {
        var result: [Int] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let cellRect = CGRect(x: x + column * cell, y: y + row * cell, width: cell, height: cell)
                if rect.contains(cellRect), !covered.contains(where: { $0.intersects(cellRect) }) {
                    result.append(row * columns + column)
                }
            }
        }
        return result
    }

    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One frame of the recording seen through a region: per cell the mean colour and the fine detail.
struct Look {
    let time: Double
    let region: Int
    /// R, G, B per cell, 0–255.
    let colors: [UInt8]
    /// Mean absolute luminance step to the right and down neighbour, per cell, 0–255.
    let detail: [Float]

    func sameAs(_ other: Look) -> Bool {
        region == other.region && colors == other.colors && detail == other.detail
    }
}

/// Mean colour difference per channel, 0–255, over `cells` (all if nil).
func difference(_ a: Look, _ b: Look, _ cells: [Int]?) -> Double {
    var total = 0
    var count = 0
    a.colors.withUnsafeBufferPointer { x in
        b.colors.withUnsafeBufferPointer { y in
            if let cells {
                for cell in cells {
                    for channel in 0..<3 { total += abs(Int(x[cell * 3 + channel]) - Int(y[cell * 3 + channel])) }
                }
                count = cells.count * 3
            } else {
                for i in 0..<min(x.count, y.count) { total += abs(Int(x[i]) - Int(y[i])) }
                count = min(x.count, y.count)
            }
        }
    }
    return Double(total) / Double(max(count, 1))
}

func detail(_ look: Look, _ cells: [Int]?) -> Double {
    guard let cells else { return Double(look.detail.reduce(0, +)) / Double(max(look.detail.count, 1)) }
    return cells.reduce(0.0) { $0 + Double(look.detail[$1]) } / Double(max(cells.count, 1))
}

/// Cells of a region in one frame. `base` points at BGRA pixels.
func describe(_ base: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, region: Region)
    -> (colors: [UInt8], detail: [Float])? {
    guard region.x >= 0, region.y >= 0, region.x + region.width + 1 <= width,
          region.y + region.height + 1 <= height else { return nil }
    let columns = region.columns, rows = region.rows, cell = region.cell
    var sums = [Int](repeating: 0, count: columns * rows * 4)
    sums.withUnsafeMutableBufferPointer { sums in
        for y in Swift.stride(from: 0, to: rows * cell, by: region.rowStep) {
            let row = base + (region.y + y) * stride + region.x * 4
            let below = row + stride
            let cellRow = (y / cell) * columns
            for column in 0..<columns {
                let target = (cellRow + column) * 4
                var red = 0, green = 0, blue = 0, steps = 0
                var previous = -1
                for x in (column * cell)..<((column + 1) * cell) {
                    let pixel = row + x * 4
                    let b = Int(pixel[0]), g = Int(pixel[1]), r = Int(pixel[2])
                    let luma = (r * 54 + g * 183 + b * 19) >> 8
                    let under = below + x * 4
                    let lumaBelow = (Int(under[2]) * 54 + Int(under[1]) * 183 + Int(under[0]) * 19) >> 8
                    red += r
                    green += g
                    blue += b
                    steps += abs(lumaBelow - luma) + (previous < 0 ? 0 : abs(luma - previous))
                    previous = luma
                }
                sums[target] += red
                sums[target + 1] += green
                sums[target + 2] += blue
                sums[target + 3] += steps
            }
        }
    }
    let pixels = cell * ((cell + region.rowStep - 1) / region.rowStep)
    var colors = [UInt8](repeating: 0, count: columns * rows * 3)
    var detail = [Float](repeating: 0, count: columns * rows)
    for index in 0..<(columns * rows) {
        for channel in 0..<3 {
            colors[index * 3 + channel] = UInt8(min((sums[index * 4 + channel] + pixels / 2) / pixels, 255))
        }
        detail[index] = Float(sums[index * 4 + 3]) / Float(pixels)
    }
    return (colors, detail)
}

// MARK: - Screen recording

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var snapshotRequest: URL?
    private let columns = 48
    private let rows = 30
    private var watched: (id: Int, region: Region)?
    private var regionList: [Region] = []
    private var looks: [Look] = []

    var all: [Frame] { lock.withLock { frames } }
    var allLooks: [Look] { lock.withLock { looks } }
    var regions: [Region] { lock.withLock { regionList } }

    func lastLook(in region: Int) -> Look? {
        lock.withLock { looks.last { $0.region == region } }
    }

    func snapshot(to url: URL) {
        lock.withLock { snapshotRequest = url }
    }

    /// From now on every frame is also described by the cells of `region`; a frame whose cells are the
    /// same as the previous one's is dropped. Returns the region's number.
    @discardableResult
    func watch(_ region: Region) -> Int {
        lock.withLock {
            regionList.append(region)
            watched = (regionList.count - 1, region)
            return regionList.count - 1
        }
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
        let region = lock.withLock { watched }
        let look = region.flatMap { watched in
            describe(UnsafePointer(base), stride: stride, width: width, height: height, region: watched.region)
                .map { Look(time: time, region: watched.id, colors: $0.colors, detail: $0.detail) }
        }
        let request: URL? = lock.withLock {
            frames.append(Frame(time: time, samples: samples))
            if let look, !(looks.last?.sameAs(look) ?? false) { looks.append(look) }
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
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if url.pathExtension == "jpg" {
            try? context.writeJPEGRepresentation(of: image, to: url, colorSpace: space,
                                                 options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
        } else {
            try? context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
        }
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
    /// Size of the recorded frames, pixels.
    var captureSize = CGSize.zero
    let scale = NSScreen.main?.backingScaleFactor ?? 2

    init(options: Options) {
        self.options = options
        photos = ((try? FileManager.default.contentsOfDirectory(at: options.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "heic" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Quick Look from Finder: keys go to Finder, which has to be in front.
        bundleID = options.quickLook == "finder" ? "com.apple.finder" : Bundle(url: options.app)?.bundleIdentifier ?? ""
    }

    // MARK: Quick Look

    /// `qlmanage -p`, when that is the viewer.
    var qlmanage: Process?
    /// Added to the launch environment of the next launch.
    var extraEnvironment: [String: String] = [:]
    /// --stills: the photo the next launch opens, instead of the first one of the folder.
    var stillPhoto: URL?
    /// Windows on screen just before the space bar: Quick Look's preview is the big one that wasn't.
    var windowsBeforeQuickLook: Set<CGWindowID> = []
    var listViewSet = false

    struct ScreenWindow {
        let id: CGWindowID
        let pid: pid_t
        let owner: String
        /// Points, top left origin.
        let bounds: CGRect
        let layer: Int
    }

    func screenWindows() -> [ScreenWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int, let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return ScreenWindow(id: CGWindowID(id), pid: pid_t(pid), owner: info[kCGWindowOwnerName as String] as? String ?? "",
                                bounds: rect, layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    /// Quick Look's preview window: for qlmanage its biggest window, for Finder the biggest window that
    /// appeared after the space bar.
    func quickLookWindow() -> ScreenWindow? {
        guard qlmanage != nil || !windowsBeforeQuickLook.isEmpty else { return nil }
        return screenWindows()
            .filter { window in
                if let qlmanage { return window.pid == qlmanage.processIdentifier }
                return !windowsBeforeQuickLook.contains(window.id) && window.pid != getpid() && window.layer >= 0
                    && !["Dock", "Window Server"].contains(window.owner)
            }
            .filter { $0.bounds.width > 200 && $0.bounds.height > 200 }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// The accessibility element of an on-screen window: its app's window with the same frame.
    func element(of window: ScreenWindow) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(window.pid), kAXWindowsAttribute as CFString,
                                            &value) == .success, let elements = value as? [AXUIElement] else { return nil }
        return elements.first { frame(of: $0).map { abs($0.minX - window.bounds.minX) < 3 && abs($0.minY - window.bounds.minY) < 3
            && abs($0.width - window.bounds.width) < 3 } ?? false }
    }

    /// Frame of an accessibility window, points.
    func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Presses a window's close button. A targeted click: no keys that could land in another app.
    @discardableResult
    func close(_ element: AXUIElement) -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Selects the first photo in a Finder window of the folder and presses the space bar.
    private func openQuickLookFromFinder() async -> Double? {
        let photo = stillPhoto ?? photos[0]
        NSWorkspace.shared.activateFileViewerSelecting([photo])
        await pause(1.5)
        guard viewerIsFrontmost else { return nil }
        if !listViewSet {
            // As List (⌘2): the down and up arrows then go through the files in order. Finder remembers
            // the view for this folder.
            press(19, command: true)
            listViewSet = true
            await pause(0.8)
            NSWorkspace.shared.activateFileViewerSelecting([photo])
            await pause(0.8)
            guard viewerIsFrontmost else { return nil }
        }
        windowsBeforeQuickLook = Set(screenWindows().map(\.id))
        return press(49) // space
    }

    /// Closes the preview and the Finder window of the photo folder, by their close buttons.
    private func closeQuickLook() async {
        if let qlmanage {
            qlmanage.terminate()
            for _ in 0..<40 where qlmanage.isRunning { await pause(0.05) }
            self.qlmanage = nil
        } else if options.quickLook == "finder" {
            if let window = quickLookWindow(), !windowsBeforeQuickLook.isEmpty {
                if !(element(of: window).map(close) ?? false), viewerIsFrontmost { press(53) } // Escape
            }
            windowsBeforeQuickLook = []
            await pause(0.5)
            if let finder = viewerPID {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finder), kAXWindowsAttribute as CFString,
                                                 &value) == .success, let windows = value as? [AXUIElement] {
                    for window in windows {
                        var title: CFTypeRef?
                        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                        if (title as? String) == options.folder.lastPathComponent { close(window) }
                    }
                }
            }
        }
        await pause(0.8)
    }

    var viewerIsFrontmost: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return front == viewerPID
    }

    /// Keys go to whatever app is in front: before pressing any, the viewer has to be there.
    var lostFocus = false

    func ensureFrontmost() async -> Bool {
        if viewerIsFrontmost { return true }
        await activateViewer()
        if viewerIsFrontmost { return true }
        lostFocus = true
        return false
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
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        captureSize = CGSize(width: configuration.width, height: configuration.height)
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
        if options.quickLook != nil {
            // Finder itself stays.
            await closeQuickLook()
            return
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
        for _ in 0..<100 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            await pause(0.05)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.forceTerminate() }
        await pause(0.8)
    }

    /// Launches the viewer with the first photo, the way a double-click in Finder does. Returns the start time.
    func launchViewer() async throws -> Double {
        switch options.quickLook {
        case "finder":
            guard let start = await openQuickLookFromFinder() else { throw CocoaError(.userCancelled) }
            return start
        case "qlmanage":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            process.arguments = ["-p"] + photos.map(\.path)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let start = now()
            try process.run()
            qlmanage = process
            return start
        default: break
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Don't reopen whatever windows the previous run left: every run starts clean.
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        configuration.environment = options.launchEnvironment.merging(extraEnvironment) { $1 }
        let files = stillPhoto.map { [$0] } ?? (options.openAll ? photos : [photos[0]])
        let start = now()
        _ = try await NSWorkspace.shared.open(files, withApplicationAt: options.app, configuration: configuration)
        return start
    }

    /// Where the running viewer was launched from: two builds of one app share the bundle identifier.
    var launchedFrom: String? {
        guard options.quickLook == nil else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?
            .bundleURL?.resolvingSymlinksInPath().path
    }

    /// When the viewer's process started, on the recording's clock (seconds), from the kernel.
    func processStart(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        let wall = Double(started.tv_sec) + Double(started.tv_usec) / 1e6
        return now() - (Date().timeIntervalSince1970 - wall)
    }

    var viewerPID: pid_t? {
        if let qlmanage { return qlmanage.isRunning ? qlmanage.processIdentifier : nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    private func viewerWindow() -> AXUIElement? {
        if options.quickLook != nil { return quickLookWindow().flatMap(element(of:)) }
        guard let pid = viewerPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
            return (value as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            return windows.first
        }
        return nil
    }

    /// Same window size for every app, so each decodes for the same area.
    func resizeViewerWindow() -> Bool {
        guard let element = viewerWindow() else { return false }
        var position = CGPoint(x: 20, y: 40)
        var size = CGSize(width: 1400, height: 870)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString,
                                                 AXValueCreate(.cgPoint, &position)!) == .success
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString,
                                                   AXValueCreate(.cgSize, &size)!) == .success
        return moved && resized
    }

    /// The viewer's window in recording pixels.
    func viewerWindowFrame() -> CGRect? {
        // Quick Look's window is known to the window server even if its app doesn't answer accessibility.
        let points = options.quickLook != nil ? quickLookWindow()?.bounds : viewerWindow().flatMap(frame(of:))
        guard let points else { return nil }
        return CGRect(x: points.minX * scale, y: points.minY * scale, width: points.width * scale,
                      height: points.height * scale)
    }

    /// Other apps' windows floating over everything, such as a system alert, in recording pixels. The
    /// cells under them never change and are left out.
    func overlays() -> [(owner: String, rect: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
                  let owner = info[kCGWindowOwnerName as String] as? String, !["Dock", "Window Server"].contains(owner),
                  // Not ours, and not the viewer's own: Quick Look's preview is a floating panel of Finder.
                  (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) != getpid() && pid_t($0) != viewerPID }) ?? true,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (owner, CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                                  height: rect.height * scale))
        }
    }

    func activateViewer() async {
        if let pid = viewerPID { NSRunningApplication(processIdentifier: pid)?.activate() }
        await pause(0.4)
    }

    /// Presses a key. With `command`, ⌘ itself goes down before and up after, as on a keyboard: a key
    /// event that only carries the flag leaves the system thinking ⌘ is still held, and the next key
    /// becomes a shortcut (⌘2 then the space bar opened Spotlight).
    @discardableResult
    func press(_ key: CGKeyCode, autorepeat: Bool = false, release: Bool = true, command: Bool = false) -> Double {
        let source = CGEventSource(stateID: .hidSystemState)
        if command { CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)!.post(tap: .cghidEventTap) }
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!
        if autorepeat { down.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        if command { down.flags.insert(.maskCommand) }
        let time = now()
        down.post(tap: .cghidEventTap)
        if release {
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!
            if command { up.flags.insert(.maskCommand) }
            up.post(tap: .cghidEventTap)
        }
        if command { releaseModifiers() }
        return time
    }

    /// ⌘, ⇧, ⌥ and ⌃ up, with no flags left on.
    func releaseModifiers() {
        let source = CGEventSource(stateID: .hidSystemState)
        for key: CGKeyCode in [55, 54, 56, 60, 58, 61, 59, 62] {
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)!
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }

    func releaseKey(_ key: CGKeyCode) -> Double {
        let time = now()
        CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: false)!
            .post(tap: .cghidEventTap)
        return time
    }

    /// How long a change on screen takes to reach the recording: the backdrop turns a photo's colour at a
    /// known moment. Every app's numbers include this delay; it isn't the app's.
    func calibrate() async -> (starts: [Double], delays: [Double]) {
        guard let backdrop else { return ([], []) }
        // Over every window while it changes colour: other apps' windows may cover the middle of the screen.
        backdrop.level = .floating
        defer { backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1) }
        var starts: [Double] = []
        var delays: [Double] = []
        for step in 0..<10 {
            let index = 150 + step
            let (r, g, b) = rgb(hue: Double(hue(ofPhoto: index)), saturation: 0.7, value: 0.72)
            let start = now()
            backdrop.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            backdrop.display()
            CATransaction.flush()
            starts.append(start)
            await pause(0.3)
            if let frame = recorder.all.first(where: { $0.time >= start && $0.shows(index) }) {
                delays.append((frame.time - start) * 1000)
            }
        }
        backdrop.backgroundColor = NSColor(white: 0.45, alpha: 1)
        backdrop.display()
        await pause(0.2)
        return (starts, delays)
    }

    private var marker: NSWindow?

    /// Changes a few pixels in the corner of the screen, so the recording gets a frame of what is on
    /// screen now: it only delivers frames when something changed.
    func nudge() async {
        if marker == nil, let screen = NSScreen.main {
            let window = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 4, height: 4),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            marker = window
        }
        for white in [0.2, 0.6] {
            marker?.backgroundColor = NSColor(white: white, alpha: 1)
            marker?.orderFrontRegardless()
            marker?.display()
            await pause(0.1)
        }
    }

    func snapshot(_ name: String) async {
        guard let folder = options.snapshots else { return }
        recorder.snapshot(to: folder.appendingPathComponent(name))
        await pause(0.2)
    }

    // Generic runs: steps through the folder at a steady pace and notes each press.

    var index = 0
    var events: [StepEvent] = []

    /// Presses `key` `count` times, one press every `interval` seconds, then waits `settle` more.
    /// `step` is +1 for the next photo, −1 for the previous one.
    func pace(_ scenario: String, count: Int, interval: Double, key: CGKeyCode, step: Int,
              settle: Double) async {
        guard count > 0, await ensureFrontmost() else { return }
        var next = now()
        let first = events.count
        for _ in 0..<count {
            await pause(next - now())
            // Never type into another app: stop as soon as the viewer isn't in front.
            guard viewerIsFrontmost else {
                lostFocus = true
                break
            }
            index += step
            let t0 = press(key)
            events.append(StepEvent(scenario: scenario, index: index, t0: t0, end: 0))
            next = t0 + interval
        }
        await pause(next - now() + settle)
        for i in first..<events.count {
            events[i].end = i + 1 < events.count ? events[i + 1].t0 : now()
        }
    }

    /// The picture in `region` once nothing in it has changed for `quiet` seconds; nil after `timeout`.
    func settledLook(in region: Int, quiet: Double = 0.3, timeout: Double) async -> Look? {
        let deadline = now() + timeout
        while true {
            if let last = recorder.lastLook(in: region), now() - last.time >= quiet { return last }
            if now() > deadline { return nil }
            await pause(0.05)
        }
    }

    /// Holds the next key down with the system's own repeat delay and rate, on photos not shown yet, then
    /// walks back over what it passed, one step at a time, until the picture is the one the hold started
    /// from. Each photo passed gets its settled picture to compare with; where the viewer actually ended
    /// up doesn't need to be known.
    func hold(seconds: Double, region: Int, from fresh: Int) async -> HoldEvent? {
        // To photos not shown yet: separate presses past the furthest one, then wait for the viewer.
        await pace("skip", count: fresh - index, interval: 0.15, key: options.nextKey, step: 1, settle: 0)
        guard !lostFocus, let anchor = await settledLook(in: region, quiet: 1.0, timeout: 30),
              await ensureFrontmost() else { return nil }
        let delay = NSEvent.keyRepeatDelay, interval = NSEvent.keyRepeatInterval
        let start = press(options.nextKey, release: false)
        var keyEvents = 1
        var next = start + delay
        while next < start + seconds {
            await pause(next - now())
            guard viewerIsFrontmost else {
                lostFocus = true
                break
            }
            press(options.nextKey, autorepeat: true, release: false)
            keyEvents += 1
            next += interval
        }
        if !lostFocus { await pause(start + seconds - now()) }
        let end = releaseKey(options.nextKey)
        if lostFocus { return nil }
        let settled = await settledLook(in: region, quiet: 1.0, timeout: 15)
        var event = HoldEvent(start: start, end: end, keyEvents: keyEvents, repeatDelay: delay, repeatInterval: interval,
                              settledAt: settled?.time ?? now())
        for _ in 0..<(keyEvents + 5) {
            guard let current = await settledLook(in: region, quiet: 0.3, timeout: 3) else { break }
            if events.last?.scenario == "holdref" { events[events.count - 1].end = now() }
            if difference(current, anchor, nil) <= options.thresholds.match {
                event.anchorReached = true
                break
            }
            await pace("holdref", count: 1, interval: 0.6, key: options.previousKey, step: -1, settle: 0)
            if lostFocus { break }
            event.walkedBack += 1
        }
        return event
    }
}

// MARK: - Measurements by colour

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
            "max": sorted.last!, "min": sorted.first!, "count": Double(sorted.count)]
}

@MainActor
func run(_ options: Options) async -> [String: Any] {
    if options.releaseModifiers {
        Driver(options: options).releaseModifiers()
        if !options.probeKey { return ["released": true, "accessibility": AXIsProcessTrusted()] }
    }
    if options.probeKey {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: options.nextKey, keyDown: down)
            if options.releaseModifiers { event?.flags = [] }
            event?.post(tap: .cghidEventTap)
        }
        return ["posted": true, "accessibility": AXIsProcessTrusted()]
    }
    guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
        CGRequestScreenCaptureAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        return ["error": "permissions", "screen": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
    }
    if options.checkOnly { return ["ok": true] }
    if let screenshot = options.screenshot {
        let driver = Driver(options: options)
        do { try await driver.startRecording() } catch { return ["error": "recording: \(error)"] }
        await driver.nudge()
        driver.recorder.snapshot(to: screenshot)
        await driver.nudge()
        await pause(0.3)
        try? await driver.stream?.stopCapture()
        return ["saved": screenshot.path]
    }
    if !options.stills.isEmpty { return await runStills(options) }
    if options.generic { return await runGeneric(options) }

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
    let calibration = await driver.calibrate().delays

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
        await driver.snapshot("open-\(run).png")
    }

    if options.openOnly {
        await driver.quitViewer()
        try? await driver.stream?.stopCapture()
        return ["app": options.app.deletingPathExtension().lastPathComponent,
                "openVisibleMs": openVisible, "openSharpMs": openSharp,
                "openVisible": summary(openVisible), "openSharp": summary(openSharp),
                "captureDelayMs": summary(calibration)]
    }

    await driver.activateViewer()
    let resized = driver.resizeViewerWindow()
    await pause(3)
    await driver.snapshot("before-steps.png")

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
    await driver.snapshot("after-steps.png")

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
    await driver.snapshot("after-hold.png")
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

// MARK: - Generic runs

struct StepEvent: Codable {
    var scenario: String
    var index: Int
    var t0: Double
    /// The next press, or the end of the pause after the last one.
    var end: Double
    var hueVisibleMs: Double?
    var hueSharpMs: Double?
}

/// The held key: when it went down and up, how many key events it made, and the walk back afterwards.
struct HoldEvent: Codable {
    var start: Double
    var end: Double
    var keyEvents: Int
    var repeatDelay: Double
    var repeatInterval: Double
    /// When the picture stopped changing after the key was released.
    var settledAt: Double
    /// Steps walked back to the photo the hold started from, and whether it was reached.
    var walkedBack = 0
    var anchorReached = false
}

struct OpenEvent: Codable {
    var start: Double
    var end: Double
    /// The viewer's process and when it started, on the same clock as start.
    var pid: Int32?
    var processStart: Double?
    /// The viewer's window when the wait ended, recording pixels.
    var window: CGRect?
    var hueVisibleMs: Double?
    var hueSharpMs: Double?
}

/// Everything a generic run recorded, enough to time it again with other thresholds.
struct Trace: Codable {
    struct StoredLook: Codable {
        var time: Double
        var region: Int
        var colors: Data
        var detail: Data
    }

    var app = ""
    var version = ""
    var binary = ""
    var folder = ""
    var startedAt = ""
    var regions: [Region] = []
    var looks: [StoredLook] = []
    var openRegion = -1
    var stepRegion = -1
    var window: CGRect?
    /// Windows floating over the viewer while it was measured; optional so older traces still load.
    var overlays: [CGRect]?
    var overlayOwners: [String]?

    /// Floating windows that cover part of the measured window. One that covers all of it must be
    /// see-through, or the run would have recorded no changes: such overlays are kept out of the mask.
    var masks: [CGRect] {
        (overlays ?? []).filter { overlay in window.map { !overlay.contains($0) } ?? true }
    }
    var windowResized = false
    var frames = 0
    var calibrationStarts: [Double] = []
    var calibrationHueMs: [Double] = []
    var opens: [OpenEvent] = []
    var steps: [StepEvent] = []
    var hold: HoldEvent?
    /// --open-mask, fractions of the window.
    var openMasks: [CGRect]?
    /// Where the viewer ran from, checked after every launch and before the last quit.
    var launched: [String]?

    /// The middle of a window where an opening is timed, and the cells of `region` in it that nothing
    /// covered. Shared by the run (to know when the opening has settled) and the analysis.
    func openCells(window: CGRect, in region: Region) -> [Int] {
        let middle = CGRect(x: window.minX + window.width * 0.3, y: window.minY + window.height * 0.25,
                            width: window.width * 0.4, height: window.height * 0.5)
        let masked = (openMasks ?? []).map {
            CGRect(x: window.minX + window.width * $0.minX, y: window.minY + window.height * $0.minY,
                   width: window.width * $0.width, height: window.height * $0.height)
        }
        return region.cells(inside: middle, clearOf: masks + masked)
    }

    func decodedLooks() -> [Look] {
        looks.map { stored in
            var detail = [Float](repeating: 0, count: stored.detail.count / 4)
            _ = detail.withUnsafeMutableBytes { stored.detail.copyBytes(to: $0) }
            return Look(time: stored.time, region: stored.region, colors: [UInt8](stored.colors), detail: detail)
        }
    }

    static func store(_ look: Look) -> StoredLook {
        StoredLook(time: look.time, region: look.region, colors: Data(look.colors),
                   detail: look.detail.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

/// The scenarios, in the order they run. Photos are fresh in each: the index only grows, except while
/// stepping back.
let scenarioOrder = ["1000ms", "400ms", "150ms", "runup", "back"]

@MainActor
func runGeneric(_ options: Options) async -> [String: Any] {
    if options.quickLook == nil, !FileManager.default.fileExists(atPath: options.app.path) {
        return ["error": "no app at \(options.app.path)", "skipped": true]
    }
    let driver = Driver(options: options)
    guard driver.photos.count >= 110 else { return ["error": "not enough photos, need 110"] }
    var trace = Trace()
    trace.app = options.viewerName
    trace.version = options.quickLook != nil ? ProcessInfo.processInfo.operatingSystemVersionString
        : Bundle(url: options.app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    trace.folder = options.folder.path
    trace.startedAt = ISO8601DateFormatter().string(from: Date())
    if !options.openMasks.isEmpty { trace.openMasks = options.openMasks }
    if let executable = Bundle(url: options.app)?.executableURL,
       let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path) {
        trace.binary = "\(executable.lastPathComponent) \(attributes[.size] ?? 0) bytes, \(attributes[.modificationDate] ?? "")"
        if let data = FileManager.default.contents(atPath: executable.path) {
            trace.binary += ", sha256 " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    driver.showBackdrop()
    do {
        try await driver.startRecording()
    } catch {
        return ["error": "recording: \(error)"]
    }
    await pause(0.5)
    await driver.quitViewer()

    // Before the window exists only a wide middle of the screen is watched, coarsely; each opening is
    // then timed over the cells that fall in the middle of the window it opened.
    trace.openRegion = driver.recorder.watch(Region(
        middleOf: CGRect(origin: .zero, size: driver.captureSize), horizontal: 0.15...0.85, vertical: 0.1...0.9,
        cell: 48, rowStep: 4, within: driver.captureSize))
    let calibration = await driver.calibrate()
    trace.calibrationStarts = calibration.starts
    trace.calibrationHueMs = calibration.delays

    if options.openDelay > 0 { await pause(options.openDelay) }
    for run in 1...options.openRuns {
        await driver.quitViewer()
        if let timeline = options.timeline {
            let folder = timeline.appendingPathComponent("open-\(run)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            driver.extraEnvironment["BOLT_LAUNCH_TIMELINE"] = folder.path
        }
        guard let start = try? await driver.launchViewer() else { return ["error": "launch failed"] }
        // Until the middle of the window has been still for 1.5 s: Preview opening 200 real photos keeps
        // redrawing for longer than 7 s. At least 5 s, at most 25.
        await pause(5)
        if let error = checkLaunched(driver, &trace) { return ["error": error] }
        // A viewer still busy opening files may not answer accessibility requests at once.
        var frame = driver.viewerWindowFrame()
        for _ in 0..<10 where frame == nil {
            await pause(0.3)
            frame = driver.viewerWindowFrame()
        }
        let region = driver.recorder.regions[trace.openRegion]
        let cells = trace.openCells(window: frame ?? region.bounds, in: region)
        while now() - start < 25 {
            let looks = driver.recorder.allLooks.filter { $0.region == trace.openRegion }
            guard let changed = lastChange(looks, cells: cells, from: start, to: now()), now() - changed < 1.5 else { break }
            await pause(0.25)
        }
        let end = now()
        var event = OpenEvent(start: start, end: end, window: frame)
        if options.quickLook == nil, let pid = driver.viewerPID {
            event.pid = pid
            event.processStart = driver.processStart(pid)
        }
        let floating = driver.overlays()
        trace.overlays = (trace.overlays ?? []) + floating.map(\.rect)
        trace.overlayOwners = (trace.overlayOwners ?? []) + floating.map(\.owner)
        if options.hueCheck {
            let measured = latency(of: 0, after: start, until: end, in: driver.recorder.all)
            event.hueVisibleMs = measured.visible
            event.hueSharpMs = measured.sharp
        }
        trace.opens.append(event)
        if run == 1 { await driver.snapshot("\(trace.app)-open.jpg") }
    }

    if options.openOnly {
        if let error = checkLaunched(driver, &trace) { return ["error": error] }
        await driver.quitViewer()
        try? await driver.stream?.stopCapture()
        trace.frames = driver.recorder.all.count
        trace.regions = driver.recorder.regions
        trace.looks = driver.recorder.allLooks.map(Trace.store)
        let traceURL = options.trace ?? options.output.deletingPathExtension().appendingPathExtension("trace")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(trace).write(to: traceURL)
        return analyze(trace, options.thresholds)
    }

    await driver.activateViewer()
    trace.windowResized = driver.resizeViewerWindow()
    await pause(0.5)
    guard let window = driver.viewerWindowFrame() else { return ["error": "no viewer window"] }
    trace.window = window
    let floating = driver.overlays()
    trace.overlays = (trace.overlays ?? []) + floating.map(\.rect)
    trace.overlayOwners = (trace.overlayOwners ?? []) + floating.map(\.owner)
    // The middle of the window: clear of title bars, toolbars, status bars and Preview's sidebar, and
    // inside the photo whether it's landscape or portrait.
    trace.stepRegion = driver.recorder.watch(Region(
        middleOf: window, horizontal: 0.35...0.65, vertical: 0.2...0.8, cell: 24, rowStep: 2,
        within: driver.captureSize))
    await pause(2.3)
    await driver.nudge()
    await driver.snapshot("\(trace.app)-before-steps.jpg")

    let next = options.nextKey, back = options.previousKey
    await driver.pace("1000ms", count: options.steps, interval: 1.0, key: next, step: 1, settle: 0.5)
    await driver.pace("400ms", count: options.steps, interval: 0.4, key: next, step: 1, settle: 1.2)
    await driver.pace("150ms", count: options.steps, interval: 0.15, key: next, step: 1, settle: 1.5)
    // Turning back: a run-up forward at a culling pace, then back over the same photos.
    await driver.pace("runup", count: 10, interval: 0.6, key: next, step: 1, settle: 0)
    await driver.pace("back", count: 10, interval: 0.6, key: back, step: -1, settle: 1.0)
    await driver.snapshot("\(trace.app)-after-steps.jpg")

    // The settled picture of every photo shown: forward to the furthest, then back to the first.
    let furthest = driver.events.map(\.index).max() ?? 0
    await driver.pace("reference", count: furthest - driver.index, interval: 0.6, key: next, step: 1, settle: 0)
    await driver.pace("reference", count: furthest, interval: 0.6, key: back, step: -1, settle: 0.6)

    // The held key, last: on photos past all the others, so nothing it shows was decoded before.
    if options.holdSeconds > 0, !driver.lostFocus {
        trace.hold = await driver.hold(seconds: options.holdSeconds, region: trace.stepRegion, from: furthest + 1)
    }
    await driver.snapshot("\(trace.app)-after-hold.jpg")

    if let error = checkLaunched(driver, &trace) { return ["error": error] }
    await driver.quitViewer()
    if driver.lostFocus {
        try? await driver.stream?.stopCapture()
        return ["error": "\(trace.app) left the front while keys were being pressed; the run was stopped"]
    }
    try? await driver.stream?.stopCapture()

    let frames = driver.recorder.all
    trace.frames = frames.count
    trace.steps = driver.events
    if options.hueCheck {
        for i in trace.steps.indices where scenarioOrder.contains(trace.steps[i].scenario) {
            let event = trace.steps[i]
            let measured = latency(of: event.index, after: event.t0, until: event.t0 + 1.5, in: frames)
            trace.steps[i].hueVisibleMs = measured.visible
            trace.steps[i].hueSharpMs = measured.sharp
        }
    }
    trace.regions = driver.recorder.regions
    trace.looks = driver.recorder.allLooks.map(Trace.store)

    let traceURL = options.trace ?? options.output.deletingPathExtension().appendingPathExtension("trace")
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try? encoder.encode(trace).write(to: traceURL)
    return analyze(trace, options.thresholds)
}

// MARK: - Timing a generic run

struct StepTiming {
    var appeared: Double?
    var sharp: Double?
    /// How long a blurred version of the new photo was up before the sharp one, or until the viewer
    /// moved on if it never got sharp.
    var blurred: Double?
    /// The two photos look alike in the measured area: the step can't be timed.
    var indistinct = false
    /// Frames between "appeared" and "sharp" that are neither blurred nor the settled picture.
    var otherFrames = 0
}

/// When `cells` last changed between `start` and `end`: the time of the last look there that differs from
/// the one before it. Changes elsewhere on screen (another app's clock, say) don't count.
func lastChange(_ looks: [Look], cells: [Int]?, from start: Double, to end: Double) -> Double? {
    var k = looks.count - 1
    while k > 0, looks[k].time > end { k -= 1 }
    while k > 0, looks[k].time >= start {
        if difference(looks[k], looks[k - 1], cells) > 0 { return looks[k].time }
        k -= 1
    }
    return nil
}

/// Index of the last look before `time`.
func lastIndex(before time: Double, in looks: [Look]) -> Int? {
    var low = 0, high = looks.count
    while low < high {
        let middle = (low + high) / 2
        if looks[middle].time < time { low = middle + 1 } else { high = middle }
    }
    return low > 0 ? low - 1 : nil
}

/// Times a change from the steady picture before `start` to `final`, over `looks[from...]` up to `until`.
/// `belongs` says whether a frame shows the new photo at all (for the generic steps: whether it's
/// nearer to this photo's settled picture than to its neighbours').
func timeChange(_ looks: [Look], start: Double, until: Double, final: Look, cells: [Int]?,
                thresholds: Thresholds, belongs: (Look) -> Bool = { _ in true }) -> StepTiming {
    var timing = StepTiming()
    guard let beforeIndex = lastIndex(before: start, in: looks) else { return timing }
    let before = looks[beforeIndex]
    let change = difference(before, final, cells)
    if change < thresholds.minChange {
        timing.indistinct = true
        return timing
    }
    let finalDetail = detail(final, cells)
    var index = beforeIndex + 1
    while index < looks.count, looks[index].time <= until {
        let look = looks[index]
        if difference(look, before, cells) > thresholds.appear * change, belongs(look) { break }
        index += 1
    }
    guard index < looks.count, looks[index].time <= until else { return timing }
    timing.appeared = (looks[index].time - start) * 1000

    // The new photo stays up until a frame shows something else, or until the end of the window.
    var leave = index + 1
    while leave < looks.count, looks[leave].time <= until, belongs(looks[leave]) { leave += 1 }
    let leaveTime = leave < looks.count ? min(looks[leave].time, until) : until
    func isSharp(_ look: Look) -> Bool {
        difference(look, final, cells) <= thresholds.match && detail(look, cells) >= thresholds.sharpDetail * finalDetail
    }
    var sharpIndex: Int?
    var k = leave - 1
    while k >= index, isSharp(looks[k]) {
        sharpIndex = k
        k -= 1
    }
    if let sharpIndex { timing.sharp = (looks[sharpIndex].time - start) * 1000 }
    let pending = index..<(sharpIndex ?? leave)
    if let blurred = pending.first(where: { detail(looks[$0], cells) < thresholds.sharpDetail * finalDetail }) {
        let until = sharpIndex.map { looks[$0].time } ?? leaveTime
        timing.blurred = (until - looks[blurred].time) * 1000
    }
    timing.otherFrames = pending.filter { detail(looks[$0], cells) >= thresholds.sharpDetail * finalDetail }.count
    return timing
}

/// The held key. Every frame from the steady picture before the key went down to the one after release
/// is matched to the nearest settled picture from the walk back; a run of frames nearest to the same
/// picture is one photo on screen. A photo counts as sharp while held if any of its frames before the
/// release matched its settled picture with 90% of its detail.
func analyzeHold(_ hold: HoldEvent, steps: [StepEvent], looks: [Look], cells: [Int]?, thresholds: Thresholds,
                 settled: (StepEvent) -> Look?) -> [String: Any] {
    let held = hold.end - hold.start
    var result: [String: Any] = [
        "keyEvents": hold.keyEvents, "repeatDelayMs": hold.repeatDelay * 1000,
        "repeatIntervalMs": hold.repeatInterval * 1000, "heldMs": held * 1000,
        "walkedBack": hold.walkedBack, "anchorReached": hold.anchorReached,
    ]
    let walk = steps.filter { $0.scenario == "holdref" }
    let walkStart = walk.first?.t0 ?? hold.settledAt + 0.01
    guard let anchorIndex = lastIndex(before: hold.start, in: looks),
          let endIndex = lastIndex(before: walkStart, in: looks), endIndex >= anchorIndex else { return result }
    let final = looks[endIndex]
    // Settled pictures from where the hold stopped back to where it started.
    // The walk's last step lands on the photo the hold started from: that one is kept once, last.
    let anchor = looks[anchorIndex]
    let walked = walk.compactMap(settled).filter { difference($0, anchor, cells) > thresholds.match } + [anchor]
    let references = [final] + walked
    result["references"] = references.count
    // How far the viewer actually moved, and whether the picture left after release is the photo it is
    // on: the walk back starts one before it, so a final picture that the walk meets k steps in is k + 1
    // photos behind.
    if hold.anchorReached { result["positionsMoved"] = hold.walkedBack }
    let behind = walked.firstIndex { difference($0, final, cells) <= thresholds.match }.map { $0 + 1 } ?? 0
    result["finalPictureBehindBy"] = behind

    func isSharp(_ look: Look, _ reference: Look) -> Bool {
        difference(look, reference, cells) <= thresholds.match
            && detail(look, cells) >= thresholds.sharpDetail * detail(reference, cells)
    }
    func nearest(_ look: Look) -> (index: Int, distance: Double) {
        references.indices.map { ($0, difference(look, references[$0], cells)) }.min { $0.1 < $1.1 }!
    }

    struct Shown {
        var start: Double
        var reference: Int
        var sharpWhileHeld = false
    }
    var shown: [Shown] = []
    var sharpTime = 0.0
    var unmatched = 0
    let window = Array(looks[anchorIndex...endIndex])
    for (k, look) in window.enumerated() {
        let match = nearest(look)
        // Neighbouring photos differ by 18 levels or more on screen; a frame this far from all of them
        // is something in between, such as a transition.
        if match.distance > 8 { unmatched += 1 }
        let sharp = isSharp(look, references[match.index])
        if shown.last?.reference != match.index { shown.append(Shown(start: look.time, reference: match.index)) }
        if sharp, look.time <= hold.end { shown[shown.count - 1].sharpWhileHeld = true }
        let from = max(look.time, hold.start)
        let to = min(k + 1 < window.count ? window[k + 1].time : walkStart, hold.end)
        // Only photos the key brought up: the one it started from was sharp long before.
        if sharp, to > from, match.index != references.count - 1 { sharpTime += to - from }
    }
    let during = shown.filter { $0.start > hold.start && $0.start <= hold.end }
    let repeating = during.filter { $0.start > hold.start + hold.repeatDelay }
    result["photosShown"] = during.count
    result["photosPerSecond"] = Double(during.count) / held
    if held > hold.repeatDelay {
        result["photosPerSecondRepeating"] = Double(repeating.count) / (held - hold.repeatDelay)
    }
    result["sharpPhotoShare"] = during.isEmpty ? 0 : Double(during.filter(\.sharpWhileHeld).count) / Double(during.count)
    result["sharpTimeShare"] = sharpTime / held  // of the time the key was down
    let after = shown.filter { $0.start > hold.end }
    result["photosAfterRelease"] = after.count
    result["lastChangeAfterReleaseMs"] = after.last.map { ($0.start - hold.end) * 1000 } ?? 0
    // Sharp after release: the first frame from which the picture stays the settled one.
    var sharpFrom: Double?
    var k = window.count - 1
    while k >= 0, isSharp(window[k], final) {
        sharpFrom = window[k].time
        k -= 1
    }
    if let sharpFrom { result["sharpAfterReleaseMs"] = max(0, (sharpFrom - hold.end) * 1000) }
    result["unmatchedFrames"] = unmatched
    return result
}

/// --stills: each photo opened on its own in a fresh launch, the window set to 1400×870 pt, then after
/// --still-wait seconds the whole screen saved as PNG. hdr-compare.swift finds the photo in it.
@MainActor
func runStills(_ options: Options) async -> [String: Any] {
    if options.quickLook == nil, !FileManager.default.fileExists(atPath: options.app.path) {
        return ["error": "no app at \(options.app.path)", "skipped": true]
    }
    guard let folder = options.snapshots else { return ["error": "--stills needs --snapshots"] }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let driver = Driver(options: options)
    var trace = Trace()
    trace.app = options.viewerName
    if let executable = Bundle(url: options.app)?.executableURL, options.quickLook == nil,
       let data = FileManager.default.contents(atPath: executable.path) {
        trace.binary = "\(executable.lastPathComponent) \(data.count) bytes, sha256 "
            + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    driver.showBackdrop()
    do { try await driver.startRecording() } catch { return ["error": "recording: \(error)"] }
    await pause(0.5)
    await driver.quitViewer()
    var shots: [[String: Any]] = []
    for name in options.stills {
        let photo = options.folder.appendingPathComponent(name)
        var shot: [String: Any] = ["photo": name]
        defer { shots.append(shot) }
        guard FileManager.default.fileExists(atPath: photo.path) else { shot["error"] = "no such photo"; continue }
        driver.stillPhoto = photo
        await driver.quitViewer()
        guard (try? await driver.launchViewer()) != nil else { shot["error"] = "launch failed"; continue }
        for _ in 0..<40 where driver.viewerWindowFrame() == nil { await pause(0.25) }
        await pause(0.5)
        if let error = checkLaunched(driver, &trace) { return ["error": error] }
        shot["resized"] = driver.resizeViewerWindow()
        await pause(options.stillWait)
        guard let window = driver.viewerWindowFrame() else { shot["error"] = "no window"; continue }
        shot["windowPx"] = [window.minX, window.minY, window.width, window.height]
        let floating = driver.overlays().filter { $0.rect.intersects(window) && !$0.rect.contains(window) }
        if !floating.isEmpty { shot["overlays"] = floating.map(\.owner) }
        let file = "\(trace.app)-\(photo.deletingPathExtension().lastPathComponent).png"
        driver.recorder.snapshot(to: folder.appendingPathComponent(file))
        await driver.nudge()
        await pause(0.5)
        shot["png"] = file
    }
    await driver.quitViewer()
    try? await driver.stream?.stopCapture()
    var result: [String: Any] = ["app": trace.app, "binary": trace.binary, "mode": "stills",
                                 "folder": options.folder.path, "stillWaitS": options.stillWait, "shots": shots]
    if let launched = trace.launched { result["launched"] = launched }
    return result
}

/// Records where the running viewer came from; an error if it isn't the app asked for.
@MainActor func checkLaunched(_ driver: Driver, _ trace: inout Trace) -> String? {
    guard let path = driver.launchedFrom else { return nil }
    if !(trace.launched ?? []).contains(path) { trace.launched = (trace.launched ?? []) + [path] }
    let wanted = driver.options.app.resolvingSymlinksInPath().path
    return path == wanted ? nil : "launched \(path), not \(wanted)"
}

func analyze(_ trace: Trace, _ thresholds: Thresholds) -> [String: Any] {
    let looks = trace.decodedLooks()
    let openLooks = looks.filter { $0.region == trace.openRegion }
    let stepLooks = looks.filter { $0.region == trace.stepRegion }
    var result: [String: Any] = [
        "app": trace.app, "version": trace.version, "binary": trace.binary, "folder": trace.folder,
        "startedAt": trace.startedAt, "mode": "generic", "windowResized": trace.windowResized,
        "frames": trace.frames, "looks": looks.count,
        "thresholds": ["appear": thresholds.appear, "sharpDetail": thresholds.sharpDetail,
                       "match": thresholds.match, "minChange": thresholds.minChange, "settle": thresholds.settle],
    ]
    if let launched = trace.launched { result["launched"] = launched }
    if let window = trace.window {
        result["windowPx"] = [window.minX, window.minY, window.width, window.height]
    }
    result["overlaysPx"] = (trace.overlays ?? []).map { [$0.minX, $0.minY, $0.width, $0.height] }
    result["overlayOwners"] = trace.overlayOwners ?? []
    result["masksPx"] = trace.masks.map { [$0.minX, $0.minY, $0.width, $0.height] }
    if trace.stepRegion >= 0 {
        let region = trace.regions[trace.stepRegion]
        result["stepRegionPx"] = [region.x, region.y, region.width, region.height]
    }

    // Recording delay, by colour and by comparing frames: the backdrop changes colour.
    let calibrationGeneric: [Double] = trace.calibrationStarts.compactMap { start in
        guard let last = lastIndex(before: start + 0.29, in: openLooks) else { return nil }
        return timeChange(openLooks, start: start, until: start + 0.29, final: openLooks[last], cells: nil,
                          thresholds: thresholds).appeared
    }
    result["captureDelayMs"] = summary(trace.calibrationHueMs)
    result["captureDelayGenericMs"] = summary(calibrationGeneric)

    // Opening from Finder.
    var openRows: [[String: Any]] = []
    if trace.openRegion >= 0 {
        let region = trace.regions[trace.openRegion]
        for event in trace.opens {
            var row: [String: Any] = [:]
            row["hueVisibleMs"] = event.hueVisibleMs
            row["hueSharpMs"] = event.hueSharpMs
            if let last = lastIndex(before: event.end, in: openLooks) {
                // The middle of the window; if the viewer never told where its window was, the middle of
                // the screen, which any window showing a photo covers.
                let window = event.window ?? region.bounds
                if event.window == nil { row["windowUnknown"] = true }
                let cells = trace.openCells(window: window, in: region)
                if !cells.isEmpty {
                    let timing = timeChange(openLooks, start: event.start, until: event.end, final: openLooks[last],
                                            cells: cells, thresholds: thresholds)
                    row["appearedMs"] = timing.appeared
                    row["sharpMs"] = timing.sharp
                    row["blurredMs"] = timing.blurred
                    // The first frame that differs from the one before the launch at all: the window.
                    if let before = lastIndex(before: event.start, in: openLooks),
                       let first = openLooks[(before + 1)...].first(where: {
                           $0.time <= event.end && difference(openLooks[before], $0, cells) >= thresholds.minChange
                       }) {
                        row["firstChangeMs"] = (first.time - event.start) * 1000
                    }
                    let changed = lastChange(openLooks, cells: cells, from: event.start, to: event.end) ?? event.start
                    row["settledForMs"] = (event.end - changed) * 1000
                    // Still changing when the wait ended: the final picture isn't known.
                    if event.end - changed < 1.0 { row["unsettled"] = true }
                    row["cells"] = cells.count
                }
            }
            if let pid = event.pid { row["pid"] = Int(pid) }
            if let started = event.processStart { row["processStartMs"] = (started - event.start) * 1000 }
            openRows.append(row)
        }
    }
    result["open"] = openRows
    if trace.stepRegion < 0, trace.steps.isEmpty { return result }

    // The settled picture of each photo: from the reference walk, else from a measured step that ended
    // settled. A picture that was still changing when the next key went down isn't used.
    // Cells of the measured area that no other window covered.
    var stepCells: [Int]?
    if trace.stepRegion >= 0, !trace.masks.isEmpty {
        let region = trace.regions[trace.stepRegion]
        let clear = region.cells(inside: region.bounds, clearOf: trace.masks)
        if clear.count < region.columns * region.rows { stepCells = clear }
        result["stepCellsCovered"] = region.columns * region.rows - clear.count
    }

    var references: [Int: Look] = [:]
    var fromSteps = 0
    func settledLook(_ event: StepEvent) -> Look? {
        guard let last = lastIndex(before: event.end, in: stepLooks), stepLooks[last].time > event.t0,
              event.end - stepLooks[last].time >= thresholds.settle else { return nil }
        return stepLooks[last]
    }
    for event in trace.steps where event.scenario == "reference" {
        if let look = settledLook(event) { references[event.index] = look }
    }
    let fromWalk = references.count
    for event in trace.steps where scenarioOrder.contains(event.scenario) && references[event.index] == nil {
        if let look = settledLook(event) {
            references[event.index] = look
            fromSteps += 1
        }
    }
    result["references"] = ["fromWalk": fromWalk, "fromSteps": fromSteps]

    var checks: [Double] = []
    var scenarios: [String: Any] = [:]
    var comparison: [String: Any] = [:]
    for scenario in scenarioOrder {
        let events = trace.steps.filter { $0.scenario == scenario }
        guard !events.isEmpty else { continue }
        var rows: [[String: Any]] = []
        var appeared: [Double] = [], sharp: [Double] = [], blurred: [Double] = []
        var notChanged = 0, notSharp = 0, indistinct = 0, otherFrames = 0, noReference = 0
        var appearedDiffs: [Double] = [], sharpDiffs: [Double] = []
        for event in events {
            guard let final = references[event.index] else {
                noReference += 1
                rows.append(["index": event.index, "noReference": true])
                continue
            }
            if let windowEnd = settledLook(event), references[event.index].map({ $0.time != windowEnd.time }) ?? false {
                checks.append(difference(windowEnd, final, stepCells))
            }
            let neighbours = (event.index - 3...event.index + 3).filter { $0 != event.index }.compactMap { references[$0] }
            let timing = timeChange(stepLooks, start: event.t0, until: event.end + 0.5, final: final, cells: stepCells,
                                    thresholds: thresholds) { look in
                let own = difference(look, final, stepCells)
                return neighbours.allSatisfy { own <= difference(look, $0, stepCells) }
            }
            var row: [String: Any] = ["index": event.index]
            if timing.indistinct {
                indistinct += 1
                row["indistinct"] = true
            } else if let shown = timing.appeared {
                appeared.append(shown)
                row["appearedMs"] = shown
                if let ready = timing.sharp { sharp.append(ready); row["sharpMs"] = ready } else { notSharp += 1 }
                if let blur = timing.blurred { blurred.append(blur); row["blurredMs"] = blur }
                otherFrames += timing.otherFrames
            } else {
                notChanged += 1
                row["notChanged"] = true
            }
            if let hue = event.hueVisibleMs {
                row["hueVisibleMs"] = hue
                if let shown = timing.appeared { appearedDiffs.append(shown - hue) }
            }
            if let hue = event.hueSharpMs {
                row["hueSharpMs"] = hue
                if let ready = timing.sharp { sharpDiffs.append(ready - hue) }
            }
            rows.append(row)
        }
        scenarios[scenario] = [
            "steps": events.count, "appeared": summary(appeared), "sharp": summary(sharp),
            "notChanged": notChanged, "notSharp": notSharp, "indistinct": indistinct, "noReference": noReference,
            "blurredSteps": blurred.count, "blurredMs": summary(blurred), "otherFrames": otherFrames,
            "first": rows.first ?? [:], "rows": rows,
        ]
        if !appearedDiffs.isEmpty || !sharpDiffs.isEmpty {
            comparison[scenario] = [
                "appearedMinusHueMs": summary(appearedDiffs.map(abs)),
                "appearedOffByMoreThanAFrame": appearedDiffs.filter { abs($0) > 1000.0 / 60 }.count,
                "sharpMinusHueMs": summary(sharpDiffs.map(abs)),
                "sharpOffByMoreThanAFrame": sharpDiffs.filter { abs($0) > 1000.0 / 60 }.count,
                "appearedSignedMs": appearedDiffs, "sharpSignedMs": sharpDiffs,
            ]
        }
    }
    result["scenarios"] = scenarios
    if !comparison.isEmpty { result["hueComparison"] = comparison }
    // Settled pictures of the same photo, seen at the end of a step and on the reference walk: how far
    // apart they are is the noise the "match" threshold has to allow for.
    result["sameSettledPhotoDifference"] = summary(checks)
    if let hold = trace.hold {
        result["hold"] = analyzeHold(hold, steps: trace.steps, looks: stepLooks, cells: stepCells,
                                     thresholds: thresholds, settled: settledLook)
    }
    return result
}

// MARK: - Self test

/// A made-up recording with known answers: one step that shows a blurred preview first, and a held key
/// that passes five photos, only the first of which gets sharp while held.
func selfTest() -> Bool {
    var seed: UInt64 = 42
    func random() -> UInt8 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: seed >> 33)
    }
    let region = Region(middleOf: CGRect(x: 0, y: 0, width: 192, height: 192), horizontal: 0...1, vertical: 0...1,
                        cell: 24, rowStep: 2, within: CGSize(width: 400, height: 400))
    let cells = region.columns * region.rows
    let photos = (0..<6).map { _ in (0..<(cells * 3)).map { _ in random() } }
    func look(_ time: Double, _ photo: Int, sharp: Bool) -> Look {
        Look(time: time, region: 0, colors: photos[photo], detail: [Float](repeating: sharp ? 10 : 3, count: cells))
    }
    var trace = Trace()
    trace.regions = [region]
    trace.stepRegion = 0
    let timeline: [Look] = [
        look(0.50, 0, sharp: true), // steady before the hold
        look(1.05, 1, sharp: false), look(1.20, 1, sharp: true), // held: 1 gets sharp
        look(1.55, 2, sharp: false), look(1.64, 3, sharp: false), look(1.72, 4, sharp: false),
        look(1.90, 5, sharp: false),
        look(2.15, 5, sharp: true), // after release
        look(3.05, 4, sharp: true), look(3.65, 3, sharp: true), look(4.25, 2, sharp: true), // the walk back
        look(4.85, 1, sharp: true), look(5.45, 0, sharp: true),
        look(9.50, 0, sharp: true), look(10.04, 1, sharp: false), look(10.08, 1, sharp: true), // one step
        look(12.05, 1, sharp: true), look(12.65, 0, sharp: true), // its references
    ]
    trace.looks = timeline.map(Trace.store)
    trace.hold = HoldEvent(start: 1.0, end: 2.0, keyEvents: 7, repeatDelay: 0.5, repeatInterval: 1.0 / 12,
                           settledAt: 2.15, walkedBack: 5, anchorReached: true)
    trace.steps = [3.0, 3.6, 4.2, 4.8, 5.4].enumerated().map { StepEvent(scenario: "holdref", index: -$0 - 1, t0: $1, end: $1 + 0.6) }
        + [StepEvent(scenario: "1000ms", index: 1, t0: 10.0, end: 11.0),
           StepEvent(scenario: "reference", index: 1, t0: 12.0, end: 12.6),
           StepEvent(scenario: "reference", index: 0, t0: 12.6, end: 13.2)]
    let result = analyze(trace, Thresholds())
    let hold = result["hold"] as? [String: Any] ?? [:]
    let step = ((result["scenarios"] as? [String: Any])?["1000ms"] as? [String: Any])?["first"] as? [String: Any] ?? [:]
    let expected: [(String, Any?, Double)] = [
        ("hold: photos shown", hold["photosShown"], 5), ("hold: photos per second", hold["photosPerSecond"], 5),
        ("hold: per second while repeating", hold["photosPerSecondRepeating"], 8),
        ("hold: sharp photo share", hold["sharpPhotoShare"], 0.2), ("hold: sharp time share", hold["sharpTimeShare"], 0.35),
        ("hold: sharp after release, ms", hold["sharpAfterReleaseMs"], 150), ("hold: references", hold["references"], 6),
        ("hold: photos after release", hold["photosAfterRelease"], 0),
        ("step: appeared, ms", step["appearedMs"], 40), ("step: sharp, ms", step["sharpMs"], 80),
        ("step: blurred, ms", step["blurredMs"], 40),
    ]
    var passed = true
    for (name, value, want) in expected {
        let got = (value as? Double) ?? (value as? Int).map(Double.init)
        let ok = got.map { abs($0 - want) <= (want >= 2 ? 0.5 : 0.001) } ?? false
        print("\(ok ? "ok  " : "FAIL") \(name): \(got.map { String(format: "%.3f", $0) } ?? "nil"), expected \(want)")
        passed = passed && ok
    }
    return passed
}

// MARK: - Main

func write(_ result: [String: Any], to url: URL) {
    let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try? data?.write(to: url)
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = Options(CommandLine.arguments)
        Task { @MainActor in
            let result = await run(options)
            write(result, to: options.output)
            exit(result["error"] == nil ? 0 : 2)
        }
    }
}

let launchOptions = Options(CommandLine.arguments)
if launchOptions.selfTest { exit(selfTest() ? 0 : 1) }
if let traceURL = launchOptions.reanalyze {
    guard let data = try? Data(contentsOf: traceURL),
          var trace = try? PropertyListDecoder().decode(Trace.self, from: data) else {
        FileHandle.standardError.write("can't read \(traceURL.path)\n".data(using: .utf8)!)
        exit(1)
    }
    if !launchOptions.openMasks.isEmpty { trace.openMasks = launchOptions.openMasks }
    write(analyze(trace, launchOptions.thresholds), to: launchOptions.output)
    exit(0)
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

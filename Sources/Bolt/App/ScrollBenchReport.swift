import BoltCore
import Foundation

/// A frame that reached the canvas while the benchmark was watching.
struct ShownFrame {
    /// Uptime at which it was in the layer.
    let at: Double
    let kind: FrameKind
    let longSide: Int
    let isHDR: Bool
    let bytes: Int

    var isSharp: Bool { kind >= .screen }
}

/// One key press that moved to a new photo, and what happened to that photo while it was on screen.
struct ScrollStep {
    let url: URL
    /// When the key was due, i.e. pressed, as an uptime.
    let due: Double
    /// When the canvas began changing, and when the step's frame was in the layer.
    let showStart: Double
    let shownAt: Double
    /// nil: a blank (waiting for the first frame) or a message.
    let frame: ShownFrame?
    /// `lastDisplayDuration` of the step: the main-thread time of `displayCurrent` up to `updateChrome`.
    var mainMs = 0.0
    /// When the run loop was about to commit the transaction, and when it had. Both nil if another step
    /// shared the loop turn.
    var handlerEnd: Double?
    var commitEnd: Double?
    /// Frames that replaced this one while its photo was still on screen.
    var arrivals: [ShownFrame] = []

    /// The first screen-sized or full frame this photo had in the layer: the step's own, or a later one.
    var sharpFrame: ShownFrame? {
        if let frame, frame.isSharp { return frame }
        return arrivals.first { $0.isSharp }
    }

    var isSharpOnArrival: Bool { frame?.isSharp ?? false }

    /// Seconds from the key press until the sharp frame was in the layer.
    var pressToSharp: Double? { sharpFrame.map { $0.at - due } }

    /// The first frame better than the one the step showed.
    var upgrade: ShownFrame? {
        arrivals.first { arrival in
            guard let frame else { return true }
            return arrival.kind > frame.kind || arrival.longSide > frame.longSide
        }
    }
}

/// What a run was asked to do and when it did it: everything the report needs besides the steps.
struct ScrollRun {
    var mode: String
    var requestedSteps: Int
    var steps: Int
    var intervalMs: Int
    var delayMs: Int
    var keysDescription: String
    /// For a turn-around: how many steps went forward before the direction flipped.
    var turnAfter: Int?
    /// For a first press: the wait after the first frame, and by how much the press was late.
    var firstPressDelayMs: Int?
    var lateMs = 0.0
    var startIndex: Int
    var folder: String
    var windowVisible: Bool
    var appActive: Bool
    var decodesHDR: Bool
    var memoryMB: Int
    var cacheMB: Int
    /// Uptimes of the first key and of the release (or last key-up).
    var started: Double
    var releaseAt: Double
}

enum ScrollReport {
    static func build(_ steps: [ScrollStep], _ run: ScrollRun) -> [String: Any] {
        var summary = summarize(steps, run)
        summary["mode"] = run.mode
        summary["keys"] = run.keysDescription
        summary["intervalMs"] = run.intervalMs
        summary["delayMs"] = run.delayMs
        summary["requestedSteps"] = run.requestedSteps
        summary["startIndex"] = run.startIndex
        summary["folder"] = run.folder
        summary["windowVisible"] = run.windowVisible
        summary["appActive"] = run.appActive
        summary["decodesHDR"] = run.decodesHDR
        summary["memoryMB"] = run.memoryMB
        summary["cacheMB"] = run.cacheMB
        if let turnAfter = run.turnAfter { summary["turnAfter"] = turnAfter }
        if let delay = run.firstPressDelayMs {
            summary["firstPressDelayMs"] = delay
            summary["lateMs"] = number(run.lateMs)
        }
        return ["summary": summary, "samples": samples(steps, run)]
    }

    // MARK: - Samples

    private static func samples(_ steps: [ScrollStep], _ run: ScrollRun) -> [[String: Any]] {
        steps.enumerated().map { index, step in
            let sharp = step.sharpFrame
            return [
                "i": index,
                "tMs": number((step.shownAt - run.started) * 1000),
                "lagMs": number((step.shownAt - step.due) * 1000),
                "name": step.url.lastPathComponent,
                "shown": step.frame.map { "\($0.kind)" } ?? "none",
                "longSide": step.frame?.longSide ?? 0,
                "hdr": step.frame?.isHDR ?? false,
                "bytes": step.frame?.bytes ?? 0,
                "mainMs": number(step.mainMs),
                "upgradeMs": number(step.upgrade.map { ($0.at - step.shownAt) * 1000 }),
                "sharpMs": number(sharp.map { ($0.at - step.shownAt) * 1000 }),
                "pressToSharpMs": number(step.pressToSharp.map { $0 * 1000 }),
                "sharpHdr": sharp?.isHDR ?? false,
                "sharpBytes": sharp?.bytes ?? 0,
                "beforeMs": number((step.showStart - step.due) * 1000),
                "showMs": number((step.shownAt - step.showStart) * 1000),
                "afterMs": number(step.handlerEnd.map { ($0 - step.shownAt) * 1000 }),
                "commitMs": number(both(step.handlerEnd, step.commitEnd).map { ($1 - $0) * 1000 }),
            ]
        }
    }

    // MARK: - Summary

    private static func summarize(_ steps: [ScrollStep], _ run: ScrollRun) -> [String: Any] {
        let count = steps.count
        guard count > 0 else { return ["steps": 0, "ignored": true, "error": "no key press reached the viewer"] }
        // The last step has no next one to be measured against.
        let inner = steps.dropLast()
        let rest = steps.dropFirst()
        let shown = rest.filter { $0.frame != nil }.count
        let span = rest.count > 1 ? rest.last!.shownAt - rest.first!.shownAt : 0
        // Average spacing times the number of photos: equals the key rate when every step showed something.
        let perSecond = span > 0 ? Double(shown) / (span * Double(rest.count) / Double(rest.count - 1)) : 0

        let pressToSharp = steps.compactMap(\.pressToSharp).map { $0 * 1000 }
        let arrivedBlurry = inner.filter { !$0.isSharpOnArrival }
        let upgradeDelays = arrivedBlurry.compactMap { step in step.sharpFrame.map { ($0.at - step.shownAt) * 1000 } }
        let sharpBeforeNext = inner.filter { $0.sharpFrame != nil }.count

        var windows = 0.0, sharpTime = 0.0
        for (step, next) in zip(steps, steps.dropFirst()) {
            let window = next.shownAt - step.shownAt
            windows += window
            sharpTime += step.sharpFrame.map { max(window - ($0.at - step.shownAt), 0) } ?? 0
        }

        var releaseToSharp: Double?
        if let sharp = steps.last!.sharpFrame {
            releaseToSharp = max(sharp.at - run.releaseAt, 0) * 1000
        }
        let lags = steps.map { ($0.shownAt - $0.due) * 1000 }
        let main = steps.map(\.mainMs)

        // Where the time of a step goes when its sharp frame was already there. Only steps that had the loop
        // turn to themselves: with two steps in one turn the "after" part would be the other one's.
        let cached = steps.filter { $0.isSharpOnArrival }
        let before = cached.map { ($0.showStart - $0.due) * 1000 }
        let show = cached.map { ($0.shownAt - $0.showStart) * 1000 }
        let after = cached.compactMap { step in step.handlerEnd.map { ($0 - step.shownAt) * 1000 } }
        let commit = cached.compactMap { step in both(step.handlerEnd, step.commitEnd).map { ($1 - $0) * 1000 } }
        let cachedMain = cached.map(\.mainMs)

        let sharpFrames = steps.compactMap(\.sharpFrame)
        let shares = { (matching: Int, total: Int) in number(total > 0 ? Double(matching) / Double(total) * 100 : nil) }

        return [
            "steps": count,
            "pressToSharpMedianMs": number(median(pressToSharp)),
            "pressToSharpP95Ms": number(percentile(pressToSharp, 0.95)),
            "pressToSharpMaxMs": number(pressToSharp.max()),
            "neverSharpPct": shares(count - pressToSharp.count, count),
            "shownPerSecond": number(perSecond),
            "sharpOnArrivalPct": shares(steps.filter(\.isSharpOnArrival).count, count),
            "sharpBeforeNextPct": shares(sharpBeforeNext, inner.count),
            "blankPct": shares(steps.filter { $0.frame == nil }.count, count),
            "sharpTimePct": number(windows > 0 ? sharpTime / windows * 100 : nil),
            "upgradedInTime": upgradeDelays.count,
            "arrivedBlurry": arrivedBlurry.count,
            "timeToSharpMedianMs": number(median(upgradeDelays)),
            "timeToSharpP95Ms": number(percentile(upgradeDelays, 0.95)),
            "releaseToSharpMs": number(releaseToSharp),
            "releaseTimedOut": releaseToSharp == nil,
            "mainMedianMs": number(median(main)),
            "mainP95Ms": number(percentile(main, 0.95)),
            "mainMaxMs": number(main.max()),
            "lagMedianMs": number(median(lags)),
            "lagP95Ms": number(percentile(lags, 0.95)),
            "lagMaxMs": number(lags.max()),
            "cachedSteps": cached.count,
            "cachedBeforeMedianMs": number(median(before)),
            "cachedShowMedianMs": number(median(show)),
            "cachedAfterMedianMs": number(median(after)),
            "cachedCommitMedianMs": number(median(commit)),
            "cachedMainMedianMs": number(median(cachedMain)),
            "hdrPct": shares(sharpFrames.filter(\.isHDR).count, sharpFrames.count),
            "sharpMB": number(median(sharpFrames.map { Double($0.bytes) / 1_048_576 })),
        ]
    }

    /// Rounded to 0.1, or JSON null for "nothing to report".
    static func number(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return (value * 10).rounded() / 10
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Nearest rank.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(Int((fraction * Double(sorted.count)).rounded(.up)) - 1, 0))]
    }
}

private func both(_ first: Double?, _ second: Double?) -> (Double, Double)? {
    guard let first, let second else { return nil }
    return (first, second)
}

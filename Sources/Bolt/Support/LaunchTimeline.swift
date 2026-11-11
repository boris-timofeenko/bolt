import Foundation

/// Milliseconds from process start to each step of opening the first photo, for tuning cold start.
/// Off unless `BOLT_LAUNCH_TIMELINE` names a folder; then `launch-<pid>.json` is written there
/// once the first sharp frame is on screen.
@MainActor
enum LaunchTimeline {
    private static let folder = ProcessInfo.processInfo.environment["BOLT_LAUNCH_TIMELINE"]
    private static var marks: [[String: Any]] = []
    private static var finished = false
    private(set) static var firstFrameMilliseconds: Double?

    /// When the kernel started this process, so the timeline includes dyld and AppKit setup.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static var now: Double { Date().timeIntervalSince(processStart) * 1000 }

    static func mark(_ step: String) {
        guard folder != nil, !finished else { return }
        marks.append(["step": step, "ms": now])
    }

    /// Called for every frame put on screen; the first one and the first sharp one are what count.
    static func frameShown(sharp: Bool) {
        if firstFrameMilliseconds == nil {
            firstFrameMilliseconds = now
            mark(sharp ? "first frame (sharp)" : "first frame (preview)")
        }
        guard sharp, !finished else { return }
        if marks.last?["step"] as? String != "first frame (sharp)" { mark("first sharp frame") }
        finished = true
        guard let folder else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("launch-\(getpid()).json")
        try? JSONSerialization.data(withJSONObject: marks, options: .prettyPrinted).write(to: url)
    }
}

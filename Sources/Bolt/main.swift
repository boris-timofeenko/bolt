import AppKit

MainActor.assumeIsolated {
    LaunchTimeline.mark("main")
    LaunchWarmUp.start()
    let application = NSApplication.shared
    LaunchTimeline.mark("NSApplication created")
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

import AppKit

/// The language of the interface. By default Bolt follows the system; a choice in Settings goes into the app's
/// own AppleLanguages, which macOS reads at launch, so it takes effect after a restart.
@MainActor
enum InterfaceLanguage {
    /// Empty when Bolt follows the system.
    static var chosen: String {
        get { (ownDefaults?["AppleLanguages"] as? [String])?.first ?? "" }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// The choice the running app started with.
    static let atLaunch = chosen

    /// Languages the app has tables for, each named in itself: "Deutsch", "日本語".
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    /// Quits and opens Bolt again once this process is gone.
    static func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                              Bundle.main.bundlePath, "\(ProcessInfo.processInfo.processIdentifier)"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// UserDefaults.standard would also return the system-wide list.
    private static var ownDefaults: [String: Any]? {
        Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
    }
}

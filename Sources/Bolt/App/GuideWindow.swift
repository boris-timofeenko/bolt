import AppKit
import BoltCore
import SwiftUI

/// Help → How to Sort Photos: the culling workflows step by step, with the keys of the active key map.
@MainActor
enum GuideWindow {
    static func make(keyMap: KeyMap) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: GuideView(sections: Guide(keyMap: keyMap).sections)))
        window.title = Command.sortingGuide.title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 640))
        window.center()
        return window
    }
}

/// The text of the guide. Keys come from the key map, so a changed profile or shortcut shows up here too;
/// a command without a key is named by its menu title instead.
@MainActor
struct Guide {
    struct Section: Identifiable {
        let title: String
        let steps: [String]
        /// Steps of a procedure get numbers; separate facts get bullets.
        var numbered = true
        var id: String { title }
    }

    let keyMap: KeyMap

    var sections: [Section] {
        [
            Section(title: L("Pick the best and copy them to another folder"), steps: [
                L("Go through the photos and press %@ on the ones you want. They get a ✓ in the status bar.",
                  key(.flag(.pick))),
                L("Choose %@. Only the picked photos stay in the list.", Self.menuPath(.picks)),
                L("Press %@ to select them all, then %@ and choose a folder. %@ moves them instead.",
                  key(.selectAll), key(.copyToFolder), key(.moveToFolder)),
                L("Choose %@ to see every photo again.", Self.menuPath(.all)),
            ]),
            Section(title: L("Sort into folders as you go"), steps: [
                L("Press %@ on a photo. Bolt asks for a folder, moves the photo there and remembers the folder for this key.",
                  key(.moveToBucket(1))),
                L("After that %@ moves a photo to the folder and %@ copies it. %@ hold nine folders.",
                  key(.moveToBucket(1)), key(.copyToBucket(1)), range(.moveToBucket(1), .moveToBucket(9))),
                L("To give a key another folder, press %@.", key(.assignBucket(1))),
            ]),
            Section(title: L("Get rid of failed shots"), steps: [
                L("Press %@ on the photos you don't need, or %@ to send one to the Trash right away.",
                  key(.flag(.reject)), key(.trash)),
                L("Then choose %@, press %@ and %@. All rejected photos go to the Trash.",
                  Self.menuPath(.rejects), key(.selectAll), key(.trash)),
            ]),
            Section(title: L("Choose the best shot of a series"), steps: [
                L("Select the series with %@, then press %@. Up to four photos appear side by side.",
                  key(.extendNext), key(.compare)),
                L("← and → switch between them. Mark the best one with %@ and press Esc.", key(.flag(.pick))),
            ]),
            Section(title: L("Rate with stars"), steps: [
                L("%@ give one to five stars, %@ removes them.", range(.rate(1), .rate(5)), key(.rate(0))),
                L("Choose %@ to see only the best ones, then copy them as above.", Self.menuPath(.rated(atLeast: 3))),
            ]),
            Section(title: L("Where flags and stars are kept"), steps: [
                L("Flags, stars and color labels are Finder tags on the file itself. Finder shows them, Spotlight finds them, and a copy of the photo keeps them."),
                L("%@ undoes a move, a deletion or a flag. Press it again to go further back.", key(.undo)),
            ], numbered: false),
        ]
    }

    /// " → " with no-break spaces: a menu path wraps as a whole, never just before an arrow.
    static let arrow = "\u{00A0}→\u{00A0}"

    /// "Help → How to Sort Photos".
    static var guideMenuPath: String {
        [L("Help"), Command.sortingGuide.title].joined(separator: arrow)
    }

    /// "View → Show → Picks".
    static func menuPath(_ filter: LabelFilter) -> String {
        [L("View"), L("Show"), filter.title].joined(separator: Self.arrow)
    }

    func key(_ command: Command) -> String {
        keyMap.chord(for: command)?.symbol ?? command.paletteTitle
    }

    /// "⌃1–5": one name for a run of keys.
    func range(_ first: Command, _ last: Command) -> String {
        guard let start = keyMap.chord(for: first), let end = keyMap.chord(for: last) else { return key(first) }
        return "\(start.symbol)–\(Keys.label(for: end.keyCode))"
    }
}

private struct GuideView: View {
    let sections: [Guide.Section]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.headline)
                        ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(section.numbered ? "\(index + 1)." : "•")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, alignment: .trailing)
                                Text(step).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

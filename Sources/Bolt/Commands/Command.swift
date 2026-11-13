import AppKit
import BoltCore

/// Everything the user can do, whether from a key, a menu or the command palette.
enum Command: Hashable {
    case next, previous, first, last, forward10, back10
    case extendNext, extendPrevious, selectAll
    case nextFolder, previousFolder, parentFolder

    case toggleGrid, toggleStrip, toggleInfo, toggleFullscreen, exitFullscreen, toggleInterface

    case zoomToggle, zoomIn, zoomOut, fitWindow, fitWidth, actualSize

    case trash
    case moveToBucket(Int), copyToBucket(Int), assignBucket(Int)
    case moveToFolder, copyToFolder
    case flag(PhotoLabels.Flag), rate(Int), colorLabel(Int), filter(LabelFilter)
    case compare, repeatLast, undo, redo
    case playPause, livePhoto, slideshow

    case rename, copyImage, copyPath, revealInFinder, share, openInEditor, open

    case rotateLeft, rotateRight, flipHorizontal
    case crop, export, exportWithPreset, convert, batchRename, dateFolders, removePrivateData

    case sort(SortKey), reverseSort
    case background(CanvasBackground)

    case commandPalette, cheatSheet, sortingGuide, performanceOverlay, settings

    enum Group: CaseIterable {
        case navigation, view, zoom, culling, file, edit, system

        var title: String {
            switch self {
            case .navigation: L("Navigation")
            case .view: L("View")
            case .zoom: L("Zoom")
            case .culling: L("Culling")
            case .file: L("File")
            case .edit: L("Edit")
            case .system: L("System")
            }
        }
    }

    /// Every command, in the order the palette lists them.
    static var all: [Command] {
        var commands: [Command] = [
            .next, .previous, .first, .last, .forward10, .back10, .extendNext, .extendPrevious, .selectAll,
            .nextFolder, .previousFolder, .parentFolder,
            .toggleGrid, .toggleStrip, .toggleInfo, .toggleFullscreen, .exitFullscreen, .toggleInterface, .slideshow,
            .playPause, .livePhoto,
            .zoomToggle, .zoomIn, .zoomOut, .fitWindow, .fitWidth, .actualSize,
            .trash, .moveToFolder, .copyToFolder, .compare, .repeatLast, .undo, .redo,
            .flag(.pick), .flag(.reject), .flag(.none),
        ]
        commands += (0...5).map(Command.rate) + LabelColor.all.map { Command.colorLabel($0.number) }
        commands += LabelFilter.menuItems.map(Command.filter)
        commands += (1...9).flatMap { [Command.moveToBucket($0), .copyToBucket($0), .assignBucket($0)] }
        commands += [.rename, .copyImage, .copyPath, .revealInFinder, .share, .openInEditor, .open,
                     .rotateLeft, .rotateRight, .flipHorizontal, .crop,
                     .export, .exportWithPreset, .convert, .batchRename, .dateFolders, .removePrivateData]
        commands += SortKey.allCases.map(Command.sort) + [.reverseSort]
        commands += CanvasBackground.allCases.map(Command.background)
        commands += [.commandPalette, .cheatSheet, .sortingGuide, .performanceOverlay, .settings]
        return commands
    }

    /// Stable name for saving custom shortcuts.
    var id: String {
        switch self {
        case .moveToBucket(let number): "bucket.move.\(number)"
        case .copyToBucket(let number): "bucket.copy.\(number)"
        case .assignBucket(let number): "bucket.assign.\(number)"
        case .flag(let flag): "flag.\(flag)"
        case .rate(let stars): "rate.\(stars)"
        case .colorLabel(let number): "color.\(number)"
        case .filter(let filter): "filter.\(filter)"
        case .sort(let key): "sort.\(key.rawValue)"
        case .background(let background): "background.\(background.rawValue)"
        default: String(describing: self)
        }
    }

    init?(id: String) {
        guard let command = Command.all.first(where: { $0.id == id }) else { return nil }
        self = command
    }

    var group: Group {
        switch self {
        case .next, .previous, .first, .last, .forward10, .back10, .nextFolder, .previousFolder, .parentFolder:
            .navigation
        case .toggleGrid, .toggleStrip, .toggleInfo, .playPause, .livePhoto, .slideshow, .toggleFullscreen,
             .exitFullscreen, .toggleInterface, .sort, .reverseSort, .background:
            .view
        case .zoomToggle, .zoomIn, .zoomOut, .fitWindow, .fitWidth, .actualSize:
            .zoom
        case .trash, .moveToBucket, .copyToBucket, .assignBucket, .moveToFolder, .copyToFolder, .repeatLast,
             .undo, .redo, .extendNext, .extendPrevious, .selectAll, .flag, .rate, .colorLabel, .filter, .compare:
            .culling
        case .rename, .copyImage, .copyPath, .revealInFinder, .share, .openInEditor, .open:
            .file
        case .rotateLeft, .rotateRight, .flipHorizontal, .crop, .export, .exportWithPreset, .convert, .batchRename,
             .dateFolders, .removePrivateData:
            .edit
        case .commandPalette, .cheatSheet, .sortingGuide, .performanceOverlay, .settings:
            .system
        }
    }

    var title: String {
        switch self {
        case .next: L("Next Photo")
        case .previous: L("Previous Photo")
        case .first: L("First Photo")
        case .last: L("Last Photo")
        case .forward10: L("Forward 10")
        case .back10: L("Back 10")
        case .extendNext: L("Add Next to Selection")
        case .extendPrevious: L("Add Previous to Selection")
        case .selectAll: L("Select All")
        case .nextFolder: L("Next Folder")
        case .previousFolder: L("Previous Folder")
        case .parentFolder: L("Enclosing Folder")
        case .toggleGrid: L("Thumbnail Grid")
        case .toggleStrip: L("Thumbnail Strip")
        case .toggleInfo: L("Info")
        case .playPause: L("Play or Pause Video")
        case .livePhoto: L("Play Live Photo (Hold)")
        case .slideshow: L("Slideshow")
        case .toggleFullscreen: L("Full Screen")
        case .exitFullscreen: L("Exit Full Screen")
        case .toggleInterface: L("Hide Interface")
        case .zoomToggle: L("Fit / 100%")
        case .zoomIn: L("Zoom In")
        case .zoomOut: L("Zoom Out")
        case .fitWindow: L("Fit to Window")
        case .fitWidth: L("Fit Width")
        case .actualSize: L("Actual Size")
        case .trash: L("Move to Trash")
        case .moveToBucket(let number):
            Preferences.bucket(number).map { L("Move to “%@”", $0.lastPathComponent) } ?? L("Move to Folder %d", number)
        case .copyToBucket(let number):
            Preferences.bucket(number).map { L("Copy to “%@”", $0.lastPathComponent) } ?? L("Copy to Folder %d", number)
        case .assignBucket(let number): L("Set Folder for Key %d…", number)
        case .moveToFolder: L("Move to Folder…")
        case .copyToFolder: L("Copy to Folder…")
        case .flag(.pick): L("Pick")
        case .flag(.reject): L("Reject")
        case .flag(.none): L("Clear Flag")
        case .rate(0): L("No Rating")
        case .rate(let stars): String(repeating: "★", count: stars)
        case .colorLabel(let number): LabelColor(number: number).title
        case .filter(let filter): filter.title
        case .compare: L("Compare")
        case .repeatLast: L("Repeat Last Action")
        case .undo: L("Undo")
        case .redo: L("Redo")
        case .rename: L("Rename")
        case .copyImage: L("Copy Image")
        case .copyPath: L("Copy Path")
        case .revealInFinder: L("Show in Finder")
        case .share: L("Share…")
        case .openInEditor:
            L("Open in %@", Preferences.externalEditor.map(FileManager.default.applicationName) ?? "Preview")
        case .open: L("Open…")
        case .rotateLeft: L("Rotate Left")
        case .rotateRight: L("Rotate Right")
        case .flipHorizontal: L("Flip Horizontal")
        case .crop: L("Crop…")
        case .export: L("Export as “%@”", Preferences.lastExportPreset.name)
        case .exportWithPreset: L("Export With…")
        case .convert: L("Convert…")
        case .batchRename: L("Rename Photos…")
        case .dateFolders: L("Sort into Date Folders")
        case .removePrivateData: L("Remove Location and Serial Numbers")
        case .sort(let key): key.title
        case .reverseSort: L("Reverse Order")
        case .background(let background): background.title
        case .commandPalette: L("All Commands")
        case .cheatSheet: L("Keyboard Shortcuts")
        case .sortingGuide: L("How to Sort Photos")
        case .performanceOverlay: L("Speed Overlay")
        case .settings: L("Settings…")
        }
    }

    /// Developer tools: they keep a key (⌘⌥P shows decode and display times) but stay out of
    /// the menus, the palette and the shortcut settings.
    var isHidden: Bool { self == .performanceOverlay }

    /// Title for places without a menu around it, like the command palette.
    var paletteTitle: String {
        switch self {
        case .sort(let key): L("Sort by %@", key.title.lowercasedFirstLetter)
        case .rate(let stars) where stars > 0: L("Rating %@", title)
        case .colorLabel(let number) where number > 0: L("Label: %@", title.lowercasedFirstLetter)
        case .filter: L("Show: %@", title.lowercasedFirstLetter)
        case .background(let background): L("Background: %@", background.title.lowercasedFirstLetter)
        default: title
        }
    }

    /// Commands that "." can repeat on the next photo.
    var isRepeatable: Bool {
        switch self {
        case .trash, .moveToBucket, .copyToBucket, .rotateLeft, .rotateRight, .flipHorizontal, .flag, .rate,
             .colorLabel: true
        default: false
        }
    }
}

extension SortKey {
    var title: String {
        switch self {
        case .name: L("Name")
        case .dateTaken: L("Date Taken")
        case .dateModified: L("Date Modified")
        case .size: L("Size")
        case .random: L("Random")
        }
    }
}

extension String {
    var lowercasedFirstLetter: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// Wraps a command for `NSMenuItem.representedObject`.
final class CommandBox: NSObject {
    let command: Command

    init(_ command: Command) {
        self.command = command
    }
}

/// Finder's color labels, in the order Lightroom puts them on keys 6–9.
struct LabelColor {
    let number: Int

    static let all = [6, 5, 2, 4, 3, 0].map(LabelColor.init)

    var title: String {
        switch number {
        case 1: L("Gray")
        case 2: L("Green")
        case 3: L("Purple")
        case 4: L("Blue")
        case 5: L("Yellow")
        case 6: L("Red")
        case 7: L("Orange")
        default: L("No Label")
        }
    }

    var color: NSColor? {
        switch number {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }
}

extension LabelFilter {
    static let menuItems: [LabelFilter] = [.all, .picks, .rejects, .unflagged,
                                           .rated(atLeast: 1), .rated(atLeast: 3), .rated(atLeast: 5)]

    var title: String {
        switch self {
        case .all: L("All Photos")
        case .picks: L("Picks")
        case .rejects: L("Rejected")
        case .unflagged: L("Unflagged")
        case .rated(let stars): L("%@ and Up", String(repeating: "★", count: stars))
        }
    }
}

extension PhotoLabels {
    /// "✓ ★★★ ●" for the status bar and grid; the dot takes the label's color.
    func badge(font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        switch flag {
        case .pick: text.append(NSAttributedString(string: "✓ ", attributes: attributes))
        case .reject: text.append(NSAttributedString(string: "✕ ", attributes: attributes))
        case .none: break
        }
        if rating > 0 {
            text.append(NSAttributedString(string: String(repeating: "★", count: rating) + " ", attributes: attributes))
        }
        if let color = LabelColor(number: color).color {
            var dot = attributes
            dot[.foregroundColor] = color
            text.append(NSAttributedString(string: "● ", attributes: dot))
        }
        return text
    }
}

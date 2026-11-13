import AppKit
import BoltCore

/// The menu bar, built in code. Command items show the shortcut from the active key map;
/// the keys themselves are handled by the key monitor, the menu only lists them.
@MainActor
enum MainMenu {
    static func build(keyMap: KeyMap) -> NSMenu {
        let main = NSMenu()
        let name = ProcessInfo.processInfo.processName

        main.addItem(submenu(name, [
            NSMenuItem(title: L("About %@", name), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                       keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: L("Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ","),
            .separator(),
            servicesItem(),
            .separator(),
            NSMenuItem(title: L("Hide %@", name), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            NSMenuItem(title: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)),
                       keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: L("Quit %@", name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))

        let commands = CommandItems(keyMap: keyMap)
        main.addItem(submenu(L("File"), [
            NSMenuItem(title: L("New Window"), action: #selector(AppDelegate.newViewerWindow(_:)), keyEquivalent: "n"),
            NSMenuItem(title: L("Open…"), action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o"),
            recentItem(),
            .separator(),
            NSMenuItem(title: L("Close"), action: #selector(AppDelegate.closeViewer(_:)), keyEquivalent: "w"),
            .separator(),
            commands[.rename], commands[.revealInFinder], commands[.copyPath], commands[.share],
            commands[.openInEditor],
            .separator(),
            commands[.export], commands[.exportWithPreset], commands[.convert], commands[.batchRename],
            commands[.dateFolders], commands[.removePrivateData],
            .separator(),
            commands[.moveToFolder], commands[.copyToFolder], commands[.trash],
        ]))

        main.addItem(submenu(L("Edit"), [
            item(L("Undo"), #selector(AppDelegate.undoAction(_:)), "z", .command),
            item(L("Redo"), #selector(AppDelegate.redoAction(_:)), "z", [.command, .shift]),
            .separator(),
            NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            commands[.selectAll],
            .separator(),
            commands[.repeatLast],
        ]))

        main.addItem(submenu(L("View"), [
            commands[.toggleGrid], commands[.toggleStrip], commands[.toggleInfo], commands[.compare],
            commands[.playPause],
            .separator(),
            commands[.toggleFullscreen], commands[.toggleInterface], commands[.slideshow],
            .separator(),
            commands[.zoomIn], commands[.zoomOut], commands[.fitWindow], commands[.actualSize],
            .separator(),
            submenu(L("Sort By"), SortKey.allCases.map { commands[.sort($0)] } + [.separator(), commands[.reverseSort]]),
            submenu(L("Background"), CanvasBackground.allCases.map { commands[.background($0)] }),
            submenu(L("Show"), LabelFilter.menuItems.map { commands[.filter($0)] }),
        ]))

        main.addItem(submenu(L("Go"), [
            commands[.next], commands[.previous], commands[.first], commands[.last],
            .separator(),
            commands[.nextFolder], commands[.previousFolder], commands[.parentFolder],
        ]))

        main.addItem(submenu(L("Photo"), [
            commands[.flag(.pick)], commands[.flag(.reject)], commands[.flag(.none)],
            submenu(L("Rating"), (0...5).map { commands[.rate($0)] }),
            submenu(L("Color Label"), LabelColor.all.map { commands[.colorLabel($0.number)] }),
            .separator(),
            commands[.rotateLeft], commands[.rotateRight], commands[.flipHorizontal], commands[.crop],
            .separator(),
            submenu(L("Folders on Keys"), (1...9).flatMap(commands.bucketItems)),
            .separator(),
            commands[.copyImage],
        ]))

        let window = submenu(L("Window"), [
            NSMenuItem(title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)),
                       keyEquivalent: ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu(L("Help"), [commands[.sortingGuide], commands[.cheatSheet], commands[.commandPalette]])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = submenu(L("Services"), [])
        NSApp.servicesMenu = item.submenu
        return item
    }

    /// AppKit fills a submenu that contains "Clear Menu" with recent documents.
    private static func recentItem() -> NSMenuItem {
        submenu(L("Open Recent"), [
            NSMenuItem(title: L("Clear Menu"), action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                       keyEquivalent: ""),
        ])
    }
}

/// Menu items for commands, with the key map's shortcut attached for display.
@MainActor
private struct CommandItems {
    let keyMap: KeyMap

    subscript(command: Command) -> NSMenuItem {
        // Cmd+Z and Cmd+C belong to the Edit menu's own items; showing them twice would confuse.
        let showsShortcut = command != .undo && command != .redo && command != .copyImage
        return NSMenuItem(command: command, keyMap: showsShortcut ? keyMap : nil,
                          action: #selector(AppDelegate.performCommand(_:)))
    }

    /// One line per key: "Move to “Trip”  1". Holding ⌥ turns it into copying, ⇧⌘ into choosing the folder,
    /// the way Finder's menus swap items. A variant whose key doesn't differ only in modifiers can't be an
    /// alternate, so it then stays a line of its own.
    func bucketItems(_ number: Int) -> [NSMenuItem] {
        let move = self[.moveToBucket(number)]
        return [move] + [Command.copyToBucket(number), .assignBucket(number)].map { command in
            let item = self[command]
            item.isAlternate = !move.keyEquivalent.isEmpty && item.keyEquivalent == move.keyEquivalent
                && item.keyEquivalentModifierMask != move.keyEquivalentModifierMask
            return item
        }
    }
}

extension NSMenuItem {
    /// A menu item for a command: its title, the command in `representedObject`, and the key map's shortcut.
    convenience init(command: Command, keyMap: KeyMap?, action: Selector, target: AnyObject? = nil) {
        self.init(title: command.title, action: action, keyEquivalent: "")
        self.target = target
        representedObject = CommandBox(command)
        if let equivalent = keyMap?.chord(for: command)?.menuEquivalent {
            keyEquivalent = equivalent.key
            keyEquivalentModifierMask = equivalent.modifiers
        }
    }
}

import AppKit
import BoltCore
import Carbon.HIToolbox

/// A key plus modifiers, identified by the physical key code rather than the character it types,
/// so G stays G on a Russian layout.
struct KeyChord: Hashable {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)

        private static let pairs: [(Modifiers, NSEvent.ModifierFlags)] = [
            (.command, .command), (.shift, .shift), (.option, .option), (.control, .control),
        ]

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(flags: NSEvent.ModifierFlags) {
            self = Self.pairs.reduce(into: []) { result, pair in if flags.contains(pair.1) { result.insert(pair.0) } }
        }

        var eventFlags: NSEvent.ModifierFlags {
            Self.pairs.reduce(into: []) { result, pair in if contains(pair.0) { result.insert(pair.1) } }
        }
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(_ keyCode: Int, _ modifiers: Modifiers = []) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = Modifiers(flags: event.modifierFlags)
    }

    /// "6:7" — modifiers and key code, as saved in preferences.
    var storage: String { "\(modifiers.rawValue):\(keyCode)" }

    init?(storage: String) {
        let parts = storage.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(parts[1], Modifiers(rawValue: parts[0]))
    }

    /// "⌃⌥⇧⌘K", in the order macOS menus use.
    var symbol: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Keys.label(for: keyCode)
    }

    /// Key equivalent for an NSMenuItem, so menus show the same shortcut the key map uses.
    var menuEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let key = Keys.menuCharacter(for: keyCode) else { return nil }
        return (key, modifiers.eventFlags)
    }
}

enum KeyProfile: String, CaseIterable {
    case bolt, irfanView, lightroom

    var title: String {
        switch self {
        case .bolt: "Bolt"
        case .irfanView: "IrfanView"
        case .lightroom: "Lightroom"
        }
    }
}

struct KeyMap {
    private(set) var bindings: [KeyChord: Command] = [:]

    func command(for chord: KeyChord) -> Command? {
        bindings[chord]
    }

    /// The shortcut menus and the cheat sheet show: the one with the fewest modifiers.
    func chord(for command: Command) -> KeyChord? {
        bindings.filter { $0.value == command }.keys.min { rank($0) < rank($1) }
    }

    private func rank(_ chord: KeyChord) -> Int {
        // Fewer modifiers first, then the order of `Keys.preference`.
        chord.modifiers.rawValue.nonzeroBitCount * 1000 + (Keys.preference.firstIndex(of: chord.keyCode) ?? 999)
    }

    mutating func bind(_ chord: KeyChord, _ command: Command) {
        bindings[chord] = command
    }

    mutating func unbind(_ command: Command) {
        bindings = bindings.filter { $0.value != command }
    }

    /// A profile with the user's own changes on top.
    static func current() -> KeyMap {
        var map = profile(Preferences.keyProfile)
        for (id, chords) in Preferences.keyOverrides {
            guard let command = Command(id: id) else { continue }
            map.unbind(command)
            for chord in chords.compactMap(KeyChord.init(storage:)) { map.bind(chord, command) }
        }
        return map
    }

    static func profile(_ profile: KeyProfile) -> KeyMap {
        var map = bolt
        switch profile {
        case .bolt:
            break
        case .irfanView:
            map.unbind(.rotateLeft)
            map.unbind(.rotateRight)
            map.unbind(.toggleFullscreen)
            map.unbind(.moveToFolder)
            map.unbind(.copyToFolder)
            map.bind(KeyChord(kVK_ANSI_L), .rotateLeft)
            map.bind(KeyChord(kVK_ANSI_R), .rotateRight)
            map.bind(KeyChord(kVK_Return), .toggleFullscreen)
            map.bind(KeyChord(kVK_ANSI_F), .toggleFullscreen)
            map.bind(KeyChord(kVK_F7), .moveToFolder)
            map.bind(KeyChord(kVK_F8), .copyToFolder)
            map.bind(KeyChord(kVK_ANSI_M), .moveToFolder)
        case .lightroom:
            // Digits are ratings in Lightroom, so buckets move to Option and Option-Shift.
            for number in 1...9 {
                map.unbind(.moveToBucket(number))
                map.unbind(.copyToBucket(number))
                map.bind(KeyChord(Keys.digits[number], .option), .moveToBucket(number))
                map.bind(KeyChord(Keys.digits[number], [.option, .shift]), .copyToBucket(number))
            }
            for stars in 0...5 { map.bind(KeyChord(Keys.digits[stars]), .rate(stars)) }
            for (key, color) in zip(6...9, LabelColor.all) { map.bind(KeyChord(Keys.digits[key]), .colorLabel(color.number)) }
            map.unbind(.rotateLeft)
            map.unbind(.rotateRight)
            map.bind(KeyChord(kVK_ANSI_LeftBracket, .command), .rotateLeft)
            map.bind(KeyChord(kVK_ANSI_RightBracket, .command), .rotateRight)
        }
        return map
    }

    /// The default layout from the spec.
    private static let bolt: KeyMap = {
        var map = KeyMap()
        let table: [(Int, KeyChord.Modifiers, Command)] = [
            (kVK_RightArrow, [], .next), (kVK_Space, [], .next),
            (kVK_LeftArrow, [], .previous), (kVK_Space, .shift, .previous),
            (kVK_Home, [], .first), (kVK_End, [], .last),
            (kVK_PageDown, [], .forward10), (kVK_PageUp, [], .back10),
            (kVK_RightArrow, .shift, .extendNext), (kVK_LeftArrow, .shift, .extendPrevious),
            (kVK_ANSI_A, .command, .selectAll),
            (kVK_RightArrow, .command, .nextFolder), (kVK_LeftArrow, .command, .previousFolder),
            (kVK_UpArrow, .command, .parentFolder),
            (kVK_Space, .option, .playPause), (kVK_ANSI_V, [], .livePhoto),
            (kVK_ANSI_S, [.command, .option], .slideshow),
            (kVK_ANSI_G, [], .toggleGrid), (kVK_ANSI_T, [], .toggleStrip), (kVK_ANSI_I, [], .toggleInfo),

            (kVK_ANSI_F, [], .toggleFullscreen), (kVK_ANSI_F, [.command, .control], .toggleFullscreen),
            (kVK_Escape, [], .exitFullscreen),
            (kVK_Tab, [], .toggleInterface),

            (kVK_ANSI_Z, [], .zoomToggle),
            (kVK_ANSI_Equal, [], .zoomIn), (kVK_ANSI_KeypadPlus, [], .zoomIn), (kVK_ANSI_Equal, .command, .zoomIn),
            (kVK_ANSI_Minus, [], .zoomOut), (kVK_ANSI_KeypadMinus, [], .zoomOut), (kVK_ANSI_Minus, .command, .zoomOut),
            (kVK_ANSI_W, [], .fitWidth),
            (kVK_ANSI_0, .command, .fitWindow),
            (kVK_ANSI_1, [.command, .option], .actualSize),

            (kVK_Delete, [], .trash), (kVK_ForwardDelete, [], .trash), (kVK_Delete, .command, .trash),
            (kVK_ANSI_M, [], .moveToFolder), (kVK_ANSI_M, .shift, .copyToFolder),
            (kVK_ANSI_Period, [], .repeatLast), (kVK_ANSI_K, [], .compare),
            (kVK_ANSI_P, [], .flag(.pick)), (kVK_ANSI_X, [], .flag(.reject)), (kVK_ANSI_U, [], .flag(.none)),
            (kVK_ANSI_Z, .command, .undo), (kVK_ANSI_Z, [.command, .shift], .redo),

            (kVK_Return, [], .rename), (kVK_ANSI_KeypadEnter, [], .rename), (kVK_F2, [], .rename),
            (kVK_ANSI_C, .command, .copyImage), (kVK_ANSI_C, [.command, .shift], .copyPath),
            (kVK_ANSI_R, .command, .revealInFinder),
            (kVK_ANSI_S, [], .share),
            (kVK_ANSI_O, [], .openInEditor),
            (kVK_ANSI_O, .command, .open),

            (kVK_ANSI_LeftBracket, [], .rotateLeft), (kVK_ANSI_RightBracket, [], .rotateRight),
            (kVK_ANSI_H, [], .flipHorizontal), (kVK_ANSI_C, [], .crop),
            (kVK_ANSI_E, [], .export), (kVK_ANSI_E, .shift, .exportWithPreset),

            (kVK_ANSI_Slash, [], .commandPalette), (kVK_ANSI_K, .command, .commandPalette),
            (kVK_ANSI_Slash, .shift, .cheatSheet),
            (kVK_ANSI_P, [.command, .option], .performanceOverlay),
        ]
        for (key, modifiers, command) in table {
            map.bind(KeyChord(key, modifiers), command)
        }
        for stars in 0...5 {
            map.bind(KeyChord(Keys.digits[stars], .control), .rate(stars))
        }
        for (key, color) in zip(6...9, LabelColor.all) {
            map.bind(KeyChord(Keys.digits[key], .control), .colorLabel(color.number))
        }
        for number in 1...9 {
            map.bind(KeyChord(Keys.digits[number]), .moveToBucket(number))
            map.bind(KeyChord(Keys.keypadDigits[number]), .moveToBucket(number))
            map.bind(KeyChord(Keys.digits[number], .option), .copyToBucket(number))
            map.bind(KeyChord(Keys.digits[number], [.command, .shift]), .assignBucket(number))
        }
        return map
    }()
}

extension NSEvent {
    /// No Command, Option, Control or Shift held.
    var hasNoModifiers: Bool {
        KeyChord.Modifiers(flags: modifierFlags).isEmpty
    }
}

/// Labels and menu characters for physical keys, as printed on a US keyboard.
enum Keys {
    static let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                         kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static let keypadDigits = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
                               kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
                               kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]

    /// When a command has several keys, the earlier one in this list is the one shown.
    static let preference: [UInt16] = [kVK_RightArrow, kVK_LeftArrow, kVK_Delete, kVK_Return, kVK_ANSI_Equal,
                                       kVK_ANSI_Minus, kVK_ANSI_F, kVK_ANSI_Slash, kVK_ANSI_M].map { UInt16($0) }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    private static let specialLabels: [Int: String] = [
        kVK_RightArrow: "→", kVK_LeftArrow: "←", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Escape: "Esc",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
        kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadMinus: "−",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func label(for keyCode: UInt16) -> String {
        let code = Int(keyCode)
        if let label = letters[code] ?? specialLabels[code] { return label }
        if let digit = keypadDigits.firstIndex(of: code) { return "\(digit)" }
        return "#\(code)"
    }

    static func menuCharacter(for keyCode: UInt16) -> String? {
        let code = Int(keyCode)
        if let letter = letters[code] { return letter.lowercased() }
        let functionKey: Int? = switch code {
        case kVK_RightArrow: NSRightArrowFunctionKey
        case kVK_LeftArrow: NSLeftArrowFunctionKey
        case kVK_UpArrow: NSUpArrowFunctionKey
        case kVK_DownArrow: NSDownArrowFunctionKey
        case kVK_Home: NSHomeFunctionKey
        case kVK_End: NSEndFunctionKey
        case kVK_PageUp: NSPageUpFunctionKey
        case kVK_PageDown: NSPageDownFunctionKey
        case kVK_ForwardDelete: NSDeleteFunctionKey
        case kVK_F2: NSF2FunctionKey
        case kVK_F7: NSF7FunctionKey
        case kVK_F8: NSF8FunctionKey
        default: nil
        }
        if let functionKey, let scalar = UnicodeScalar(functionKey) { return String(Character(scalar)) }
        return switch code {
        case kVK_Space: " "
        case kVK_Return: "\r"
        case kVK_Tab: "\t"
        case kVK_Escape: "\u{1b}"
        case kVK_Delete: "\u{8}"
        default: nil
        }
    }
}

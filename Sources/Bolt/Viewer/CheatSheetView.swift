import AppKit

/// "?" — every shortcut of the current key map, grouped, over the photo. Any key or click closes it.
final class CheatSheetView: NSView {
    private struct Row {
        let keys: String
        let title: String
    }

    var onClose: (() -> Void)?
    private let panel = NSView()
    private let columns = NSStackView()
    private let content = NSStackView()

    init(keyMap: KeyMap) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
        content.addArrangedSubview(columns)
        // Keys alone don't say how they add up; the guide does.
        let guide = NSTextField(labelWithString: L("How the culling keys work together: %@.", Guide.guideMenuPath))
        guide.font = .systemFont(ofSize: 11)
        guide.textColor = .secondaryLabelColor
        content.addArrangedSubview(guide)
        panel.addSubview(content)

        let groups = Self.rows(for: keyMap)
        // Three columns of roughly equal height.
        var column = Self.columnStack()
        var columnHeight = 0
        let target = groups.reduce(0) { $0 + $1.rows.count + 2 } / 3 + 1
        for group in groups {
            if columnHeight > 0, columnHeight + group.rows.count / 2 > target {
                columns.addArrangedSubview(column)
                column = Self.columnStack()
                columnHeight = 0
            }
            column.addArrangedSubview(Self.heading(group.title))
            for row in group.rows { column.addArrangedSubview(Self.rowView(row)) }
            column.setCustomSpacing(14, after: column.arrangedSubviews.last!)
            columnHeight += group.rows.count + 2
        }
        columns.addArrangedSubview(column)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
    }

    override func layout() {
        super.layout()
        let size = content.fittingSize
        panel.frame = NSRect(x: max((bounds.width - size.width) / 2, 0), y: max((bounds.height - size.height) / 2, 0),
                             width: size.width, height: size.height)
        content.frame = panel.bounds
    }

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }

    // MARK: - Content

    private static func rows(for keyMap: KeyMap) -> [(title: String, rows: [Row])] {
        func row(_ command: Command, _ title: String? = nil) -> Row? {
            keyMap.chord(for: command).map { Row(keys: $0.symbol, title: title ?? command.title) }
        }
        /// "1–9", "⌥1–9": one line for the nine bucket keys.
        func range(_ first: Command, _ last: Command, _ title: String) -> Row? {
            guard let start = keyMap.chord(for: first), let end = keyMap.chord(for: last) else { return nil }
            return Row(keys: "\(start.symbol)–\(Keys.label(for: end.keyCode))", title: title)
        }

        let navigation = [row(.next), row(.previous), row(.first), row(.last), row(.forward10), row(.back10),
                          row(.nextFolder), row(.previousFolder), row(.parentFolder)]
        let view = [row(.toggleGrid), row(.toggleStrip), row(.toggleInfo), row(.livePhoto), row(.playPause),
                    row(.toggleFullscreen), row(.exitFullscreen),
                    row(.toggleInterface)]
        let zoom = [row(.zoomToggle), row(.zoomIn), row(.zoomOut), row(.fitWidth)]
        let culling = [row(.trash),
                       range(.moveToBucket(1), .moveToBucket(9), L("Move to folder 1–9")),
                       range(.copyToBucket(1), .copyToBucket(9), L("Copy to folder 1–9")),
                       range(.assignBucket(1), .assignBucket(9), L("Choose folder for a key")),
                       row(.moveToFolder), row(.copyToFolder),
                       row(.flag(.pick)), row(.flag(.reject)), row(.flag(.none)),
                       range(.rate(0), .rate(5), L("Rating")),
                       range(.colorLabel(6), .colorLabel(4), L("Color label")),
                       row(.extendNext, L("Extend selection")), row(.compare),
                       row(.repeatLast), row(.undo), row(.redo)]
        let file = [row(.rename), row(.copyImage), row(.copyPath), row(.revealInFinder), row(.share),
                    row(.openInEditor)]
        let edit = [row(.rotateLeft), row(.rotateRight), row(.flipHorizontal), row(.crop), row(.export, L("Export")),
                    row(.exportWithPreset)]
        let system = [row(.commandPalette), row(.cheatSheet)]

        return [(Command.Group.navigation.title, navigation), (Command.Group.view.title, view),
                (Command.Group.zoom.title, zoom), (Command.Group.culling.title, culling),
                (Command.Group.file.title, file), (Command.Group.edit.title, edit),
                (Command.Group.system.title, system)]
            .map { ($0.0, $0.1.compactMap { $0 }) }
            .filter { !$0.1.isEmpty }
    }

    private static func columnStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private static func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func rowView(_ row: Row) -> NSView {
        let keys = NSTextField(labelWithString: row.keys)
        keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keys.alignment = .right
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [keys, title])
        stack.spacing = 12
        return stack
    }
}

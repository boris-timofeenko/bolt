import AppKit

/// The strip along the bottom, IrfanView-style: position, name, size, date, zoom.
/// The name doubles as the rename field.
final class StatusBarView: NSView, NSTextFieldDelegate {
    struct Content {
        var position = ""
        var name = ""
        var labels = NSAttributedString()
        var details: [String] = []
        var zoom = ""
        var sort = ""
    }

    static let height: CGFloat = 24

    var onSortClick: ((NSView) -> Void)?
    private var renameHandler: ((String?) -> Void)?

    private let positionLabel = StatusBarView.label()
    private let nameField = StatusBarView.label(color: .labelColor)
    private let labelsField = StatusBarView.label()
    private let detailLabels = (0..<4).map { _ in StatusBarView.label() }
    private let zoomLabel = StatusBarView.label()
    private let progressLabel = StatusBarView.label(color: .labelColor)
    private let sortButton = NSButton(title: "", target: nil, action: nil)
    /// Thin vertical rules between fields, like the dividers in IrfanView's status bar. Laid out by hand
    /// with the fields: stack views ran the constraint solver on every photo change and on launch.
    private var separators: [CALayer] = []

    private var leadingFields: [NSView] { [positionLabel, nameField, labelsField] + detailLabels }
    private var trailingFields: [NSView] { [progressLabel, zoomLabel, sortButton] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingMiddle
        for label in detailLabels { label.lineBreakMode = .byTruncatingTail }

        sortButton.isBordered = false
        sortButton.font = .systemFont(ofSize: 11)
        sortButton.contentTintColor = .secondaryLabelColor
        sortButton.target = self
        sortButton.action = #selector(sortClicked)

        (leadingFields + trailingFields).forEach(addSubview)
        setProgress(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for separator in separators { separator.backgroundColor = NSColor.separatorColor.cgColor }
    }

    // MARK: - Layout

    // Frames include the 2 pt a text field keeps around its text, so these are 2 pt less than the gaps seen.
    private static let leftInset: CGFloat = 2
    private static let rightInset: CGFloat = 4
    /// A separator with the space around it.
    private static let separatorWidth: CGFloat = 13
    /// Narrower than this, a detail is dropped rather than shown as "…".
    private static let minimumDetailWidth: CGFloat = 40
    private static let minimumNameWidth: CGFloat = 60

    override func layout() {
        super.layout()
        var rules: [CGFloat] = []

        // Trailing fields keep their full width, right to left.
        var x = bounds.width - Self.rightInset
        for (index, field) in trailingFields.filter({ !$0.isHidden }).reversed().enumerated() {
            if index > 0 {
                x -= Self.separatorWidth
                rules.append(x + Self.separatorWidth / 2)
            }
            let width = Self.naturalSize(of: field).width
            x -= width
            place(field, x: x, width: width)
        }

        // Leading fields share what's left: details give way first, from the last one, then the name.
        let available = x - Self.leftInset - 6
        let fields = leadingFields.filter { !$0.isHidden }
        var widths = fields.map { $0 === nameField && isRenaming ? renameFieldWidth() : Self.naturalSize(of: $0).width }
        var shown = Array(repeating: true, count: fields.count)
        func total() -> CGFloat {
            zip(widths, shown).reduce(0) { $0 + ($1.1 ? $1.0 : 0) }
                + CGFloat(max(shown.filter { $0 }.count - 1, 0)) * Self.separatorWidth
        }
        for index in fields.indices.reversed() where detailLabels.contains(where: { $0 === fields[index] }) {
            let excess = total() - available
            guard excess > 0 else { break }
            if widths[index] - excess >= Self.minimumDetailWidth {
                widths[index] -= excess
            } else {
                shown[index] = false
            }
        }
        if let name = fields.firstIndex(where: { $0 === nameField }), total() > available {
            widths[name] = max(widths[name] - (total() - available), Self.minimumNameWidth)
        }

        x = Self.leftInset
        var first = true
        for (index, field) in fields.enumerated() {
            guard shown[index] else {
                field.frame = .zero
                continue
            }
            if !first {
                rules.append(x + Self.separatorWidth / 2)
                x += Self.separatorWidth
            }
            first = false
            place(field, x: x, width: widths[index])
            x += widths[index]
        }
        placeSeparators(at: rules)
    }

    /// An editable field has no width of its own: the text's, plus room to type.
    private func renameFieldWidth() -> CGFloat {
        max(ceil(nameField.cell?.cellSize.width ?? 0) + 24, 160)
    }

    /// The intrinsic size plus the padding a control keeps outside it.
    private static func naturalSize(of field: NSView) -> NSSize {
        let frame = field.frame(forAlignmentRect: NSRect(origin: .zero, size: field.intrinsicContentSize))
        return NSSize(width: ceil(frame.width), height: ceil(frame.height))
    }

    private func place(_ field: NSView, x: CGFloat, width: CGFloat) {
        let height = Self.naturalSize(of: field).height
        field.frame = NSRect(x: x, y: floor((bounds.height - height) / 2), width: width, height: height)
    }

    private func placeSeparators(at positions: [CGFloat]) {
        while separators.count < positions.count {
            let separator = CALayer()
            layer?.addSublayer(separator)
            separators.append(separator)
            // The colour depends on the appearance; `updateLayer` sets it.
            needsDisplay = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, separator) in separators.enumerated() {
            separator.isHidden = index >= positions.count
            guard index < positions.count else { continue }
            separator.frame = CGRect(x: floor(positions[index]), y: (bounds.height - 12) / 2, width: 1, height: 12)
        }
        CATransaction.commit()
    }

    var isRenaming: Bool { renameHandler != nil }

    /// "Converting 120 / 400" while a batch runs; nil hides it.
    func setProgress(_ text: String?) {
        progressLabel.stringValue = text ?? ""
        progressLabel.isHidden = text == nil
        needsLayout = true
    }

    func update(_ content: Content) {
        positionLabel.stringValue = content.position
        if !isRenaming { nameField.stringValue = content.name }
        nameField.isHidden = content.name.isEmpty
        labelsField.attributedStringValue = content.labels
        labelsField.isHidden = content.labels.length == 0
        for (index, label) in detailLabels.enumerated() {
            label.stringValue = index < content.details.count ? content.details[index] : ""
            label.isHidden = index >= content.details.count
        }
        zoomLabel.stringValue = content.zoom
        sortButton.title = content.sort
        needsLayout = true
    }

    // MARK: - Rename

    /// Turns the name into a text field with the part before the extension selected.
    /// The handler gets the new name, or nil if the user pressed Esc.
    func beginRename(_ name: String, completion: @escaping (String?) -> Void) {
        renameHandler = completion
        nameField.stringValue = name
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBezeled = true
        nameField.bezelStyle = .squareBezel
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        window?.makeFirstResponder(nameField)
        let stem = (name as NSString).deletingPathExtension
        nameField.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishRename(with: nameField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishRename(with: nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        needsLayout = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicking elsewhere keeps what was typed, like Finder.
        if isRenaming { finishRename(with: nameField.stringValue) }
    }

    private func finishRename(with name: String?) {
        guard let handler = renameHandler else { return }
        renameHandler = nil
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        needsLayout = true
        handler(name)
    }

    // MARK: - Building blocks

    @objc private func sortClicked() {
        onSortClick?(sortButton)
    }

    private static func label(color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.cell?.usesSingleLineMode = true
        return label
    }
}

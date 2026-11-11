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
    private let leading = NSStackView()
    private let trailing = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in detailLabels {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        }

        sortButton.isBordered = false
        sortButton.font = .systemFont(ofSize: 11)
        sortButton.contentTintColor = .secondaryLabelColor
        sortButton.target = self
        sortButton.action = #selector(sortClicked)

        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.spacing = 0
            stack.alignment = .centerY
            addSubview(stack)
        }
        add([positionLabel, nameField, labelsField] + detailLabels, to: leading)
        add([progressLabel, zoomLabel, sortButton], to: trailing)
        setProgress(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        let trailingWidth = trailing.fittingSize.width
        trailing.frame = NSRect(x: bounds.width - trailingWidth - 6, y: 0, width: trailingWidth, height: bounds.height)
        leading.frame = NSRect(x: 4, y: 0, width: max(bounds.width - trailingWidth - 16, 0), height: bounds.height)
    }

    var isRenaming: Bool { renameHandler != nil }

    /// "Converting 120 / 400" while a batch runs; nil hides it.
    func setProgress(_ text: String?) {
        progressLabel.stringValue = text ?? ""
        progressLabel.isHidden = text == nil
        if let index = trailing.arrangedSubviews.firstIndex(of: progressLabel) {
            trailing.arrangedSubviews[index + 1].isHidden = text == nil
        }
        needsLayout = true
    }

    func update(_ content: Content) {
        positionLabel.stringValue = content.position
        if !isRenaming { nameField.stringValue = content.name }
        setField(nameField, visible: !content.name.isEmpty)
        labelsField.attributedStringValue = content.labels
        setField(labelsField, visible: content.labels.length > 0)
        for (index, label) in detailLabels.enumerated() {
            label.stringValue = index < content.details.count ? content.details[index] : ""
            setField(label, visible: index < content.details.count)
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
        handler(name)
    }

    // MARK: - Building blocks

    /// Hides a field together with the divider in front of it.
    private func setField(_ field: NSView, visible: Bool) {
        field.isHidden = !visible
        if let index = leading.arrangedSubviews.firstIndex(of: field), index > 0 {
            leading.arrangedSubviews[index - 1].isHidden = !visible
        }
    }

    @objc private func sortClicked() {
        onSortClick?(sortButton)
    }

    private func add(_ views: [NSView], to stack: NSStackView) {
        for (index, view) in views.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.separator()) }
            stack.addArrangedSubview(view)
        }
    }

    private static func label(color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.cell?.usesSingleLineMode = true
        return label
    }

    /// A thin vertical rule with padding, like the dividers in IrfanView's status bar.
    private static func separator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 17),
            container.heightAnchor.constraint(equalToConstant: 12),
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }
}

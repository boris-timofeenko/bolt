import AppKit

/// One row of the quick picker.
struct PickerItem {
    var title: String
    var subtitle: String?
    /// Right-aligned hint, usually a shortcut.
    var accessory: String?
    var action: () -> Void
}

/// A search field over a short list, shown at the top of the window. Used for the folder picker
/// and the command palette. Typing filters, arrows move, Return picks, Esc closes.
final class QuickPicker: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let provider: (String) -> [PickerItem]
    private var items: [PickerItem] = []

    private static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 30
    private static let maxVisibleRows = 9

    init(title: String, placeholder: String, provider: @escaping (String) -> [PickerItem]) {
        self.provider = provider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        addSubview(field)

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)

        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func present(in container: NSView) {
        container.addSubview(self)
        layoutInContainer()
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard superview != nil else { return }
        removeFromSuperview()
        onClose?()
    }

    func layoutInContainer() {
        guard let container = superview else { return }
        let visibleRows = CGFloat(min(max(items.count, 1), Self.maxVisibleRows))
        let height = 30 + 34 + visibleRows * Self.rowHeight + 8
        let width = min(Self.width, container.bounds.width - 32)
        frame = NSRect(x: (container.bounds.width - width) / 2, y: 48, width: width, height: height)
        titleLabel.frame = NSRect(x: 14, y: 10, width: width - 28, height: 16)
        field.frame = NSRect(x: 12, y: 28, width: width - 24, height: 26)
        scroll.frame = NSRect(x: 4, y: 62, width: width - 8, height: visibleRows * Self.rowHeight)
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    private func reload() {
        items = provider(field.stringValue)
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        layoutInContainer()
    }

    private func choose(row: Int) {
        guard items.indices.contains(row) else { return }
        let action = items[row].action
        dismiss()
        action()
    }

    @objc private func rowClicked() {
        choose(row: table.clickedRow)
    }

    // MARK: - Field

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            choose(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Focus went elsewhere, e.g. a click on the photo.
        if window?.firstResponder !== field.currentEditor() { dismiss() }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PickerRowView.identifier, owner: nil) as? PickerRowView
            ?? PickerRowView()
        cell.configure(items[row])
        return cell
    }
}

private final class PickerRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerRow")

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        accessory.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        accessory.textColor = .secondaryLabelColor

        // The title keeps its full width; the path gives way first.
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, subtitle, accessory])
        stack.spacing = 10
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: PickerItem) {
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle ?? ""
        accessory.stringValue = item.accessory ?? ""
        accessory.isHidden = item.accessory == nil
    }
}

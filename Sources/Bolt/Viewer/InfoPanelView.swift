import AppKit
import BoltCore
import UniformTypeIdentifiers

/// "I": what the file and its EXIF say, in a column on the right.
final class InfoPanelView: NSView {
    static let width: CGFloat = 270

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var coordinate: (latitude: Double, longitude: Double)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let document = FlippedView()
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 0)
        let size = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: size.height)
        scroll.documentView?.frame = NSRect(x: 0, y: 0, width: bounds.width - 2, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Fills in the values. Rows are built once and only updated here: rebuilding them on every
    /// photo cost about 20 ms, more than everything else in a step put together.
    func show(item: PhotoItem?, info: ImageInfo?) {
        if sections.isEmpty { buildRows() }
        coordinate = nil
        if let latitude = info?.latitude, let longitude = info?.longitude { coordinate = (latitude, longitude) }
        let values: [Field: String?] = [
            .name: item?.name,
            .folder: item.map { Format.path($0.folder) },
            .size: item.map { Format.fileSize($0.fileSize) },
            .modified: item.map { Format.dateTime($0.modified) },
            .pixels: info.map { Format.dimensions($0.pixelWidth, $0.pixelHeight)
                + " · " + String(format: L("%.1f MP"), locale: .current, $0.megapixels) },
            .format: info?.typeIdentifier.flatMap(Self.formatName),
            .color: info?.colorProfile,
            .bitDepth: info?.bitDepth.map { L("%d bit", $0) },
            .frames: info.flatMap { $0.isAnimated ? "\($0.frameCount)" : nil },
            .duration: info?.duration.map(Format.duration),
            .camera: info?.camera,
            .lens: info?.lens,
            .focalLength: info.flatMap(Self.focalLength),
            .aperture: info?.fNumber.map { String(format: "ƒ/%.1f", $0) },
            .shutter: info?.exposureTime.map(Format.exposure),
            .iso: info?.iso.map { "\($0)" },
            .taken: info?.captureDate.map(Format.dateTime),
            .coordinates: coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) },
        ]
        for section in sections {
            var anyVisible = false
            for (row, field) in section.fields.enumerated() {
                let value = values[field] ?? nil
                section.values[row].stringValue = value ?? ""
                section.grid.row(at: row).isHidden = value == nil
                anyVisible = anyVisible || value != nil
            }
            section.heading.isHidden = !anyVisible
            section.grid.isHidden = !anyVisible
        }
        mapsButton.isHidden = coordinate == nil
        needsLayout = true
    }

    private enum Field {
        case name, folder, size, modified
        case pixels, format, color, bitDepth, frames, duration
        case camera, lens, focalLength, aperture, shutter, iso, taken
        case coordinates

        var title: String {
            switch self {
            case .name: L("Name")
            case .folder: L("Folder")
            case .size: L("Size")
            case .modified: L("Modified")
            case .pixels: L("Pixels")
            case .format: L("Format")
            case .color: L("Color")
            case .bitDepth: L("Bit depth")
            case .frames: L("Frames")
            case .duration: L("Duration")
            case .camera: L("Camera")
            case .lens: L("Lens")
            case .focalLength: L("Focal length")
            case .aperture: L("Aperture")
            case .shutter: L("Shutter")
            case .iso: L("ISO")
            case .taken: L("Taken")
            case .coordinates: L("Coordinates")
            }
        }
    }

    private struct Section {
        let heading: NSTextField
        let grid: NSGridView
        let fields: [Field]
        let values: [NSTextField]
    }

    private var sections: [Section] = []
    private lazy var mapsButton: NSButton = {
        let button = NSButton(title: L("Open in Maps"), target: self, action: #selector(openInMaps))
        button.bezelStyle = .inline
        button.controlSize = .small
        return button
    }()

    private func buildRows() {
        let layout: [(String, [Field])] = [
            (L("File"), [.name, .folder, .size, .modified]),
            (L("Image"), [.pixels, .format, .color, .bitDepth, .frames, .duration]),
            (L("Camera"), [.camera, .lens, .focalLength, .aperture, .shutter, .iso, .taken]),
            (L("Location"), [.coordinates]),
        ]
        for (title, fields) in layout {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            let values = fields.map { field in
                let text = NSTextField(wrappingLabelWithString: "")
                text.font = .systemFont(ofSize: 11)
                text.isSelectable = true
                text.preferredMaxLayoutWidth = Self.width - 120
                if field == .folder {
                    // A path is read from the end; one line is enough.
                    text.maximumNumberOfLines = 1
                    text.lineBreakMode = .byTruncatingHead
                }
                return text
            }
            let grid = NSGridView(views: zip(fields, values).map { field, value in
                let key = NSTextField(labelWithString: field.title)
                key.font = .systemFont(ofSize: 11)
                key.textColor = .secondaryLabelColor
                return [key, value]
            })
            grid.columnSpacing = 8
            grid.rowSpacing = 3
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 78
            if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(grid)
            sections.append(Section(heading: heading, grid: grid, fields: fields, values: values))
        }
        stack.addArrangedSubview(mapsButton)
    }

    @objc private func openInMaps() {
        // Maps does the network part; Bolt itself never goes online.
        guard let coordinate,
              let url = URL(string: String(format: "maps://?ll=%.6f,%.6f&q=%.6f,%.6f", coordinate.latitude,
                                           coordinate.longitude, coordinate.latitude, coordinate.longitude))
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func focalLength(_ info: ImageInfo) -> String? {
        guard let focal = info.focalLength else { return nil }
        let text = String(format: L("%@ mm"), Format.number(focal))
        guard let equivalent = info.focalLength35mm, equivalent > 0 else { return text }
        return L("%@ (%d mm equiv.)", text, equivalent)
    }

    private static func formatName(_ identifier: String) -> String? {
        UTType(identifier)?.localizedDescription ?? identifier
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

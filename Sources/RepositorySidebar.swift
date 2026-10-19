import AppKit

/// One geometry contract for the selection fill and every row's text.
enum RepositoryRowMetrics {
    static func selection(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: min(4, bounds.width / 2), dy: min(2, bounds.height / 2))
    }

    static func content(in bounds: NSRect) -> NSRect {
        let selection = selection(in: bounds)
        return selection.insetBy(dx: min(10, selection.width / 2), dy: min(6, selection.height / 2))
    }

    static var height: CGFloat {
        max(52, ceil(Skin.ui(0, .medium).boundingRectForFont.height)
            + ceil(Skin.ui(-2).boundingRectForFont.height) + 20)
    }

    static var selectionColor: NSColor {
        Skin.c.panel.blended(withFraction: 0.22, of: Skin.c.accent) ?? Skin.c.panel
    }
}

final class RepositoryRowView: NSTableRowView {
    override var isSelected: Bool { didSet { refreshCells(); needsDisplay = true } }
    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        RepositoryRowMetrics.selectionColor.setFill()
        NSBezierPath(roundedRect: RepositoryRowMetrics.selection(in: bounds), xRadius: 5, yRadius: 5).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        refreshCells()
    }

    private func refreshCells() {
        for cell in subviews.compactMap({ $0 as? RepositoryCellView }) { cell.restyle() }
    }
}

/// Fixed-width, single-line labels. Long text cannot expand the table column.
final class RepositoryCellView: NSTableCellView, Skinnable {
    let titleLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    private let title: String
    private let location: String
    private let current: Bool

    init(title: String, location: String, current: Bool, fullPath: String) {
        self.title = title
        self.location = location
        self.current = current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for label in [titleLabel, pathLabel] {
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        toolTip = fullPath
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel((current ? "Current repository, " : "") + title + (location.isEmpty ? "" : ", " + fullPath))
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        restyle()
    }

    func restyle() {
        let selected = (superview as? NSTableRowView)?.isSelected == true
        let background = selected ? RepositoryRowMetrics.selectionColor : Skin.c.panel
        titleLabel.font = Skin.ui(0, .medium)
        pathLabel.font = Skin.ui(-2)
        titleLabel.textColor = StyledText.readable(current ? Skin.c.accent : Skin.c.ink, on: background)
        pathLabel.textColor = StyledText.readable(Skin.c.inkSoft, on: background)
        titleLabel.stringValue = (current ? "✓ " : "") + title
        pathLabel.stringValue = location
        pathLabel.isHidden = location.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Convert from the row's actual selection geometry, not an intrinsic cell width.
        let content: NSRect
        if let row = superview as? NSTableRowView {
            content = convert(RepositoryRowMetrics.content(in: row.bounds), from: row).intersection(bounds)
        } else {
            content = RepositoryRowMetrics.content(in: bounds)
        }
        let titleHeight = min(ceil(titleLabel.font!.boundingRectForFont.height), content.height)
        let pathHeight = location.isEmpty ? 0 : min(ceil(pathLabel.font!.boundingRectForFont.height), max(0, content.height - titleHeight - 3))
        let total = titleHeight + (pathHeight > 0 ? 3 + pathHeight : 0)
        let bottom = content.midY - total / 2
        if isFlipped {
            titleLabel.frame = NSRect(x: content.minX, y: bottom, width: content.width, height: titleHeight)
            pathLabel.frame = NSRect(x: content.minX, y: bottom + titleHeight + 3, width: content.width, height: pathHeight)
        } else {
            pathLabel.frame = NSRect(x: content.minX, y: bottom, width: content.width, height: pathHeight)
            titleLabel.frame = NSRect(x: content.minX, y: bottom + total - titleHeight, width: content.width, height: titleHeight)
        }
    }
}

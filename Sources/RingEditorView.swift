import AppKit

private final class RingEditorNode: NSButton {
    var chosen = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: bounds.midX - 27, y: 2, width: 54, height: 54)
        (chosen ? NSColor.controlAccentColor : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if let image {
            let ink: NSColor = chosen ? .white : .labelColor
            let tinted = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { rect in
                image.draw(in: rect)
                if image.isTemplate { ink.setFill(); rect.fill(using: .sourceIn) }
                return true
            }
            tinted.draw(in: NSRect(x: bounds.midX - 13, y: 16, width: 26, height: 26))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: NSRect(x: 0, y: 61, width: bounds.width, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: chosen ? .semibold : .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
}

/// A spatial editor: the same eight directions are used for selection and arrangement.
final class RingEditorView: NSView {
    var config = Configuration() { didSet { rebuild() } }
    var selection = ItemLocation(root: 0, child: nil) { didSet { if selection != oldValue { parent = selection.child != nil ? selection.root : nil }; rebuild() } }
    var onSelect: ((ItemLocation) -> Void)?
    var onAdd: (() -> Void)?
    private(set) var parent: Int?
    private var nodes: [NSButton] = []
    private let back = NSButton(title: "", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 18; layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        back.bezelStyle = .circular; back.target = self; back.action = #selector(goBack); back.setAccessibilityLabel("返回主圆环"); addSubview(back)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    func showChildren() { guard config.items[selection.root].action == .submenu else { return }; parent = selection.root; rebuild() }
    func showRoot() { parent = nil; rebuild() }
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private func rebuild() {
        nodes.forEach { $0.removeFromSuperview() }; nodes.removeAll()
        if let parent, config.items[parent].action != .submenu { self.parent = nil }
        let items = parent.map { config.items[$0].children } ?? config.items
        for index in 0..<8 {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / 4
            let point = NSPoint(x: center.x + cos(angle) * 143, y: center.y + sin(angle) * 143)
            let button = RingEditorNode(title: "", target: self, action: #selector(selected(_:)))
            button.frame = NSRect(x: point.x - 48, y: point.y - 39, width: 96, height: 80)
            button.tag = index; button.isBordered = false; button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown; button.font = .systemFont(ofSize: 11, weight: .medium)
            let selected = parent == nil ? (selection.child == nil && selection.root == index) : (selection.root == parent && selection.child == index)
            if index < items.count {
                let item = items[index]; button.title = item.title
                let image = item.iconPNG.flatMap { NSImage(data: $0) } ?? DialIcons.image(named: item.effectiveSymbol)
                button.image = image?.copy() as? NSImage; button.image?.isTemplate = item.iconPNG == nil || item.templateIcon; button.image?.size = NSSize(width: 25, height: 25)
                button.toolTip = item.title; button.setAccessibilityLabel(item.title + (item.action == .submenu ? "，二级菜单" : ""))
            } else {
                button.title = "添加"; button.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "添加子项")
                button.isHidden = index != items.count
            }
            button.chosen = selected
            addSubview(button); nodes.append(button)
        }
        back.frame = NSRect(x: center.x - 27, y: center.y - 27, width: 54, height: 54)
        back.image = NSImage(systemSymbolName: parent == nil ? "circle.hexagongrid" : "arrow.uturn.backward", accessibilityDescription: nil)
        back.isEnabled = parent != nil; needsDisplay = true
    }
    override func layout() { super.layout(); rebuild() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - 143, y: center.y - 143, width: 286, height: 286))
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke(); circle.lineWidth = 1; circle.stroke()
    }
    @objc private func selected(_ sender: NSButton) {
        if let parent {
            if sender.tag >= config.items[parent].children.count { onAdd?(); return }
            onSelect?(ItemLocation(root: parent, child: sender.tag))
        } else { onSelect?(ItemLocation(root: sender.tag, child: nil)) }
    }
    @objc private func goBack() { let root = parent ?? selection.root; parent = nil; onSelect?(ItemLocation(root: root, child: nil)); rebuild() }
}

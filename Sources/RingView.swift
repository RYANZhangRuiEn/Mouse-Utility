import AppKit
import QuartzCore

final class DialPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class BubbleLayers {
    let body = CALayer(), icon = CALayer(), marker = CALayer()
    let track = CAShapeLayer(), progress = CAShapeLayer()
    var item: MenuItem?
    init(parent: CALayer, radius: CGFloat) {
        body.bounds = NSRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        body.cornerRadius = radius
        icon.frame = NSRect(x: radius - 14, y: radius - 14, width: 28, height: 28)
        icon.contentsGravity = .resizeAspect; icon.contentsScale = 2
        marker.frame = NSRect(x: radius * 2 - 5, y: radius * 2 - 5, width: 5, height: 5); marker.cornerRadius = 2.5
        body.addSublayer(icon); body.addSublayer(marker); parent.addSublayer(body)
        let path = CGMutablePath()
        path.addArc(center: NSPoint(x: radius, y: radius), radius: radius + 4.5, startAngle: .pi / 2, endAngle: -.pi * 1.5, clockwise: true)
        for ring in [track, progress] { ring.bounds = body.bounds; ring.path = path; ring.fillColor = nil; ring.lineWidth = 2.5; ring.lineCap = .round; parent.addSublayer(ring) }
        progress.strokeEnd = 0
    }
    func place(_ p: NSPoint) { body.position = p; track.position = p; progress.position = p }
    func hide(_ hidden: Bool) { body.isHidden = hidden; track.isHidden = hidden || item?.action.adjustable != true; progress.isHidden = hidden || item?.action.adjustable != true }
}

/// No hardware calls or image decoding in the pointer path; all node images are cached on edit.
final class RingView: NSView {
    weak var controller: AppController?
    private let canvas = CALayer()
    private var items = MenuItem.recommended()
    private var style = RingAppearance()
    private var rootLayers: [BubbleLayers] = [], childLayers: [BubbleLayers] = []
    private var rootButtons: [NSButton] = [], childButtons: [NSButton] = []
    private var closeButton: NSButton!
    private let closeBubble = CALayer(), closeIcon = CALayer()
    private let badge = CALayer(), badgeText = CATextLayer()
    private var images: [UUID: (CGImage?, CGImage?)] = [:]
    private var imageCache: [String: CGImage] = [:]
    private var values: [DialAction: Double] = [:]
    private var lastHapticID:UUID?
    var onHapticSelection:((UUID)->Void)?
    var onHapticClick:(()->Void)?
    private(set) var hovered: Int?
    private(set) var hoveredChild: Int?
    private(set) var openParent: Int?
    private var armed: Int?
    private var pinnedItem: MenuItem?
    private var closeHovered = false
    private var tracking: NSTrackingArea?
    private var expansion: DispatchWorkItem?
    private var expansionToken = 0
    private var integrator = LevelWheelInterpreter()
    private var sideIntegrator = SideWheelSteps()
    private var dragAction: DialAction?
    private var dragY: CGFloat = 0
    private var status = ""
    private var rootHighlighted = Array(repeating: false, count: 8)
    private var childHighlighted = Array(repeating: false, count: 8)
    private var renderedClose: Bool?
    private var deferringBadge = false
    private var idleColor = NSColor.white.cgColor
    private var accentColor = NSColor.black.cgColor
    private var normalInkColor = NSColor.black.cgColor
    private var activeInkColor = NSColor.white.cgColor
    private(set) var scale = 1.0
    var selected = 0
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    var activeSlot: Int? { hovered ?? openParent ?? armed }
    var activeItem: MenuItem? {
        if let parent = openParent, let child = hoveredChild, items[parent].children.indices.contains(child) { return items[parent].children[child] }
        if hovered == nil, let pinnedItem { return pinnedItem }
        return activeSlot.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
        canvas.anchorPoint = .zero; canvas.position = .zero; canvas.bounds = NSRect(origin: .zero, size: RingGeometry.size); layer?.addSublayer(canvas)
        for i in 0..<8 {
            let root = BubbleLayers(parent: canvas, radius: RingGeometry.bubbleRadius)
            root.place(RingGeometry.point(i)); rootLayers.append(root)
            let button = makeButton(tag: i, selector: #selector(rootPressed(_:)))
            rootButtons.append(button)
        }
        for i in 0..<8 {
            let child = BubbleLayers(parent: canvas, radius: 25); child.hide(true); childLayers.append(child)
            let button = makeButton(tag: i, selector: #selector(childPressed(_:))); button.isHidden = true; childButtons.append(button)
        }
        closeBubble.frame = NSRect(x: 240, y: 240, width: 40, height: 40); closeBubble.cornerRadius = 20
        closeIcon.frame = NSRect(x: 12, y: 12, width: 16, height: 16); closeIcon.contentsScale = 2
        closeBubble.addSublayer(closeIcon); canvas.addSublayer(closeBubble)
        closeButton = makeButton(tag: 0, selector: #selector(closeRing)); closeButton.setAccessibilityLabel("关闭圆环")
        badge.cornerRadius = 9; badge.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.93).cgColor; badge.isHidden = true
        badgeText.font = NSFont.systemFont(ofSize: 11, weight: .medium); badgeText.fontSize = 11; badgeText.contentsScale = 2
        badgeText.foregroundColor = NSColor.white.cgColor; badgeText.alignmentMode = .center; badgeText.truncationMode = .end
        badge.addSublayer(badgeText); canvas.addSublayer(badge)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        loadConfiguration()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func makeButton(tag: Int, selector: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: selector)
        button.tag = tag; button.isTransparent = true; button.refusesFirstResponder = true; addSubview(button); return button
    }
    private func transaction(_ body: () -> Void) { CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit() }
    func loadConfiguration() {
        let config = controller?.store.config ?? Configuration()
        items = config.items; style = config.appearance
        idleColor = style.idle.cgColor; accentColor = style.accent.cgColor
        normalInkColor = style.normalInk.cgColor; activeInkColor = style.activeInk.cgColor
        expansion?.cancel(); openParent = nil; hoveredChild = nil; imageCache.removeAll(keepingCapacity: true); images.removeAll(keepingCapacity: true)
        for node in items.flatMap({ [$0] + $0.children }) {
            images[node.id] = (renderImage(node, active: false), renderImage(node, active: true))
        }
        rootHighlighted = Array(repeating: false, count: 8); childHighlighted = Array(repeating: false, count: 8)
        transaction {
            for i in 0..<8 {
                configure(rootLayers[i], item: items[i]); rootButtons[i].setAccessibilityLabel("位置 \(i + 1)：" + items[i].title)
                childLayers[i].hide(true); childButtons[i].isHidden = true
            }
            closeIcon.contents = renderSymbol("xmark", color: .black, size: 16)
            updateHighlights(); updateProgress()
        }
        setScale(scale); updateBadge()
    }
    func setScale(_ value: Double) {
        scale = value
        transaction { canvas.setAffineTransform(CGAffineTransform(scaleX: value, y: value)) }
        for i in 0..<8 { rootButtons[i].frame = scaled(rootLayers[i].body.frame); childButtons[i].frame = scaled(childLayers[i].body.frame) }
        closeButton.frame = scaled(closeBubble.frame)
    }
    private func scaled(_ rect: NSRect) -> NSRect { NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale) }
    private func configure(_ layers: BubbleLayers, item: MenuItem) {
        layers.item = item; layers.icon.contents = images[item.id]?.0
        layers.body.backgroundColor = style.idle.cgColor
        layers.body.opacity = item.action == .none ? 0.32 : 1
        layers.marker.isHidden = item.action != .submenu
        layers.marker.backgroundColor = style.normalInk.cgColor
        layers.track.strokeColor = style.normalInk.withAlphaComponent(0.16).cgColor
        layers.progress.strokeColor = style.accent.cgColor
        layers.hide(false)
    }
    private func renderSymbol(_ symbol: String, color: NSColor, size: CGFloat) -> CGImage? {
        let key = symbol + color.description + String(Double(size))
        if let cached = imageCache[key] { return cached }
        guard let base = DialIcons.image(named: symbol) else { return nil }
        let image = base.withSymbolConfiguration(.init(pointSize: size - 3, weight: .medium)) ?? base
        let result = raster(image, color: color, size: size)
        if let result { imageCache[key] = result }; return result
    }
    private func renderImage(_ item: MenuItem, active: Bool) -> CGImage? {
        let color = active ? style.activeInk : style.normalInk
        if let data = item.iconPNG, let image = NSImage(data: data) { return raster(image, color: item.templateIcon ? color : nil, size: 32) }
        return renderSymbol(item.effectiveSymbol, color: color, size: 32) ?? renderSymbol("questionmark", color: color, size: 32)
    }
    private func raster(_ image: NSImage, color: NSColor?, size: CGFloat) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * 2), pixelsHigh: Int(size * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let aspect = image.size.width / max(1, image.size.height), extent = size - 4
        let fit = aspect > 1 ? NSSize(width: extent, height: extent / aspect) : NSSize(width: extent * aspect, height: extent)
        image.draw(in: NSRect(x: (size - fit.width) / 2, y: (size - fit.height) / 2, width: fit.width, height: fit.height))
        if let color { color.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceIn) }
        NSGraphicsContext.restoreGraphicsState(); return bitmap.cgImage
    }
    func prepare(armedSlot: Int? = nil, armedAction: DialAction? = nil) {
        lastHapticID = nil
        expansion?.cancel(); expansionToken += 1
        hovered = nil; hoveredChild = nil; openParent = nil; armed = armedSlot; pinnedItem = armedAction.map { MenuItem($0) }; closeHovered = false; status = ""; dragAction = nil
        if let armedSlot { selected = armedSlot }; integrator.reset(); sideIntegrator.reset()
        transaction { for i in 0..<8 { childLayers[i].hide(true); childButtons[i].isHidden = true }; updateHighlights() }
        updateBadge()
    }
    func movePointer(to p: NSPoint) {
        let old = activeItem?.id
        var root = RingGeometry.hit(p)
        let close = RingGeometry.isClose(p)
        let child = openParent.flatMap { RingGeometry.childHit(p, parent: $0, count: items[$0].children.count) }
        let bridge = openParent.map { RingGeometry.inBridge(p, parent: $0, count: items[$0].children.count) } ?? false
        if child == nil, let candidate = root, candidate != openParent, openParent != nil {
            if !bridge { collapseFolder(notify: false) }
            else {
                let center = RingGeometry.point(candidate)
                if hypot(p.x - center.x, p.y - center.y) > 33 { root = nil }
                // Inside a neighboring bubble, defer switching briefly so a crossing path
                // toward a wide secondary fan cannot immediately destroy the open menu.
            }
        }
        let newChild = openParent == nil ? nil : child
        guard hovered != root || hoveredChild != newChild || closeHovered != close || old != activeItem?.id else { return }
        hovered = root; hoveredChild = newChild; closeHovered = close
        if let root { selected = root; armed = nil; pinnedItem = nil }
        let changed = old != activeItem?.id
        if changed { integrator.reset(); sideIntegrator.reset(); status = ""; expansion?.cancel(); expansionToken += 1 }
        transaction { updateHighlights() }
        deferringBadge = true
        let pointedID:UUID?
        if let parent = openParent,let child = newChild { pointedID = items[parent].children[child].id }
        else { pointedID = root.map { items[$0].id } }
        if pointedID != lastHapticID { lastHapticID = pointedID; if let pointedID { onHapticSelection?(pointedID) } }
        if changed { controller?.hoverChanged() }
        deferringBadge = false; updateBadge()
        if let root, openParent != root, changed, items[root].action == .submenu || (openParent != nil && bridge) {
            let token = expansionToken
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.expansionToken == token, self.hovered == root else { return }
                if self.items[root].action == .submenu { self.openFolder(root) }
                else { self.collapseFolder() }
            }
            expansion = work; DispatchQueue.main.asyncAfter(deadline: .now() + style.hoverDelay, execute: work)
        }
    }
    func openFolder(_ root: Int) {
        guard items.indices.contains(root), items[root].action == .submenu else { return }
        expansion?.cancel(); expansionToken += 1
        let children = items[root].children
        guard !children.isEmpty else { setStatus("菜单为空 · 在设置中添加子项"); return }
        openParent = root; hovered = root; hoveredChild = nil; armed = nil; pinnedItem = nil
        childHighlighted = Array(repeating: false, count: 8)
        transaction {
            for i in 0..<8 {
                if i < children.count {
                    let layers = childLayers[i]
                    layers.place(RingGeometry.childPoint(parent: root, index: i, count: children.count)); configure(layers, item: children[i])
                    childButtons[i].frame = scaled(layers.body.frame); childButtons[i].isHidden = false
                    childButtons[i].setAccessibilityLabel("二级 \(i + 1)：" + children[i].title)
                } else { childLayers[i].hide(true); childButtons[i].isHidden = true }
            }
            updateHighlights(); updateProgress()
        }
        updateBadge(); controller?.hoverChanged()
    }
    func collapseFolder(notify: Bool = true) {
        expansion?.cancel(); expansionToken += 1; openParent = nil; hoveredChild = nil
        transaction { for i in 0..<8 { childLayers[i].hide(true); childButtons[i].isHidden = true }; updateHighlights() }
        if notify { status = ""; updateBadge(); controller?.hoverChanged() }
    }
    func escape() { dragAction = nil; if openParent != nil { collapseFolder() } else { controller?.hideRing() } }
    private func updateHighlights() {
        for i in 0..<8 {
            let active = i == activeSlot || i == openParent
            if active != rootHighlighted[i] {
                rootHighlighted[i] = active
                rootLayers[i].body.backgroundColor = active ? accentColor : idleColor
                rootLayers[i].icon.contents = active ? images[items[i].id]?.1 : images[items[i].id]?.0
                rootLayers[i].marker.backgroundColor = active ? activeInkColor : normalInkColor
            }
            let childActive = i == hoveredChild
            if childActive != childHighlighted[i], let item = childLayers[i].item {
                childHighlighted[i] = childActive
                childLayers[i].body.backgroundColor = childActive ? accentColor : idleColor
                childLayers[i].icon.contents = childActive ? images[item.id]?.1 : images[item.id]?.0
            }
        }
        if renderedClose != closeHovered {
            renderedClose = closeHovered
            closeBubble.backgroundColor = NSColor(calibratedRed: 1, green: closeHovered ? 0.4 : 0.59, blue: closeHovered ? 0.49 : 0.65, alpha: 0.97).cgColor
        }
    }
    func setProgress(_ action: DialAction, value: Double?) {
        let normalized = value.map { clamp($0) }
        guard values[action] != normalized else { return }
        if let normalized { values[action] = normalized } else { values.removeValue(forKey: action) }
        transaction { updateProgress() }
    }
    private func updateProgress() {
        for layers in rootLayers + childLayers { if let action = layers.item?.action, action.adjustable { layers.progress.strokeEnd = values[action].map { CGFloat($0) } ?? 0 } }
    }
    func setStatus(_ text: String) { guard status != text else { return }; status = text; if !deferringBadge { updateBadge() } }
    private func updateBadge() {
        let text = closeHovered && pinnedItem == nil ? "" : status.isEmpty ? (activeItem?.title ?? "") : status
        transaction {
            badge.isHidden = text.isEmpty
            let width = min(260, max(54, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 22))
            badge.frame = NSRect(x: 260 - width / 2, y: 210, width: width, height: 22)
            badgeText.frame = NSRect(x: 8, y: 4, width: width - 16, height: 15); badgeText.string = text
        }
        setAccessibilityLabel("鼠标圆环，\(activeItem?.title ?? "未选择")。\(status)" + (openParent != nil ? "。二级菜单已展开" : ""))
    }
    @objc private func closeRing() { controller?.hideRing() }
    @objc private func rootPressed(_ sender: NSButton) { activateRoot(sender.tag) }
    @objc private func childPressed(_ sender: NSButton) { activateChild(sender.tag) }
    private func activateRoot(_ slot: Int) {
        onHapticClick?()
        hovered = slot; hoveredChild = nil; armed = nil; pinnedItem = nil; selected = slot
        if items[slot].action == .submenu { openFolder(slot); return }
        collapseFolder(notify: false); transaction { updateHighlights() }; controller?.performItem(items[slot])
    }
    private func activateChild(_ slot: Int) {
        guard let parent = openParent, items[parent].children.indices.contains(slot) else { return }
        onHapticClick?()
        hoveredChild = slot; transaction { updateHighlights() }; controller?.performItem(items[parent].children[slot])
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    private func point(_ event: NSEvent) -> NSPoint { let p = convert(event.locationInWindow, from: nil); return NSPoint(x: p.x / scale, y: p.y / scale) }
    override func mouseEntered(with event: NSEvent) { movePointer(to: point(event)) }
    override func mouseMoved(with event: NSEvent) { movePointer(to: point(event)) }
    override func mouseExited(with event: NSEvent) { if dragAction == nil { movePointer(to: NSPoint(x: -1000, y: -1000)) } }
    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        movePointer(to: p)
        if RingGeometry.isClose(p) { controller?.hideRing(); return }
        if let action = activeItem?.action, action.adjustable { dragAction = action; dragY = p.y }
        if let parent = openParent, let child = RingGeometry.childHit(p, parent: parent, count: items[parent].children.count) { activateChild(child) }
        else if let root = RingGeometry.hit(p) { activateRoot(root) }
        else { controller?.hideRing() }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let action = dragAction { let delta = Double(p.y - dragY) / 150; dragY = p.y; controller?.adjustContinuous(action, delta: delta) }
        else { movePointer(to: p) }
    }
    override func mouseUp(with event: NSEvent) { dragAction = nil; movePointer(to: point(event)) }
    override func scrollWheel(with event: NSEvent) {
        guard let cg = event.cgEvent else { return }
        processScroll(cg, native: event, at: point(event), time: event.timestamp)
    }
    func hardwareScroll(_ cg: CGEvent) {
        guard let window, let event = NSEvent(cgEvent: cg) else { return }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        processScroll(cg, native: event, at: NSPoint(x:local.x/scale,y:local.y/scale), time: ProcessInfo.processInfo.systemUptime)
    }
    private func processScroll(_ cg: CGEvent, native event: NSEvent, at point: NSPoint, time: Double) {
        // Never treat externally interpolated frames as physical wheel notches.
        guard cg.getIntegerValueField(.eventSourceUserData) != MouseEvents.externalSmoothingMarker, cg.getIntegerValueField(.eventSourceUserData) != MouseEvents.sentinel else { return }
        movePointer(to: point)
        guard let action = activeItem?.action, action.adjustable, let config = controller?.store.config else { return }
        let horizontal = abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)
        let settings = config.ringWheel
        if horizontal {
            let steps = sideIntegrator.consume(delta:MouseEvents.physicalDelta(cg,horizontal:true)*(config.reverseScroll ? -1:1),precise:event.hasPreciseScrollingDeltas,momentum:event.momentumPhase != [],time:time)
            if steps != 0 { controller?.adjustContinuous(action,delta:Double(steps)*config.step) }; return
        }
        let motion = integrator.consume(WheelSample(cg),profile:settings.profile,time:time)
        let amount = Double(motion.steps) * (config.reverseScroll ? -1:1)
        if amount != 0 { controller?.adjustContinuous(action,delta:amount*settings.step) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape(); return }
        if let number = event.charactersIgnoringModifiers.flatMap(Int.init), (1...8).contains(number) {
            if let parent = openParent { if number <= items[parent].children.count { activateChild(number - 1) } }
            else { activateRoot(number - 1) }; return
        }
        if event.keyCode == 126 || event.keyCode == 125, let action = activeItem?.action { controller?.adjust(action, steps: event.keyCode == 126 ? 1 : -1); return }
        super.keyDown(with: event)
    }
}

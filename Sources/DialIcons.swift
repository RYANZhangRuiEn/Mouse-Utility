import AppKit

/// Original vector clipboard variants, shared by the picker, outline and ring.
enum DialIcons {
    static let paste = "orbit.clipboard.paste"
    static let plainText = "orbit.clipboard.text"
    static let clipboardSettings = "orbit.clipboard.settings"
    static let additions: [(String, String)] = [
        ("剪贴板 · 粘贴", paste), ("剪贴板 · 纯文本", plainText), ("剪贴板 · 设置", clipboardSettings)
    ]
    static func image(named name: String) -> NSImage? {
        guard [paste, plainText, clipboardSettings].contains(name) else {
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        let result = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.black.setStroke()
            let board = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 5, width: 18, height: 23), xRadius: 2.5, yRadius: 2.5)
            board.lineWidth = 2.1; board.stroke()
            NSGraphicsContext.current?.cgContext.clear(NSRect(x: 9, y: 25, width: 10, height: 5))
            let clip = NSBezierPath(roundedRect: NSRect(x: 9.5, y: 25.5, width: 8, height: 5), xRadius: 1.5, yRadius: 1.5)
            clip.lineWidth = 2.1; clip.stroke()
            NSGraphicsContext.current?.cgContext.clear(NSRect(x: 16, y: 0, width: 16, height: 18))
            if name == paste {
                let card = NSBezierPath(roundedRect: NSRect(x: 18, y: 1.5, width: 11.5, height: 14.5), xRadius: 2, yRadius: 2)
                card.lineWidth = 2.1; card.stroke()
                let lines = NSBezierPath(); lines.lineWidth = 1.8; lines.lineCapStyle = .round
                for y: CGFloat in [7, 11] { lines.move(to: NSPoint(x: 22, y: y)); lines.line(to: NSPoint(x: 25.5, y: y)) }
                lines.stroke()
            } else if name == plainText {
                let text = NSBezierPath(); text.lineWidth = 2.3; text.lineCapStyle = .round; text.lineJoinStyle = .round
                text.move(to: NSPoint(x: 18, y: 12)); text.line(to: NSPoint(x: 29, y: 12))
                text.move(to: NSPoint(x: 23.5, y: 12)); text.line(to: NSPoint(x: 23.5, y: 2))
                text.move(to: NSPoint(x: 20.5, y: 2)); text.line(to: NSPoint(x: 26.5, y: 2))
                text.stroke()
            } else {
                let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
                gear?.draw(in: NSRect(x: 17, y: 0, width: 15, height: 16))
            }
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = additions.first { $0.1 == name }?.0
        return result
    }
}

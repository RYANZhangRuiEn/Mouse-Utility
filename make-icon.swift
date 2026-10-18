import AppKit
import Foundation
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), xRadius: s * 0.22, yRadius: s * 0.22).fill()
    NSColor(calibratedRed: 0.8, green: 0.91, blue: 0.43, alpha: 1).setStroke()
    let center = NSBezierPath(ovalIn: NSRect(x: s * 0.35, y: s * 0.35, width: s * 0.3, height: s * 0.3)); center.lineWidth = s * 0.065; center.stroke()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4
        let x = s * 0.5 + cos(angle) * s * 0.30, y = s * 0.5 + sin(angle) * s * 0.30
        (i == 1 ? NSColor(calibratedRed: 0.8, green: 0.91, blue: 0.43, alpha: 1) : NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.88, alpha: 1)).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - s * 0.048, y: y - s * 0.048, width: s * 0.096, height: s * 0.096)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
}

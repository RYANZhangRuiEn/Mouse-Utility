import AppKit
import Combine

let appName = "鼠环 Preview"
let appID = "local.mousering.preview"
func clamp(_ x: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double { min(upper, max(lower, x)) }

enum DialAction: String, Codable, CaseIterable, Identifiable {
    case shortcut, submenu, brightness, volume, mute, previous, playPause, next, showRing, none
    // Read-only migration values; they never appear as action choices.
    case shortcutA, shortcutB
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcut, .shortcutA, .shortcutB: return "快捷键 / 自定义"
        case .submenu: return "二级菜单"
        case .brightness: return "亮度"
        case .volume: return "音量"
        case .mute: return "静音"
        case .previous: return "上一首"
        case .playPause: return "播放 / 暂停"
        case .next: return "下一首"
        case .showRing: return "打开圆环"
        case .none: return "不使用"
        }
    }
    var symbol: String {
        switch self {
        case .shortcut, .shortcutA, .shortcutB: return "keyboard"
        case .submenu: return "square.grid.2x2"
        case .brightness: return "sun.max"
        case .volume: return "speaker.wave.2"
        case .mute: return "speaker.slash"
        case .previous: return "backward.end.fill"
        case .playPause: return "playpause.fill"
        case .next: return "forward.end.fill"
        case .showRing: return "circle.hexagongrid"
        case .none: return "minus"
        }
    }
    var adjustable: Bool { self == .volume || self == .brightness }
    static let editable: [DialAction] = [.shortcut, .submenu, .volume, .brightness, .mute, .playPause, .previous, .next, .none]
}

struct KeyBinding: Codable, Equatable {
    var name: String
    var keyCode: UInt16
    var modifiers: UInt64
    var keyLabel: String
    var display: String {
        let f = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + keyLabel
    }
    static func command(_ key: String, code: UInt16, extra: NSEvent.ModifierFlags = []) -> KeyBinding {
        KeyBinding(name: "", keyCode: code, modifiers: UInt64(NSEvent.ModifierFlags.command.union(extra).rawValue), keyLabel: key)
    }
}

struct MenuItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var action: DialAction
    var shortcut: KeyBinding?
    var symbol: String?
    var iconPNG: Data?
    var templateIcon = true
    var children: [MenuItem] = []
    init(_ action: DialAction, name: String? = nil, shortcut: KeyBinding? = nil, symbol: String? = nil, children: [MenuItem] = []) {
        self.action = action; self.name = name ?? action.title; self.shortcut = shortcut; self.symbol = symbol; self.children = children
    }
    var title: String { name.isEmpty ? action.title : name }
    var effectiveSymbol: String { symbol?.isEmpty == false ? symbol! : action.symbol }
    static func media() -> MenuItem { MenuItem(.submenu, name: "媒体", symbol: "playpause", children: [.init(.previous), .init(.playPause), .init(.next)]) }
    static func custom(_ number: Int) -> MenuItem { MenuItem(.shortcut, name: "自定义 \(number)") }
    static func recommended() -> [MenuItem] {
        [.init(.volume), .init(.brightness), .media(), .init(.mute),
         .custom(1), .custom(2),
         .init(.submenu, name: "常用快捷键", symbol: "command", children: [
            .init(.shortcut, name: "复制", shortcut: .command("C", code: 8), symbol: "doc.on.doc"),
            .init(.shortcut, name: "粘贴", shortcut: .command("V", code: 9), symbol: "orbit.clipboard.paste"),
            .init(.shortcut, name: "剪切", shortcut: .command("X", code: 7), symbol: "scissors")]),
         .custom(3)]
    }
}

struct RingAppearance: Codable, Equatable {
    var theme = "light"
    var accentHex = "#151515"
    var scale = 1.0
    var hoverDelay = 0.14
    var dark: Bool { theme == "dark" }
    var idle: NSColor { dark ? NSColor(calibratedWhite: 0.17, alpha: 0.97) : NSColor(calibratedWhite: 0.98, alpha: 0.97) }
    var normalInk: NSColor { dark ? .white : NSColor(calibratedWhite: 0.07, alpha: 1) }
    var accent: NSColor {
        if dark && accentHex == "#151515" { return NSColor(calibratedRed: 0.79, green: 0.9, blue: 0.45, alpha: 1) }
        return NSColor(hex: accentHex) ?? .black
    }
    var activeInk: NSColor {
        let c = accent.usingColorSpace(.deviceRGB) ?? .black
        return c.redComponent * 0.2126 + c.greenComponent * 0.7152 + c.blueComponent * 0.0722 > 0.58 ? .black : .white
    }
}
extension NSColor {
    convenience init?(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(calibratedRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.deviceRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
struct ItemLocation: Equatable { var root: Int; var child: Int? }


enum MouseButtonIdentity {
    static func name(_ number:Int) -> String {
        let physical = "按键 \(number+1)"
        return number == 2 ? physical + "（中键）" : physical
    }
}

enum HeldWheelAction: String, Codable, CaseIterable {
    case none, zoom, horizontal, rotate, spaces, volume, brightness
    var title: String {
        switch self {
        case .none: return "保持普通滚动"
        case .zoom: return "触控板式缩放"
        case .horizontal: return "滚轮左右平移"
        case .rotate: return "旋转（支持的应用）"
        case .spaces: return "切换左右桌面"
        case .volume: return "调节系统音量"
        case .brightness: return "调节屏幕亮度"
        }
    }
}
enum HeldMoveAction: String, Codable, CaseIterable {
    case none, pan, windows
    var title: String {
        switch self {
        case .none: return "保持普通移动"
        case .pan: return "自由平移 / 二维滚动"
        case .windows: return "切换桌面 / 调度中心"
        }
    }
}
struct MouseHabits: Codable, Equatable {
    var enabled = false
    var manuallyPaused = false
    var wheel: [String: HeldWheelAction] = [:]
    var move: [String: HeldMoveAction] = [:]
    var reverseMove: [String: Bool] = [:]
    var reverseWheel: [String: Bool] = [:]
    var shortcuts: [String: KeyBinding] = [:]
    var zoomModifiers: UInt64 = 0
    var zoomStyle = "pinch"
    var sensitivity = 1.0
    var reverseZoom = false
    var thumbSpaces = false
    var reverseSpaces = false
    var adaptation = WheelSettings()
    init() {}
    private enum CodingKeys:String,CodingKey {
        case enabled, manuallyPaused, wheel, move, reverseMove, reverseWheel, shortcuts, zoomModifiers, zoomStyle, sensitivity, reverseZoom, thumbSpaces, reverseSpaces, adaptation
    }
    init(from decoder:Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
        wheel = try c.decodeIfPresent([String:HeldWheelAction].self,forKey:.wheel) ?? [:]
        move = try c.decodeIfPresent([String:HeldMoveAction].self,forKey:.move) ?? [:]
        reverseMove = try c.decodeIfPresent([String:Bool].self,forKey:.reverseMove) ?? [:]
        reverseWheel = try c.decodeIfPresent([String:Bool].self,forKey:.reverseWheel) ?? [:]
        shortcuts = try c.decodeIfPresent([String:KeyBinding].self,forKey:.shortcuts) ?? [:]
        zoomModifiers = try c.decodeIfPresent(UInt64.self,forKey:.zoomModifiers) ?? 0
        zoomStyle = try c.decodeIfPresent(String.self,forKey:.zoomStyle) ?? "pinch"
        sensitivity = try c.decodeIfPresent(Double.self,forKey:.sensitivity) ?? 1
        reverseZoom = try c.decodeIfPresent(Bool.self,forKey:.reverseZoom) ?? false
        thumbSpaces = try c.decodeIfPresent(Bool.self,forKey:.thumbSpaces) ?? false
        reverseSpaces = try c.decodeIfPresent(Bool.self,forKey:.reverseSpaces) ?? false
        adaptation = try c.decodeIfPresent(WheelSettings.self,forKey:.adaptation) ?? WheelSettings()
        if let paused = try c.decodeIfPresent(Bool.self,forKey:.manuallyPaused) { manuallyPaused = paused }
        else if hasConfiguredRules { enabled = true } // 0.4 could save active rules behind a never-enabled master switch.
        self = sanitized()
    }
    var hasConfiguredRules:Bool { wheel.values.contains { $0 != .none } || move.values.contains { $0 != .none } || zoomModifiers != 0 || thumbSpaces }
    mutating func activateConfiguredRules() { if hasConfiguredRules { enabled = true; manuallyPaused = false } }
    static var screenshot: MouseHabits {
        var result = MouseHabits()
        result.enabled = true; result.wheel = ["2": .horizontal, "3": .zoom]
        result.move = ["4": .pan, "5": .windows]
        result.shortcuts["2"] = .command("D", code: 2, extra: .control)
        result.thumbSpaces = true
        return result
    }
    func sanitized() -> MouseHabits {
        var result = self
        func valid(_ raw: String) -> Bool { Int(raw).map { (2...31).contains($0) } ?? false }
        result.wheel = wheel.filter { valid($0.key) && $0.value != .volume && $0.value != .brightness }; result.move = move.filter { valid($0.key) }
        result.adaptation = adaptation.sanitized()
        result.reverseMove = reverseMove.filter { valid($0.key) }
        result.reverseWheel = reverseWheel.filter { valid($0.key) }
        result.shortcuts = shortcuts.filter { valid($0.key) && $0.value.keyCode <= 255 }
        result.zoomModifiers &= UInt64(NSEvent.ModifierFlags([.command,.option,.control,.shift]).rawValue)
        result.zoomStyle = "pinch"
        result.sensitivity = sensitivity.isFinite ? clamp(sensitivity,0.25,3) : 1
        return result
    }
}

struct Configuration: Codable, Equatable {
    var schemaVersion = 7
    var items = MenuItem.recommended()
    var mouseBindings: [String: String] = ["2": "none", "3": "none", "4": "none"]
    var mouseHabits = MouseHabits()
    var displayTarget = "pointer"
    var ringWheel = RingWheelSettings()
    // Preview has a separate preferences domain and independent scroll schema.
    var smoothScroll = SmoothScrollSettings()
    var brightnessControl = BrightnessSettings()
    var step = 0.04
    var reverseScroll = false
    var appearance = RingAppearance()
    init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items, mouseBindings, mouseHabits, displayTarget, step, reverseScroll, appearance, ringWheel, smoothScroll, brightnessControl
        case slots, shortcutA, shortcutB
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try c.decodeIfPresent([MenuItem].self, forKey: .items) { items = stored }
        else if let old = try c.decodeIfPresent([DialAction].self, forKey: .slots) {
            let a = try c.decodeIfPresent(KeyBinding.self, forKey: .shortcutA)
            let b = try c.decodeIfPresent(KeyBinding.self, forKey: .shortcutB)
            items = old.map { action in
                if action == .shortcutA || action == .shortcutB {
                    let binding = action == .shortcutA ? a : b
                    return MenuItem(.shortcut, name: binding?.name ?? "自定义", shortcut: binding)
                }
                if action == .playPause { return .media() }
                return MenuItem(action)
            }
        }
        mouseBindings = try c.decodeIfPresent([String: String].self, forKey: .mouseBindings) ?? mouseBindings
        mouseHabits = try c.decodeIfPresent(MouseHabits.self, forKey: .mouseHabits) ?? mouseHabits
        for key in ["2", "3", "4"] {
            if let raw = mouseBindings[key], raw == "shortcutA" || raw == "shortcutB" {
                let binding = try c.decodeIfPresent(KeyBinding.self, forKey: raw == "shortcutA" ? .shortcutA : .shortcutB)
                mouseBindings[key] = items.first(where: { $0.shortcut == binding && $0.action == .shortcut }).map { "item:" + $0.id.uuidString } ?? "none"
            }
        }
        displayTarget = try c.decodeIfPresent(String.self, forKey: .displayTarget) ?? displayTarget
        ringWheel = try c.decodeIfPresent(RingWheelSettings.self, forKey: .ringWheel) ?? RingWheelSettings(profile: mouseHabits.adaptation.levelProfile ?? mouseHabits.adaptation.vertical, step: mouseHabits.adaptation.levelStep)
        smoothScroll = (try? c.decode(SmoothScrollSettings.self, forKey: .smoothScroll)) ?? smoothScroll
        brightnessControl = try c.decodeIfPresent(BrightnessSettings.self, forKey: .brightnessControl) ?? brightnessControl
        step = try c.decodeIfPresent(Double.self, forKey: .step) ?? step
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? reverseScroll
        appearance = try c.decodeIfPresent(RingAppearance.self, forKey: .appearance) ?? appearance
        self = sanitized()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(items, forKey: .items)
        try c.encode(mouseBindings, forKey: .mouseBindings); try c.encode(mouseHabits, forKey: .mouseHabits); try c.encode(displayTarget, forKey: .displayTarget)
        try c.encode(smoothScroll, forKey: .smoothScroll); try c.encode(brightnessControl, forKey: .brightnessControl)
        try c.encode(ringWheel, forKey: .ringWheel); try c.encode(step, forKey: .step)
        try c.encode(reverseScroll, forKey: .reverseScroll); try c.encode(appearance, forKey: .appearance)
    }
    func item(at location: ItemLocation) -> MenuItem? {
        guard items.indices.contains(location.root) else { return nil }
        if let child = location.child { return items[location.root].children.indices.contains(child) ? items[location.root].children[child] : nil }
        return items[location.root]
    }
    mutating func update(at location: ItemLocation, _ body: (inout MenuItem) -> Void) {
        guard items.indices.contains(location.root) else { return }
        if let child = location.child {
            guard items[location.root].children.indices.contains(child) else { return }
            body(&items[location.root].children[child])
        } else { body(&items[location.root]) }
    }
    func find(id: UUID) -> MenuItem? {
        for item in items { if item.id == id { return item }; if let child = item.children.first(where: { $0.id == id }) { return child } }
        return nil
    }
    var flattened: [(String, MenuItem)] { items.flatMap { root in [(root.title, root)] + (root.action == .submenu ? root.children.map { (root.title + " / " + $0.title, $0) } : []) } }
    func sanitized() -> Configuration {
        var result = self; result.schemaVersion = 7
        result.mouseHabits = mouseHabits.sanitized()
        result.ringWheel = ringWheel.sanitized()
        result.smoothScroll = smoothScroll.sanitized(); result.brightnessControl = brightnessControl.sanitized()
        result.mouseHabits.adaptation.zoomProfile = mouseHabits.adaptation.zoomProfile ?? (mouseHabits.adaptation.vertical.calibrated ? mouseHabits.adaptation.vertical : nil)
        result.mouseHabits.adaptation.levelProfile = nil
        result.mouseHabits.adaptation.vertical = WheelProfile()
        result.mouseHabits.adaptation.horizontal = WheelProfile()
        result.mouseHabits.zoomModifiers = 0
        result.mouseBindings = mouseBindings.filter { Int($0.key).map { (2...31).contains($0) } ?? false }
        result.items = Array(items.prefix(8))
        while result.items.count < 8 { result.items.append(MenuItem(.none)) }
        var ids = Set<UUID>()
        func clean(_ original: MenuItem, depth: Int) -> MenuItem {
            var item = original
            if ids.contains(item.id) { item.id = UUID() }; ids.insert(item.id)
            item.name = String(item.name.prefix(64))
            if item.action == .shortcutA || item.action == .shortcutB { item.action = .shortcut }
            if item.action == .showRing { item.action = .none }
            if depth > 0 && item.action == .submenu { item.action = .shortcut }
            item.children = depth == 0 ? Array(item.children.prefix(8)).map { clean($0, depth: 1) } : []
            if let data = item.iconPNG, data.count > 100_000 { item.iconPNG = nil }
            if let binding = item.shortcut, binding.keyCode > 255 { item.shortcut = nil }
            return item
        }
        result.items = result.items.map { clean($0, depth: 0) }
        result.step = step.isFinite ? clamp(step, 0.01, 0.1) : 0.04
        result.appearance.scale = appearance.scale.isFinite ? clamp(appearance.scale, 0.8, 1.25) : 1
        result.appearance.hoverDelay = appearance.hoverDelay.isFinite ? clamp(appearance.hoverDelay, 0.06, 0.5) : 0.14
        if NSColor(hex: appearance.accentHex) == nil { result.appearance.accentHex = "#151515" }
        if appearance.theme != "dark" { result.appearance.theme = "light" }
        return result
    }
}

final class SettingsStore: ObservableObject {
    @Published var config: Configuration { didSet { scheduleSave() } }
    private var pendingSave: DispatchWorkItem?
    private let persistent: Bool
    init(persistent: Bool = true) {
        self.persistent = persistent
        if !persistent { config = Configuration(); return }
        if let data = UserDefaults.standard.data(forKey: "configuration"), let stored = try? JSONDecoder().decode(Configuration.self, from: data) {
            config = stored
            if UserDefaults.standard.data(forKey: "configuration-v02-backup") == nil { UserDefaults.standard.set(data, forKey: "configuration-v02-backup") }
        } else { config = Configuration() }
    }
    private func scheduleSave() {
        guard persistent else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }; pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }
    func flush() { guard persistent else { return }; pendingSave?.cancel(); pendingSave = nil; if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "configuration") } }
    func backup() { guard persistent else { return }; if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "configuration-undo") } }
    func undo() { if let data = UserDefaults.standard.data(forKey: "configuration-undo"), let stored = try? JSONDecoder().decode(Configuration.self, from: data) { config = stored } }
    func exportData() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(config) }
    func importData(_ data: Data) throws {
        guard data.count <= 8_000_000 else { throw ControlFailure(message: "配置文件过大") }
        let next = try JSONDecoder().decode(Configuration.self, from: data); backup(); config = next
    }
}
/// Integrates both detented and high-resolution wheels, caps a fast flick, and ignores momentum tails.
/// Coalesces wheel input without losing clamp/reversal order near 0% and 100%.
struct BoundedAdjustment {
    let minimum: Double
    let maximum: Double
    private(set) var offset: Double = 0
    private(set) var lower: Double
    private(set) var upper: Double
    private var deltas: [Double] = []
    init(minimum: Double = 0, maximum: Double = 1) {
        self.minimum = minimum; self.maximum = maximum; lower = minimum; upper = maximum
    }
    mutating func append(_ delta: Double) {
        guard delta.isFinite else { return }
        deltas.append(delta)
        offset += delta
        lower = clamp(lower + delta, minimum, maximum)
        upper = clamp(upper + delta, minimum, maximum)
    }
    func apply(to value: Double) -> Double { clamp(value + offset, lower, upper) }
    func rebased(minimum: Double) -> BoundedAdjustment {
        guard minimum != self.minimum else { return self }
        var result = BoundedAdjustment(minimum: minimum, maximum: maximum)
        for delta in deltas { result.append(delta) }
        return result
    }
}


struct RingGeometry {
    static let size = NSSize(width: 520, height: 520)
    static let center = NSPoint(x: 260, y: 260)
    static let radius: CGFloat = 118
    static let bubbleRadius: CGFloat = 29
    static let innerHitRadius: CGFloat = 28
    static let outerHitRadius: CGFloat = 166
    static func point(_ slot: Int) -> NSPoint {
        let angle = CGFloat.pi / 2 - CGFloat(slot) * .pi / 4
        return NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    static func hit(_ p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y, d = dx * dx + dy * dy
        guard d >= innerHitRadius * innerHitRadius, d <= outerHitRadius * outerHitRadius else { return nil }
        let angle = (.pi / 2 - atan2(dy, dx) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(floor((angle + .pi / 8) / (.pi / 4))) % 8
    }
    static func isClose(_ p: NSPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) < 28 }
    static func childAngle(parent: Int, index: Int, count: Int) -> CGFloat {
        let span = min(2.2, CGFloat(max(0, count - 1)) * 0.44)
        return .pi / 2 - CGFloat(parent) * .pi / 4 + (count <= 1 ? 0 : span / 2 - span * CGFloat(index) / CGFloat(count - 1))
    }
    static func childPoint(parent: Int, index: Int, count: Int) -> NSPoint {
        let a = childAngle(parent: parent, index: index, count: count)
        return NSPoint(x: center.x + cos(a) * 215, y: center.y + sin(a) * 215)
    }
    static func childHit(_ p: NSPoint, parent: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let r = hypot(p.x - center.x, p.y - center.y)
        guard r >= 169, r <= 253 else { return nil }
        let a = atan2(p.y - center.y, p.x - center.x)
        let best = (0..<count).min { lhs, rhs in abs(angleDifference(a, childAngle(parent: parent, index: lhs, count: count))) < abs(angleDifference(a, childAngle(parent: parent, index: rhs, count: count))) }!
        let tolerance: CGFloat = count <= 1 ? 0.22 : min(2.2, CGFloat(count - 1) * 0.44) / CGFloat(count - 1) / 2 + 0.035
        return abs(angleDifference(a, childAngle(parent: parent, index: best, count: count))) <= tolerance ? best : nil
    }
    static func inBridge(_ p: NSPoint, parent: Int, count: Int) -> Bool {
        let r = hypot(p.x - center.x, p.y - center.y)
        let span = min(2.2, CGFloat(max(0, count - 1)) * 0.44)
        return r >= 118 && r <= 254 && abs(angleDifference(atan2(p.y - center.y, p.x - center.x), .pi / 2 - CGFloat(parent) * .pi / 4)) <= max(0.3, span / 2 + 0.15)
    }
    static func angleDifference(_ a: CGFloat, _ b: CGFloat) -> CGFloat { atan2(sin(a - b), cos(a - b)) }
    static func frame(near p: NSPoint, screen: NSRect, scale: Double = 1) -> NSRect {
        let s = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: max(screen.minX + 8, min(p.x - s.width / 2, screen.maxX - s.width - 8)), y: max(screen.minY + 8, min(p.y - s.height / 2, screen.maxY - s.height - 8)), width: s.width, height: s.height)
    }
}

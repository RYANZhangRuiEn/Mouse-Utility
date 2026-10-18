import AppKit

struct BrightnessSettings: Codable, Equatable {
    var extendedRange = true
    var hardwareBoundary = 0.5
    func sanitized() -> Self { Self(extendedRange: extendedRange, hardwareBoundary: hardwareBoundary.isFinite ? clamp(hardwareBoundary, 0.2, 0.8) : 0.5) }
    func components(_ level: Double) -> (hardware: Double, color: Double) {
        let value = clamp(level), boundary = sanitized().hardwareBoundary
        guard extendedRange else { return (value, 1) }
        return value <= boundary ? (0, value / boundary) : ((value - boundary) / (1 - boundary), 1)
    }
    func combined(hardware: Double, color: Double) -> Double {
        guard extendedRange else { return clamp(hardware) }
        let boundary = sanitized().hardwareBoundary
        return color < 0.99999 ? clamp(color) * boundary : boundary + clamp(hardware) * (1 - boundary)
    }
}

struct ColorRamp: Codable {
    var red: [Float], green: [Float], blue: [Float]
    static func read(_ id: CGDirectDisplayID) throws -> Self {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity >= 2, capacity <= 65536 else { throw ControlFailure(message: "此屏幕没有可用的色彩表") }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r, count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count >= 2 else { throw ControlFailure(message: "无法读取屏幕色彩表") }
        return Self(red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
    }
    func scaled(_ value: Double) -> Self {
        let f = Float(clamp(value))
        return Self(red: red.map { $0 * f }, green: green.map { $0 * f }, blue: blue.map { $0 * f })
    }
    func apply(_ id: CGDirectDisplayID) throws {
        guard red.count == green.count, red.count == blue.count, red.count >= 2,
              CGSetDisplayTransferByTable(id, UInt32(red.count), red, green, blue) == .success else { throw ControlFailure(message: "色彩表调节未被系统接受") }
    }
    func differs(from other: Self, tolerance: Float = 0.004) -> Bool {
        guard red.count == other.red.count, green.count == other.green.count, blue.count == other.blue.count else { return true }
        return zip(red + green + blue, other.red + other.green + other.blue).contains { abs($0 - $1) > tolerance }
    }
    var maximum: Float { (red + green + blue).max() ?? 0 }
}

/// Serial display-queue ownership. Baselines are retained, never multiplied cumulatively.
final class DisplayColorTables {
    private struct Owned { var baseline: ColorRamp; var applied: ColorRamp; var factor: Double }
    private var owned: [CGDirectDisplayID: Owned] = [:]
    func factor(_ id: CGDirectDisplayID) -> Double { owned[id]?.factor ?? 1 }
    func set(_ factor: Double, id: CGDirectDisplayID) throws {
        if factor >= 0.99999, owned[id] == nil { return }
        var state: Owned
        if let existing = owned[id] { state = existing }
        else { let baseline = try ColorRamp.read(id); state = Owned(baseline: baseline, applied: baseline, factor: 1) }
        let current = try ColorRamp.read(id)
        guard !current.differs(from: state.applied) else { throw ControlFailure(message: "另一个程序正在调整屏幕色彩；请关闭其调暗功能或使用 BetterDisplay 协同") }
        let next = state.baseline.scaled(factor)
        try next.apply(id)
        let readback = try ColorRamp.read(id)
        guard !readback.differs(from: next) else { try? state.baseline.apply(id); throw ControlFailure(message: "系统未保留色彩表，请检查 HDR 或其他显示工具") }
        state.applied = next; state.factor = clamp(factor); owned[id] = state
        if factor >= 0.99999 { owned.removeValue(forKey: id) }
    }
    func restoreAll(blackOnly: Bool = false) {
        for (id, state) in owned where (!blackOnly || state.factor <= 0.02) && CGDisplayIsOnline(id) != 0 {
            if let current = try? ColorRamp.read(id), !current.differs(from: state.applied) { try? state.baseline.apply(id) }
        }
        if blackOnly { owned = owned.filter { $0.value.factor > 0.02 } } else { owned.removeAll() }
    }
}

/// BetterDisplay's documented notification protocol (MIT CLI reference).
/// It is optional: the app performs its own DDC + color-table control when BD is absent.
final class BetterDisplayBridge {
    struct Request: Codable { let uuid: String; let commands: [String]; let parameters: [String: String?] }
    struct Response: Codable { let uuid: String?; let result: Bool?; let payload: String? }
    private final class Pending {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
    }
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var observer: NSObjectProtocol?
    init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("com.betterdisplay.BetterDisplay.response"), object: nil, queue: .main) { [weak self] notification in
            guard let self, let raw = notification.object as? String, let response = try? JSONDecoder().decode(Response.self, from: Data(raw.utf8)), let uuid = response.uuid else { return }
            self.lock.lock(); let item = self.pending[uuid]
            if response.result == true { item?.result = .success(response.payload ?? "") }
            else { item?.result = .failure(ControlFailure(message: response.payload ?? "BetterDisplay 未接受调节")) }
            self.lock.unlock(); item?.semaphore.signal()
        }
    }
    static var running: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "pro.betterdisplay.BetterDisplay").contains { !$0.isTerminated }
    }
    /// Must be called on a worker queue, leaving main free to deliver the response.
    func send(_ commands: [String], displayID: CGDirectDisplayID, feature: String, value: Double? = nil) throws -> String {
        precondition(!Thread.isMainThread)
        let uuid = UUID().uuidString, item = Pending()
        var params: [String: String?] = ["displayID": String(displayID)]
        if let value { params[feature] = String(format: "%.6f", value) } else { params[feature] = .some(nil) }
        let data = try JSONEncoder().encode(Request(uuid: uuid, commands: commands, parameters: params))
        lock.lock(); pending[uuid] = item; lock.unlock()
        defer { lock.lock(); pending.removeValue(forKey: uuid); lock.unlock() }
        DistributedNotificationCenter.default().postNotificationName(.init("com.betterdisplay.BetterDisplay.request"), object: String(decoding: data, as: UTF8.self), userInfo: nil, deliverImmediately: true)
        guard item.semaphore.wait(timeout: .now() + 1.5) == .success else { throw ControlFailure(message: "BetterDisplay 无响应，请检查其集成设置") }
        lock.lock(); let result = item.result; lock.unlock()
        return try result?.get() ?? ""
    }
    func read(_ id: CGDirectDisplayID, feature: String = "combinedBrightness") throws -> Double {
        let text = try send(["get"], displayID: id, feature: feature)
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, (0...1).contains(number) else { throw ControlFailure(message: "BetterDisplay 返回的亮度无效") }
        return number
    }
    func set(_ value: Double, id: CGDirectDisplayID, feature: String = "combinedBrightness") throws -> Double {
        _ = try send(["set"], displayID: id, feature: feature, value: clamp(value))
        return try read(id, feature: feature)
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
}

protocol BrightnessIO: AnyObject {
    func read(display: HardwareDisplay, settings: BrightnessSettings) throws -> ControlValue
    func write(display: HardwareDisplay, value: Double, settings: BrightnessSettings) throws -> ControlValue
    func restoreDimming(blackOnly: Bool)
}

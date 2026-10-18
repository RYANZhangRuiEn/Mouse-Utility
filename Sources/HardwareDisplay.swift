import AppKit
import IOKit
import Darwin

struct HardwareDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    var uuid: String { CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? String(id) }
    var builtIn: Bool { CGDisplayIsBuiltin(id) != 0 }
    static func online() -> [HardwareDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let screen = NSScreen.screens.first { BrightnessController.id($0) == id }
            return HardwareDisplay(id: id, name: screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "内建显示屏" : "外接显示屏 \(id)"))
        }
    }
}

/// DDC/CI over the Apple Silicon display transport. No gamma or overlay fallback.
/// Packet format and transport signatures checked against waydabber's MIT projects.
final class HardwareDDC {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private var create: Create?, read: Transfer?, write: Transfer?
    init() {
        if let library {
            if let p = dlsym(library, "IOAVServiceCreateWithService") { create = unsafeBitCast(p, to: Create.self) }
            if let p = dlsym(library, "IOAVServiceReadI2C") { read = unsafeBitCast(p, to: Transfer.self) }
            if let p = dlsym(library, "IOAVServiceWriteI2C") { write = unsafeBitCast(p, to: Transfer.self) }
        }
    }
    private func connection(_ id: CGDirectDisplayID) -> CFTypeRef? {
        guard CGDisplayIsBuiltin(id) == 0, let create else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault); defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var product: [String: Any] = [:], candidates: [(CFTypeRef, Int)] = []
        while true {
            let entry = IOIteratorNext(iterator); if entry == 0 { break }; defer { IOObjectRelease(entry) }
            var buffer = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(entry, &buffer)
            let name = String(cString: buffer)
            if name == "IOMobileFramebufferShim" || name == "AppleCLCD2" {
                let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, nil, 0)?.takeRetainedValue() as? [String:Any]
                product = attrs?["ProductAttributes"] as? [String:Any] ?? [:]
            }
            guard name == "DCPAVServiceProxy", IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String == "External", let service = create(nil, entry)?.takeRetainedValue() else { continue }
            let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value
            let model = (product["ProductID"] as? NSNumber)?.uint32Value
            let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value
            var score = 0
            if vendor == CGDisplayVendorNumber(id), model == CGDisplayModelNumber(id) { score = 3 }
            if let serial, serial != 0, serial == CGDisplaySerialNumber(id) { score += 5 }
            candidates.append((service, score))
        }
        let sorted = candidates.sorted { $0.1 > $1.1 }
        if let best = sorted.first, best.1 > 0, sorted.count == 1 || best.1 > sorted[1].1 { return best.0 }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32), displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &displayIDs, &displayCount) == .success else { return nil }
        let externalCount = displayIDs.prefix(Int(displayCount)).filter { CGDisplayIsBuiltin($0) == 0 }.count
        return externalCount == 1 && candidates.count == 1 ? candidates[0].0 : nil
    }
    private func send(_ service: CFTypeRef, _ packet: [UInt8]) -> Bool {
        guard let write else { return false }; var packet = packet; let count = UInt32(packet.count)
        return packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, count) == 0 }
    }
    func value(id: CGDirectDisplayID) -> (current: UInt16, maximum: UInt16)? {
        guard let service = connection(id), let read else { return nil }
        for _ in 0..<2 {
            // Get VCP 0x10 (luminance). The transport prepends the data address.
            guard send(service, [0x82, 0x01, 0x10, 0x6e ^ 0x82 ^ 0x01 ^ 0x10]) else { continue }
            usleep(50000)
            var reply = [UInt8](repeating: 0, count: 11)
            let result = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, 11) }
            guard result == 0, reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10, reply.reduce(UInt8(0x50), ^) == 0 else { continue }
            let maximum = UInt16(reply[6]) * 256 + UInt16(reply[7]), current = UInt16(reply[8]) * 256 + UInt16(reply[9])
            if maximum > 0, current <= maximum { return (current, maximum) }
        }
        return nil
    }
    func set(id: CGDirectDisplayID, fraction: Double) throws {
        guard let state = value(id: id), let service = connection(id) else { throw ControlFailure(message: "此连接未提供硬件亮度，请检查显示器 DDC/CI 设置及连接线") }
        let value = UInt16((clamp(fraction) * Double(state.maximum)).rounded())
        var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 255)]
        packet.append(packet.reduce(UInt8(0x6e ^ 0x51), ^))
        guard send(service, packet) else { throw ControlFailure(message: "显示器未接受亮度设置") }
        usleep(50000)
    }
    deinit { if let library { dlclose(library) } }
}

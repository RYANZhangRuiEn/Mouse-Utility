// MouseRing's protocol adapter. No external driver or scrolling implementation is embedded.
// Packet facts: Logitech HID++ 2.0, HiRes Wheel 0x2121; OpenLogi's 0x19B0 documentation.
import Foundation

struct RingHapticSettings:Codable,Equatable {
    var enabled = true
    var intensity = 50
    func sanitized() -> Self { .init(enabled:enabled,intensity:max(0,min(100,intensity))) }
}
enum MasterWheelMode:String,Codable,CaseIterable {
    case ratchet, freeSpin
    var title:String { self == .ratchet ? "棘齿挡":"无极挡" }
}
extension Configuration {
    var needsSmoothListening:Bool { smoothScroll.needsListening || freeWheelSmoothScroll.needsListening }
    func scrolling(for mode:MasterWheelMode) -> SmoothScrollSettings { mode == .ratchet ? smoothScroll:freeWheelSmoothScroll }
    mutating func setScrolling(_ settings:SmoothScrollSettings,for mode:MasterWheelMode) {
        if mode == .ratchet { smoothScroll = settings } else { freeWheelSmoothScroll = settings }
    }
}

struct HIDPPPacket {
    var slot:UInt8
    var feature:UInt8
    var operation:UInt8
    var client:UInt8
    var payload:[UInt8]
    init(slot:UInt8,feature:UInt8,operation:UInt8,client:UInt8,payload:[UInt8] = []) {
        self.slot = slot; self.feature = feature; self.operation = operation; self.client = client; self.payload = payload
    }
    init?(bytes:[UInt8]) {
        guard let id = bytes.first,id == 0x10 || id == 0x11,bytes.count == (id == 0x10 ? 7:20) else { return nil }
        slot = bytes[1]; feature = bytes[2]; operation = bytes[3]>>4; client = bytes[3]&15
        payload = Array(bytes.dropFirst(4))
    }
    func bytes(short:Bool = false) -> [UInt8] {
        let size = short && payload.count<=3 ? 7:20
        var result = [UInt8](repeating:0,count:size)
        result[0] = size == 7 ? 0x10:0x11; result[1] = slot; result[2] = feature
        result[3] = (operation&15)<<4 | (client&15)
        for (index,value) in payload.prefix(size-4).enumerated() { result[index+4] = value }
        return result
    }
    static func normalized(_ bytes:[UInt8],reportID:UInt32) -> [UInt8] {
        if bytes.first == 0x10 || bytes.first == 0x11 { return bytes }
        guard reportID == 0x10 || reportID == 0x11 else { return [] }
        return [UInt8(reportID)]+bytes
    }
    func matches(_ request:HIDPPPacket) -> Bool {
        slot == request.slot && feature == request.feature && operation == request.operation && client == request.client
    }
    func isError(for request:HIDPPPacket) -> Bool {
        (feature == 0xFF || feature == 0x8F) && slot == request.slot && payload.count>=2 &&
        ((operation<<4)|client) == request.feature && payload[0] == ((request.operation<<4)|request.client)
    }
}

enum MouseDeviceFeature {
    static let haptic:UInt16 = 0x19B0
    static let wheel:UInt16 = 0x2121
    static func identifier(_ id:UInt16) -> [UInt8] { [UInt8(id>>8),UInt8(id&255),0] }
    static func index(_ payload:[UInt8]?) -> UInt8? { payload.flatMap { $0.first }.flatMap { $0 == 0 ? nil:$0 } }
    static func wheelState(_ payload:[UInt8]) -> MasterWheelMode? {
        guard let state = payload.first,state<=1 else { return nil }
        return state == 0 ? .freeSpin:.ratchet
    }
    static func wheelNotification(_ packet:HIDPPPacket,slot:UInt8,index:UInt8) -> MasterWheelMode? {
        guard packet.slot == slot,packet.feature == index,packet.operation == 1,packet.client == 0 else { return nil }
        return wheelState(packet.payload)
    }
    static func waveforms(_ payload:[UInt8]) -> UInt32? {
        guard payload.count>=8 else { return nil }
        return payload[4...7].reduce(UInt32(0)) { ($0<<8)|UInt32($1) }
    }
    static func waveform(confirmation:Bool,mask:UInt32) -> UInt8? {
        // Known firmware pulses: collision on hover, state change on activation.
        let preferences:[UInt8] = confirmation ? [1,4]:[4,1]
        return preferences.first { mask & (UInt32(1)<<UInt32($0)) != 0 }
    }
}
struct DeviceHapticConfiguration:Equatable {
    var enabled:Bool
    var intensity:UInt8
    init(enabled:Bool,intensity:UInt8) { self.enabled = enabled; self.intensity = min(100,intensity) }
    init?(payload:[UInt8]) {
        guard payload.count>=2,payload[0]<=1,payload[1]<=100 else { return nil }
        enabled = payload[0] == 1; intensity = payload[1]
    }
    var payload:[UInt8] { [enabled ? 1:0,intensity,0] }
}

/// A temporary device configuration lease. Readback records firmware's actual strength;
/// restoration never overwrites an intervening change made by another app.
final class DeviceHapticSession {
    typealias Exchange = (UInt8,[UInt8],Bool)->[UInt8]?
    let exchange:Exchange
    var pause:(TimeInterval)->Void = { Thread.sleep(forTimeInterval:$0) }
    private(set) var original:DeviceHapticConfiguration?
    private(set) var applied:DeviceHapticConfiguration?
    private var attempted:DeviceHapticConfiguration?
    init(exchange:@escaping Exchange) { self.exchange = exchange }
    private func read() -> DeviceHapticConfiguration? { exchange(1,[],true).flatMap { DeviceHapticConfiguration(payload:$0) } }
    func pulse(settings:RingHapticSettings,mask:UInt32,confirmation:Bool) -> Bool {
        let settings = settings.sanitized()
        guard settings.enabled,settings.intensity>0 else { return true }
        guard let waveform = MouseDeviceFeature.waveform(confirmation:confirmation,mask:mask),let current = read() else { return false }
        let ownsCurrent = applied.map { current == $0 } ?? (attempted.map { current == $0 } ?? false)
        if original == nil || !ownsCurrent { original = current }
        let wanted = DeviceHapticConfiguration(enabled:true,intensity:UInt8(settings.intensity))
        if current != wanted {
            applied = nil; attempted = wanted
            let acknowledged = exchange(2,wanted.payload,true) != nil
            guard let actual = read(),actual.enabled,actual.intensity>0,(acknowledged || actual != current || actual == wanted) else { _ = restore(); return false }
            applied = actual; attempted = nil // Do not guess hardware's discrete strength levels.
        } else { applied = current; attempted = nil }
        for index in 0..<(confirmation ? 2:1) {
            if index>0 { pause(0.055) }
            guard exchange(4,[waveform,0,0],false) != nil else { return false }
        }
        return true
    }
    @discardableResult func restore() -> Bool {
        guard let original else { return true }
        guard let current = read() else { return false }
        if current == original { clear(); return true }
        guard current == applied || (applied == nil && current == attempted) else { clear(); return true }
        guard exchange(2,original.payload,true) != nil,read() == original else { return false }
        clear(); return true
    }
    private func clear() { original = nil; applied = nil; attempted = nil }
}

// Original MouseRing IOKit transport for documented HID++ packets.
import AppKit
import IOKit.hid

struct HIDEndpoint {
    let device:IOHIDDevice
    let key:Int
    let name:String
    let bluetooth:Bool
    let shortReports:Bool
    init(_ device:IOHIDDevice) {
        self.device = device; key = Int(CFHash(device))
        name = IOHIDDeviceGetProperty(device,kIOHIDProductKey as CFString) as? String ?? "Logitech mouse"
        bluetooth = (IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String ?? "").lowercased().contains("bluetooth")
        let maximum = (IOHIDDeviceGetProperty(device,kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 20
        shortReports = maximum>0 && maximum<20
    }
}
private final class HIDCallbackContext {
    weak var link:HIDPPLink?
    init(_ link:HIDPPLink) { self.link = link }
}
final class HIDPPLink {
    var onAttach:((HIDEndpoint)->Void)?
    var onDetach:((Int)->Void)?
    var onNotification:((Int,HIDPPPacket)->Void)?
    private let inputQueue = DispatchQueue(label:"local.mousering.preview.hid-input",qos:.userInteractive)
    private let transaction = NSLock(), replyLock = NSLock()
    private var manager:IOHIDManager?
    private(set) var isOpen = false
    private var serial = 0
    private final class Awaiting {
        let device:Int, request:HIDPPPacket
        let ready = DispatchSemaphore(value:0)
        var value:[UInt8]?, failed = false
        init(_ device:Int,_ request:HIDPPPacket) { self.device = device; self.request = request }
    }
    private var awaiting:Awaiting?
    @discardableResult func open() -> IOReturn {
        if isOpen { return kIOReturnSuccess }
        if let manager {
            let result = IOHIDManagerOpen(manager,0); isOpen = result == kIOReturnSuccess
            if isOpen,let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> { devices.forEach { onAttach?(HIDEndpoint($0)) } }
            return result
        }
        let created = IOHIDManagerCreate(kCFAllocatorDefault,0)
        manager = created
        let matching:[[String:Any]] = [
            [kIOHIDVendorIDKey:0x046D,kIOHIDProductIDKey:0xB042],
            [kIOHIDVendorIDKey:0x046D,kIOHIDPrimaryUsagePageKey:0xFF00,kIOHIDPrimaryUsageKey:1],
            [kIOHIDVendorIDKey:0x046D,kIOHIDPrimaryUsagePageKey:0xFF43]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(created,matching as CFArray)
        let retained = Unmanaged.passRetained(HIDCallbackContext(self)), pointer = retained.toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(created,{ context,_,_,device in
            guard let context else { return }
            Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue().link?.onAttach?(HIDEndpoint(device))
        },pointer)
        IOHIDManagerRegisterDeviceRemovalCallback(created,{ context,_,_,device in
            guard let context else { return }
            Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue().link?.onDetach?(Int(CFHash(device)))
        },pointer)
        IOHIDManagerRegisterInputReportCallback(created,{ context,_,sender,_,reportID,buffer,length in
            guard let context,let sender else { return }
            let endpoint = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start:buffer,count:length))
            let link = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue().link
            link?.accept(key:Int(CFHash(endpoint)),bytes:HIDPPPacket.normalized(bytes,reportID:reportID))
        },pointer)
        IOHIDManagerSetDispatchQueue(created,inputQueue)
        IOHIDManagerSetCancelHandler(created) { retained.release() }
        let result = IOHIDManagerOpen(created,0)
        isOpen = result == kIOReturnSuccess
        IOHIDManagerActivate(created)
        return result
    }
    private func accept(key:Int,bytes:[UInt8]) {
        guard let packet = HIDPPPacket(bytes:bytes) else { return }
        if packet.client == 0 { onNotification?(key,packet) }
        replyLock.lock()
        if let pending = awaiting,pending.device == key {
            if packet.matches(pending.request) { pending.value = packet.payload; pending.ready.signal() }
            else if packet.isError(for:pending.request) { pending.failed = true; pending.ready.signal() }
        }
        replyLock.unlock()
    }
    // Call only on the feature controller's worker queue. Input replies use a separate queue.
    func exchange(_ endpoint:HIDEndpoint,slot:UInt8,feature:UInt8,operation:UInt8,payload:[UInt8] = [],reply:Bool = true,timeout:TimeInterval = 0.20) -> [UInt8]? {
        transaction.lock(); defer { transaction.unlock() }
        let clients:[UInt8] = [0x0C,0x0E,0x0A,0x08]
        let client = clients[serial%clients.count]; serial += 1
        let packet = HIDPPPacket(slot:slot,feature:feature,operation:operation,client:client,payload:payload)
        let bytes = packet.bytes(short:endpoint.shortReports)
        let waiting = Awaiting(endpoint.key,packet)
        if reply { replyLock.lock(); awaiting = waiting; replyLock.unlock() }
        let result = IOHIDDeviceSetReport(endpoint.device,kIOHIDReportTypeOutput,CFIndex(bytes[0]),bytes,bytes.count)
        if result == kIOReturnSuccess && reply { _ = waiting.ready.wait(timeout:.now()+timeout) }
        replyLock.lock(); if awaiting === waiting { awaiting = nil }; let value = waiting.value,failed = waiting.failed; replyLock.unlock()
        guard result == kIOReturnSuccess else { return nil }
        if !reply { return [] }
        return failed ? nil:value
    }
    func close() {
        replyLock.lock(); awaiting?.failed = true; awaiting?.ready.signal(); awaiting = nil; replyLock.unlock()
        guard let manager else { return }
        IOHIDManagerClose(manager,0); IOHIDManagerCancel(manager)
        self.manager = nil; isOpen = false
    }
    deinit { close() }
}

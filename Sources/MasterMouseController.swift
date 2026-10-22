// MouseRing's feature orchestration. All device I/O stays off the main thread.
import AppKit

final class MasterMouseController {
    private struct Device {
        var endpoint:HIDEndpoint
        var slot:UInt8
        var haptic:UInt8?
        var wheel:[WheelStateReader]
        var waveforms:UInt32
        var session:DeviceHapticSession?
    }
    private let link = HIDPPLink()
    private let queue = DispatchQueue(label:"local.mousering.preview.mouse-features",qos:.userInteractive)
    private var candidates:[Int:HIDEndpoint] = [:]
    private var selected:Device?
    private var polling:DispatchSourceTimer?
    private var settings = RingHapticSettings()
    private var ringActive = false, pendingTest = false, stopped = false
    private var failedModeReads = 0
    private var stopRequested = false // Main-thread lifecycle gate; stopped belongs to the worker.
    private var lastOpenAttempt = -TimeInterval.infinity
    private(set) var status = "未连接 Master 4"
    private(set) var wheelMode:MasterWheelMode?
    var onStatus:((String)->Void)?
    var onWheelMode:((MasterWheelMode?)->Void)?
    init() {
        link.onAttach = { [weak self] endpoint in self?.queue.async { [weak self] in self?.discover(endpoint) } }
        link.onDetach = { [weak self] key in self?.queue.async { [weak self] in
            guard let self,!self.stopped else { return }; self.candidates.removeValue(forKey:key)
            if self.selected?.endpoint.key == key {
                self.selected = nil; self.polling?.cancel(); self.polling = nil
                self.mode(nil); self.message("Master 4 已断开")
                for candidate in self.candidates.values { self.discover(candidate); if self.selected != nil { break } }
            }
        } }
        link.onNotification = { [weak self] key,packet in self?.queue.async { [weak self] in
            guard let self,!self.stopped,let device = self.selected,device.endpoint.key == key,let index = device.wheel.first(where: { $0.kind == .hires })?.index,
                  let mode = MouseDeviceFeature.wheelNotification(packet,slot:device.slot,index:index) else { return }
            self.failedModeReads = 0
            if device.wheel.first?.kind == .enhanced { self.readMode() } else { self.mode(mode) }
        } }
    }
    private func message(_ text:String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.status != text else { return }; self.status = text; self.onStatus?(text)
        }
    }
    private func mode(_ value:MasterWheelMode?) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.wheelMode != value else { return }; self.wheelMode = value; self.onWheelMode?(value)
        }
    }
    func start(userInitiated:Bool = false) {
        guard !stopRequested,!link.isOpen else { return }
        guard userInitiated || CGPreflightListenEventAccess() else { message("需要输入监控权限"); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard userInitiated || now-lastOpenAttempt>=5 else { return }; lastOpenAttempt = now
        let result = link.open()
        if result == 0 {
            message("正在读取 Master 4…")
            queue.asyncAfter(deadline:.now()+4) { [weak self] in
                guard let self,!self.stopped,self.selected == nil else { return }
                self.message("未连接支持的 Master 4")
            }
        }
        else { message("设备访问未就绪 · 请检查输入监控权限") }
    }
    private func feature(_ id:UInt16,on endpoint:HIDEndpoint,slot:UInt8) -> UInt8? {
        MouseDeviceFeature.index(link.exchange(endpoint,slot:slot,feature:0,operation:0,payload:MouseDeviceFeature.identifier(id)))
    }
    private func discover(_ endpoint:HIDEndpoint) {
        guard !stopped else { return }; candidates[endpoint.key] = endpoint
        if let selected {
            if selected.endpoint.key == endpoint.key || selected.endpoint.bluetooth || !endpoint.bluetooth { return }
        }
        for slot:UInt8 in endpoint.bluetooth ? [0xFF]:[1,2,3,4,5,6] {
            let haptic = feature(MouseDeviceFeature.haptic,on:endpoint,slot:slot)
            // A known Master 4 Bluetooth product or a receiver slot advertising haptics.
            guard endpoint.bluetooth || haptic != nil else { continue }
            let wheel = WheelStateReader.Kind.allCases.compactMap { kind -> WheelStateReader? in
                feature(kind.featureID,on:endpoint,slot:slot).map { WheelStateReader(kind:kind,index:$0) }
            }
            guard haptic != nil || !wheel.isEmpty else { continue }
            var mask:UInt32 = 0,session:DeviceHapticSession?
            if let index = haptic {
                mask = link.exchange(endpoint,slot:slot,feature:index,operation:0).flatMap(MouseDeviceFeature.waveforms) ?? 0
                session = DeviceHapticSession { [weak self] operation,payload,reply in
                    self?.link.exchange(endpoint,slot:slot,feature:index,operation:operation,payload:payload,reply:reply)
                }
            }
            if let previous = selected { _ = previous.session?.restore() }
            selected = Device(endpoint:endpoint,slot:slot,haptic:haptic,wheel:wheel,waveforms:mask,session:session)
            message(haptic != nil && mask != 0 ? "Master 4 已连接":"已连接 · 设备未提供震动")
            startPolling()
            if pendingTest { pendingTest = false; trial() }
            return
        }
    }
    private func startPolling() {
        polling?.cancel(); polling = nil; failedModeReads = 0
        guard selected?.wheel.isEmpty == false else { mode(nil); return }
        readMode()
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now()+0.75,repeating:0.75,leeway:.milliseconds(150))
        timer.setEventHandler { [weak self] in self?.readMode() }; timer.resume(); polling = timer
    }
    private func readMode() {
        guard !stopped,let device = selected else { return }
        for reader in device.wheel {
            if let report = link.exchange(device.endpoint,slot:device.slot,feature:reader.index,operation:reader.kind.operation,timeout:0.12),let value = reader.decode(report) {
                failedModeReads = 0; mode(value); return
            }
        }
        failedModeReads += 1; if failedModeReads>=3 { mode(nil) }
    }
    func configure(_ value:RingHapticSettings) {
        queue.async {
            guard !self.stopped else { return }; self.settings = value.sanitized()
            if !self.settings.enabled || self.settings.intensity == 0 { _ = self.selected?.session?.restore() }
        }
    }
    func beginRing() { queue.async { if !self.stopped { self.ringActive = true } } }
    func hover() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        queue.async {
            guard self.ringActive,ProcessInfo.processInfo.systemUptime-timestamp<0.20 else { return }
            self.play(confirmation:false)
        }
    }
    func confirm() { queue.async { if self.ringActive { self.play(confirmation:true) } } }
    private func play(confirmation:Bool) {
        guard !stopped,settings.enabled,settings.intensity>0,let device = selected,let session = device.session else { return }
        if session.pulse(settings:settings,mask:device.waveforms,confirmation:confirmation) {
            if let actual = session.applied { message("Master 4 · 震动强度 \(actual.intensity)%") }
        } else { message("震动暂不可用 · 已保留设备状态") }
    }
    func endRing(completion:(()->Void)? = nil) {
        queue.async {
            self.ringActive = false
            if let session = self.selected?.session,!session.restore() && !session.restore() { self.message("设备恢复待重试") }
            if let completion { DispatchQueue.main.async(execute:completion) }
        }
    }
    func test() { queue.async {
        guard self.selected != nil else {
            self.pendingTest = true
            for candidate in Array(self.candidates.values) { self.discover(candidate); if self.selected != nil { break } }
            return
        }
        self.trial()
    } }
    private func trial() { play(confirmation:false); if !ringActive { _ = selected?.session?.restore() } }
    func stop(completion:(()->Void)? = nil) {
        stopRequested = true
        queue.async {
            self.stopped = true; self.ringActive = false
            self.polling?.cancel(); self.polling = nil
            if let session = self.selected?.session { _ = session.restore() }
            self.selected = nil; self.mode(nil)
            DispatchQueue.main.async { self.link.close(); completion?() }
        }
    }
}

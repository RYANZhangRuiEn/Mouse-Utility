import AppKit
import CoreAudio
import AudioToolbox
import ApplicationServices
import Darwin

struct ControlFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AudioController {
    private var restoreVolume: [AudioDeviceID: Float32] = [:]
    private func device() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { throw ControlFailure(message: "未找到系统声音输出设备") }
        return id
    }
    private func address(_ selector: AudioObjectPropertySelector, _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    private func readFloat(_ id: AudioDeviceID, _ selector: UInt32, _ element: UInt32 = 0) -> Float32? {
        var a = address(selector, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private func writeFloat(_ id: AudioDeviceID, _ selector: UInt32, _ element: UInt32 = 0, _ value: Float32) -> Bool {
        var a = address(selector, element), value = value
        var writable = DarwinBoolean(false)
        guard AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &writable) == noErr, writable.boolValue else { return false }
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }
    private func volume(_ id: AudioDeviceID) -> Float32? {
        if let v = readFloat(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) { return v }
        if let v = readFloat(id, kAudioDevicePropertyVolumeScalar) { return v }
        let channels = [1, 2].compactMap { readFloat(id, kAudioDevicePropertyVolumeScalar, UInt32($0)) }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
    }
    private func setVolume(_ id: AudioDeviceID, _ value: Float32) throws {
        if writeFloat(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, 0, value) { return }
        if writeFloat(id, kAudioDevicePropertyVolumeScalar, 0, value) { return }
        // Keep stereo balance when only individual channels are exposed.
        let old = volume(id) ?? 0
        var success = false
        for element: UInt32 in [1, 2] {
            if let current = readFloat(id, kAudioDevicePropertyVolumeScalar, element) {
                let next = old > 0.001 ? min(1, max(0, current * value / old)) : value
                success = writeFloat(id, kAudioDevicePropertyVolumeScalar, element, next) || success
            }
        }
        guard success else { throw ControlFailure(message: "此输出设备不支持系统音量调节") }
    }
    private func muteValue(_ id: AudioDeviceID) -> Bool? {
        var a = address(kAudioDevicePropertyMute), value: UInt32 = 0, size: UInt32 = 4
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    private func setMute(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute), value: UInt32 = muted ? 1 : 0
        var writable = DarwinBoolean(false)
        guard AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &writable) == noErr, writable.boolValue else { return false }
        return AudioObjectSetPropertyData(id, &a, 0, nil, 4, &value) == noErr
    }
    func snapshot() throws -> (value: Double, muted: Bool, name: String) {
        let id = try device()
        guard let value = volume(id) else { throw ControlFailure(message: "此输出设备不提供可调系统音量") }
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name)
        let deviceName = status == noErr ? (name?.takeRetainedValue() as String? ?? "系统输出") : "系统输出"
        return (Double(value), muteValue(id) ?? (value == 0), deviceName)
    }
    func adjust(by delta: Double) throws -> Double { try adjust(transform: { clamp($0 + delta) }) }
    func adjust(transform: (Double) -> Double) throws -> Double {
        let id = try device()
        guard let current = volume(id) else { throw ControlFailure(message: "此输出设备不支持系统音量调节") }
        let value = Float32(clamp(transform(Double(current))))
        try setVolume(id, value)
        if value > 0 { _ = setMute(id, false) }
        return Double(volume(id) ?? value)
    }
    func toggleMute() throws -> Bool {
        let id = try device()
        if let muted = muteValue(id), setMute(id, !muted) { return !muted }
        guard let value = volume(id) else { throw ControlFailure(message: "此输出设备不支持静音控制") }
        if value > 0 { restoreVolume[id] = value; try setVolume(id, 0); return true }
        try setVolume(id, restoreVolume[id] ?? 0.3)
        return false
    }
}

final class BrightnessController: BrightnessIO {
    typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private var getBrightness: GetBrightness?, setBrightness: SetBrightness?
    private let ddc = HardwareDDC()
    private let colorTables = DisplayColorTables()
    private let bridge = BetterDisplayBridge()
    private var bridgeManaged: [CGDirectDisplayID: Double] = [:]
    private var lastHardwareWrite: [CGDirectDisplayID: Double] = [:]
    init() {
        if let framework {
            if let f = dlsym(framework, "DisplayServicesGetBrightness") { getBrightness = unsafeBitCast(f, to: GetBrightness.self) }
            if let f = dlsym(framework, "DisplayServicesSetBrightness") { setBrightness = unsafeBitCast(f, to: SetBrightness.self) }
        }
    }
    static func id(_ screen: NSScreen) -> CGDirectDisplayID { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    static func uuid(_ screen: NSScreen) -> String { HardwareDisplay(id: id(screen), name: screen.localizedName).uuid }
    func target(_ selection: String, anchor: NSPoint) -> HardwareDisplay? {
        let displays = HardwareDisplay.online()
        if selection == "pointer", let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main { return displays.first { $0.id == Self.id(screen) } }
        if selection == "builtin" { return displays.first { $0.builtIn } }
        return displays.first { $0.uuid == selection }
    }
    func nativeValue(id: CGDirectDisplayID) -> Double? {
        if CGDisplayIsBuiltin(id) == 0, let state = ddc.value(id: id) { return Double(state.current) / Double(state.maximum) }
        var value: Float = 0
        guard let getBrightness, getBrightness(id, &value) == 0, value.isFinite else { return nil }
        return clamp(Double(value))
    }
    func setNativeValue(id: CGDirectDisplayID, value: Double) throws {
        if CGDisplayIsBuiltin(id) == 0 { try ddc.set(id: id, fraction: value); return }
        guard let setBrightness, setBrightness(id, Float(clamp(value))) == 0 else { throw ControlFailure(message: "此屏幕未提供硬件亮度控制") }
    }
    func read(display: HardwareDisplay, settings: BrightnessSettings) throws -> ControlValue {
        if BetterDisplayBridge.running {
            colorTables.restoreAll(); lastHardwareWrite.removeAll()
            return ControlValue(value: try bridge.read(display.id, feature: settings.extendedRange ? "combinedBrightness" : "hardwareBrightness"), name: display.name, backend: "BetterDisplay 协同")
        }
        guard let hardware = nativeValue(id: display.id) else { throw ControlFailure(message: "无法读取屏幕硬件亮度") }
        lastHardwareWrite[display.id] = hardware
        return ControlValue(value: settings.combined(hardware: hardware, color: colorTables.factor(display.id)), name: display.name, backend: settings.extendedRange ? "硬件＋色彩表" : "硬件")
    }
    func write(display: HardwareDisplay, value: Double, settings: BrightnessSettings) throws -> ControlValue {
        if BetterDisplayBridge.running {
            colorTables.restoreAll(); lastHardwareWrite.removeAll()
            let actual = try bridge.set(value, id: display.id, feature: settings.extendedRange ? "combinedBrightness" : "hardwareBrightness")
            if settings.extendedRange { bridgeManaged[display.id] = clamp(value) }
            return ControlValue(value: actual, name: display.name, backend: "BetterDisplay 协同")
        }
        let component = settings.components(value)
        if lastHardwareWrite[display.id].map({abs($0 - component.hardware) > 0.004}) ?? true {
            try setNativeValue(id: display.id, value: component.hardware)
            guard let actual = nativeValue(id: display.id) else { throw ControlFailure(message: "无法确认屏幕硬件亮度") }
            lastHardwareWrite[display.id] = actual
        }
        try colorTables.set(component.color, id: display.id)
        return ControlValue(value: settings.combined(hardware: lastHardwareWrite[display.id] ?? component.hardware, color: component.color), name: display.name, backend: settings.extendedRange ? "硬件＋色彩表" : "硬件")
    }
    func restoreDimming(blackOnly: Bool = false) {
        colorTables.restoreAll(blackOnly: blackOnly); lastHardwareWrite.removeAll()
        if BetterDisplayBridge.running {
            for (id, value) in bridgeManaged where (!blackOnly || value <= 0.02) && CGDisplayIsOnline(id) != 0 { _ = try? bridge.send(["set"], displayID: id, feature: "softwareBrightness", value: 1) }
        }
        if blackOnly { bridgeManaged = bridgeManaged.filter { $0.value > 0.02 } } else { bridgeManaged.removeAll() }
    }
    func snapshot(screen: NSScreen) throws -> (value: Double, software: Bool) {
        guard let value = nativeValue(id: Self.id(screen)) else { throw ControlFailure(message: "无法读取硬件亮度，请检查 DDC/CI 及连接线") }
        return (value, false)
    }
    deinit { if let framework { dlclose(framework) } }
}

enum InputSender {
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    static func media(_ code: Int) throws {
        guard trusted else { throw ControlFailure(message: "请在设置中授权辅助功能，再使用媒体控制") }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)?.cgEvent else { throw ControlFailure(message: "无法创建媒体控制事件") }
            event.post(tap: .cghidEventTap)
        }
    }
    private static let keyboardQueue = DispatchQueue(label:"local.mousering.preview.keyboard")
    static func keyboardEvents(_ binding:KeyBinding) throws -> (CGEvent,CGEvent) {
        // Dock's Mission Control hotkeys require a HID state source and the arrow's function flag.
        let source = CGEventSource(stateID:.hidSystemState)
        var flags = CGEventFlags(rawValue:binding.modifiers)
        if (123...126).contains(binding.keyCode) { flags.insert(.maskSecondaryFn) }
        guard let down = CGEvent(keyboardEventSource:source,virtualKey:binding.keyCode,keyDown:true),
              let up = CGEvent(keyboardEventSource:source,virtualKey:binding.keyCode,keyDown:false) else { throw ControlFailure(message:"无法创建快捷键事件") }
        down.flags = flags; up.flags = flags
        down.setIntegerValueField(.keyboardEventAutorepeat,value:0)
        up.setIntegerValueField(.keyboardEventAutorepeat,value:0)
        return (down,up)
    }
    static func shortcut(_ binding: KeyBinding) throws {
        guard trusted else { throw ControlFailure(message: "请在设置中授权辅助功能，再发送快捷键") }
        let pair = try keyboardEvents(binding)
        keyboardQueue.async {
            pair.0.post(tap:.cghidEventTap)
            Thread.sleep(forTimeInterval:0.012)
            pair.1.post(tap:.cghidEventTap)
        }
    }
}

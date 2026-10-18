import AppKit
import Carbon

final class TestShield: ShortcutRecordingShield {
    var failureReason = "测试拒绝"
    var allowed = true, active = false
    var starts = 0, stops = 0
    var receive: ((NSEvent) -> Void)?, interrupted: (() -> Void)?
    func start(receive: @escaping (NSEvent) -> Void, interrupted: @escaping () -> Void) -> Bool {
        starts += 1
        guard allowed else { return false }
        active = true; self.receive = receive; self.interrupted = interrupted; return true
    }
    func stop() { if active { stops += 1 }; active = false; receive = nil; interrupted = nil }
}
final class MenuTarget: NSObject {
    var executions = 0
    @objc func execute(_ sender: Any?) { executions += 1 }
}
let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let shield = TestShield(), recorder = RecorderButton(shield: shield)
window.contentView!.addSubview(recorder)
let target = MenuTarget(), menu = NSMenu(), menuItem = NSMenuItem(), commands = NSMenu()
menu.addItem(menuItem); menuItem.submenu = commands
for key in ["q","w",",","c","v"] {
    let command = NSMenuItem(title:key,action:#selector(MenuTarget.execute(_:)),keyEquivalent:key)
    command.target = target; commands.addItem(command)
}
app.mainMenu = menu
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ reason: String) {
    guard value() else { fputs("FAIL: \(reason)\n",stderr); exit(1) }; checks += 1
}
func event(_ type:NSEvent.EventType, _ code:UInt16, _ flags:NSEvent.ModifierFlags = [], _ label:String = "", repeatKey:Bool = false) -> NSEvent {
    NSEvent.keyEvent(with:type, location:.zero, modifierFlags:flags, timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber, context:nil, characters:label, charactersIgnoringModifiers:label,
                    isARepeat:repeatKey, keyCode:code)!
}
var recorded:[KeyBinding] = []
recorder.onRecord = { recorded.append($0) }
for (code,label,flags) : (UInt16,String,NSEvent.ModifierFlags) in [(12,"q",.command),(13,"w",.command),(43,",",.command),(8,"c",.command),(9,"v",.command),(49," ",.command),(48,"\t",.command),(21,"4",[.command,.shift]),(49," ",[.command,.option,.control])] {
    let previous = recorded.count, stops = shield.stops
    recorder.begin(); check(RecorderButton.isCapturing && shield.active,"recording owns shield")
    app.sendEvent(event(.keyDown,code,flags,label))
    check(recorded.count == previous && recorder.recording,"not committed on key down")
    app.sendEvent(event(.keyDown,code,flags,label,repeatKey:true))
    app.sendEvent(event(.keyUp,code,flags,label))
    check(recorder.recording && shield.active,"held modifiers remain protected")
    app.sendEvent(event(.flagsChanged,55))
    check(!recorder.recording && !shield.active && shield.stops == stops+1,"release restores shield exactly once")
    check(recorded.count == previous+1 && recorded.last?.keyCode == code && recorded.last?.modifiers == UInt64(flags.rawValue),"recorded exact combination once")
}
check(target.executions == 0,"app menu shortcuts never execute during capture")
let previous = recorder.binding, count = recorded.count
recorder.begin(); app.sendEvent(event(.keyDown,53))
check(recorder.recording,"Esc stays protected until key up")
app.sendEvent(event(.keyUp,53))
check(!recorder.recording && recorder.binding == previous && recorded.count == count,"Esc preserves prior shortcut")
recorder.begin(); app.sendEvent(event(.keyDown,0,[],"a"))
app.sendEvent(event(.flagsChanged,55))
check(recorder.recording,"modifier release alone cannot leak a held primary key")
app.sendEvent(event(.keyUp,0,[],"a"))
check(recorded.last?.keyCode == 0 && !recorder.recording,"bare key completes on release")
recorder.begin(); NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)
check(!recorder.recording && !shield.active,"window deactivation restores keyboard")
recorder.begin(); NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:app)
check(!recorder.recording && !shield.active,"app deactivation restores keyboard")
recorder.begin(); NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:window)
check(!recorder.recording && !shield.active,"window close restores keyboard")
recorder.begin(); window.makeFirstResponder(nil)
check(!recorder.recording && !shield.active,"changing field cancels capture")
recorder.begin(); shield.interrupted?()
check(!recorder.recording && !shield.active && recorder.title.contains("中断"),"tap interruption fails closed")
shield.allowed = false; recorder.begin()
check(!recorder.recording && !RecorderButton.isCapturing && recorder.title == shield.failureReason,"failed protection cannot record unprotected keys")
shield.allowed = true
let anotherShield = TestShield(), another = RecorderButton(shield:anotherShield)
window.contentView!.addSubview(another)
recorder.begin(); another.begin()
check(!recorder.recording && another.recording && !shield.active,"only one recorder can own capture")
another.cancelRecording(); check(!RecorderButton.isCapturing,"cancel clears global capture guard")
for (_,name) in DialIcons.additions {
    let image = DialIcons.image(named:name)
    check(image != nil && image!.isTemplate && !image!.representations.isEmpty,"custom clipboard icon renders")
}

print("PASS: \(checks) shortcut recording and icon checks")

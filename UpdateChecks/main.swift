import AppKit

let app = NSApplication.shared
var checks = 0
func check(_ condition:@autoclosure ()->Bool,_ message:String) { guard condition() else { fatalError(message) }; checks += 1 }
func near(_ a:Double,_ b:Double)->Bool { abs(a-b)<0.000001 }
func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
func press(_ button:NSButton) { _ = app.sendAction(button.action!,to:button.target,from:button) }
func wheel(_ y:Int32 = 1,_ x:Int32 = 0,pid:pid_t = 321)->CGEvent {
    let e = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:2,wheel1:y,wheel2:x,wheel3:0)!
    e.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid)); return e
}
func finish(_ engine:SmoothScrollEngine) { engine.tick(at:ProcessInfo.processInfo.systemUptime+1) }
// Physical detents are collected before interpolation. Three reports form each slow detent.
for count in [1,4,10,17,40,100] {
    var learner = AutomaticWheelLearning(); learner.begin(count:count)
    for (round,sign) in [1.0,-1.0].enumerated() {
        for i in 0..<count {
            let t = Double(round*(count+1))+Double(i)*0.2
            learner.record(WheelSample(values:["raw":999],momentum:true),time:t-0.01)
            for fragment in 0..<3 { learner.record(WheelSample(values:["raw":sign*2,"line":sign]),time:t+Double(fragment)*0.01) }
            learner.idle(time:t+0.12)
            check(learner.progress == (i == count-1 && round == 0 ? 0:i+1),"automatic cell count \(count)/\(round)/\(i)")
        }
        if round == 0 {
            check(learner.stage == .down,"up round automatically changes direction")
            learner.record(WheelSample(values:["raw":6]),time:Double(count)+0.1)
            learner.idle(time:Double(count)+0.3)
            check(learner.progress == 0,"upward overshoot cannot count downward cells")
        }
    }
    check(learner.stage == .done && learner.profile?.calibrated == true,"all allowed lengths can finish automatically")
    check(learner.profile?.upNotches == count && learner.profile?.downNotches == count && learner.profile?.learnedAt != nil,"saved learning includes both direction counts and date")
    check(near(learner.profile?.units["raw"] ?? 0,6),"split reports conserve physical unit")
}
var bounded = AutomaticWheelLearning(); bounded.begin(count:0); check(bounded.target == 1,"minimum one cell"); bounded.begin(count:1000); check(bounded.target == 100,"maximum 100 cells")
let learned = WheelProfile(units:["raw":6],samples:20,source:"raw",learnedAt:Date(),upNotches:10,downNotches:10)
var configuration = Configuration(); configuration.ringWheel.profile = learned
configuration.mouseHabits.adaptation.vertical = learned; configuration.mouseHabits.adaptation.horizontal = learned; configuration.mouseHabits.adaptation.zoomProfile = learned
configuration.mouseHabits.adaptation.appZoom["app.test"] = AppZoomCalibration(gain:1,before:100,after:110,physicalSteps:1,step:0.1,verified:true)
var reset = configuration; reset.resetWheelLearning(.zoom)
reset = try JSONDecoder().decode(Configuration.self,from:JSONEncoder().encode(reset))
check(reset.ringWheel.profile == learned && reset.mouseHabits.adaptation.zoomProfile == nil && !reset.mouseHabits.adaptation.vertical.calibrated && reset.mouseHabits.adaptation.appZoom.isEmpty,"zoom reset cannot revive a legacy profile or erase ring learning")
reset = configuration; reset.resetWheelLearning(.levels)
check(!reset.ringWheel.profile.calibrated && reset.mouseHabits.adaptation.zoomProfile == learned && reset.mouseHabits.adaptation.appZoom.count == 1,"level reset preserves zoom learning and app fits")
// Migration retains public units, identity and all existing profile data.
var oldObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(configuration)) as! [String:Any]
oldObject.removeValue(forKey:"freeWheelSmoothScroll"); oldObject.removeValue(forKey:"learningCount"); oldObject.removeValue(forKey:"ringHaptics")
let migrated = try JSONDecoder().decode(Configuration.self,from:JSONSerialization.data(withJSONObject:oldObject))
check(migrated.freeWheelSmoothScroll == migrated.smoothScroll && migrated.learningCount == 10,"old public settings initially seed both modes")
check(migrated.ringWheel.profile == learned,"existing learned data survives migration")
var split = migrated; split.freeWheelSmoothScroll.global.pixelsPerStep = 81; split.freeWheelSmoothScroll.global.reverseVertical = true
check(split.smoothScroll.global.pixelsPerStep == 36 && !split.smoothScroll.global.reverseVertical,"wheel modes save independently")
var profile = SmoothScrollSettings(); profile.enabled = false; profile.global.reverseVertical = true
check(profile.needsListening && profile.tuning(for:"any")?.smoothVertical == false && profile.tuning(for:"any")?.reverseVertical == true,"reverse remains usable with global smoothing off")
profile.applications = [ScrollApplication(bundleID:"reader",name:"Reader",useGlobal:false)]
check(profile.tuning(for:"reader")?.smoothVertical == true,"independent application smoothing works when global smoothing is off")
profile.applications[0].enabled = false; check(profile.tuning(for:"reader") == nil,"application disable has priority")
profile.onlyListed = true; check(profile.tuning(for:"other") == nil,"whitelist keeps unrelated applications untouched")
// The early gesture tap preserves input; actual app rules are resolved at the annotated tail.
let input = MouseInputController(); input.config = split
input.smoother.useDisplayClock = false; input.smoother.mayPost = { true }
input.smoother.resolveApplication = { $0 == 321 ? "reader":$0 == 322 ? "editor":nil }
input.smoother.configure(split.smoothScroll)
var frames:[CGEvent] = [], pids:[pid_t] = []
input.smoother.post = { frames.append($0); pids.append($1) }
let late = ScrollRoutingTap(engine:input.smoother)
let raw = wheel()
check(!input.handleInput(.scrollWheel,raw) && frames.isEmpty,"ordinary wheel survives early gesture arbitration")
check(late.handle(raw),"annotated ordinary wheel enters independent engine"); finish(input.smoother)
check(frames.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)}) == 36 && pids.allSatisfy{$0 == 321},"frame delivery uses annotated target")
check(frames.allSatisfy { !input.handleInput(.scrollWheel,$0) && !late.handle($0) },"emitted frames never loop through either tap")
frames.removeAll(); input.setWheelMode(.freeSpin)
check(input.activeWheelMode == .freeSpin && late.handle(wheel()),"actual free-spin report switches active profile"); finish(input.smoother)
check(frames.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)}) == -81,"free-spin profile has its own distance and reversal")
input.setWheelMode(nil); check(input.activeWheelMode == .ratchet,"unknown wheel state explicitly falls back to ratchet")
let unknown = wheel(pid:999)
check(!input.smoother.consume(unknown,foregroundPID:321),"unknown actual target cannot accidentally use foreground app rule")
input.smoother.mayPost = { false }; check(!late.handle(wheel()),"without posting permission retain raw scrolling"); input.smoother.mayPost = { true }
check(!ScrollInteractionScope.bypass(targetPID:321,ownPID:123,recording:false,ring:false,practice:true,settings:true,applicationList:false),"foreign app cannot be bypassed by overlapping background window geometry")
check(!ScrollInteractionScope.bypass(targetPID:123,ownPID:123,recording:false,ring:false,practice:false,settings:true,applicationList:false,learningPage:true),"surrounding learning page receives smooth/reverse")
check(ScrollInteractionScope.bypass(targetPID:123,ownPID:123,recording:false,ring:false,practice:true,settings:false,applicationList:false,learningPage:true),"learning canvas keeps raw physical samples")
check(!ScrollInteractionScope.bypass(targetPID:123,ownPID:123,recording:false,ring:false,practice:false,settings:true,applicationList:true),"own application rules list receives ordinary smoothing")
// Held horizontal conversion enters the same engine exactly once, without discarding every tail.
input.config.mouseHabits.enabled = true; input.config.mouseHabits.wheel["2"] = .horizontal
var converted:[CGEvent] = []; input.postRoutedEvent = { e,_ in converted.append(e) }
let down = CGEvent(mouseEventSource:nil,mouseType:.otherMouseDown,mouseCursorPosition:.zero,mouseButton:.center)!
down.setIntegerValueField(.mouseEventButtonNumber,value:2)
check(input.handleInput(.otherMouseDown,down),"held horizontal button is claimed")
frames.removeAll()
for _ in 0..<3 {
    check(input.handleInput(.scrollWheel,wheel()),"held vertical wheel is converted")
    let e = converted.removeFirst(); e.setIntegerValueField(.eventTargetUnixProcessID,value:321)
    check(e.getIntegerValueField(.eventSourceUserData) == MouseEvents.heldHorizontalMarker,"conversion is marked for late processing")
    check(late.handle(e),"held conversion reaches smooth engine")
    check(e.getIntegerValueField(.eventSourceUserData) == MouseEvents.sentinel,"conversion marker is finalized after tail handling")
}
finish(input.smoother)
check(frames.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)}) == 108,"consecutive horizontal inputs retain every pending pixel")
var rebinding = wheel(); MouseEvents.mark(rebinding,as:1234567); MouseEvents.mark(rebinding)
check(rebinding.getIntegerValueField(.eventSourceUserData) == MouseEvents.sentinel,"nonzero source marker is replaced on macOS 27")
// Real native AppKit scroll view: both axes animate and reverse, without global injection.
let engine = SmoothScrollEngine(); engine.useDisplayClock = false; engine.resolveApplication = { _ in "reader" }
let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:300,height:180)); scroll.documentView = NSView(frame:NSRect(x:0,y:0,width:1800,height:1800))
let window = NSWindow(contentRect:scroll.frame,styleMask:.borderless,backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = scroll; window.orderFront(nil)
for axis in [1,2] { for reverse in [false,true] {
    var s = SmoothScrollSettings(); s.global.reverseVertical = reverse; s.global.reverseHorizontal = reverse; engine.configure(s)
    scroll.contentView.scroll(to:NSPoint(x:600,y:600)); scroll.reflectScrolledClipView(scroll.contentView)
    let before = scroll.contentView.bounds.origin; var delivered = 0
    engine.post = { event,_ in delivered += 1; scroll.scrollWheel(with:NSEvent(cgEvent:event)!) }
    check(engine.consume(axis == 1 ? wheel():wheel(0,1),foregroundPID:321),"native view input is accepted")
    let base = ProcessInfo.processInfo.systemUptime
    for i in 1...40 { engine.tick(at:base+Double(i)/120); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.002)) }
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.08))
    let after = scroll.contentView.bounds.origin
    let delta = axis == 1 ? after.y-before.y:after.x-before.x
    check(delivered>3 && abs(delta)>25,"native scroll view visibly moves on axis \(axis)")
    check((delta>0) == (axis == 1 ? !reverse:reverse),"native view reversal changes actual direction axis \(axis)")
} }
window.orderOut(nil)
// Protocol parsing/feature selection is implemented from packet documentation, with no live I/O.
let request = HIDPPPacket(slot:0xFF,feature:0x28,operation:4,client:0xC,payload:[4,0,0])
check(request.bytes(short:true) == [0x10,0xFF,0x28,0x4C,4,0,0],"short HID++ framing")
check(request.bytes().count == 20 && HIDPPPacket(bytes:request.bytes())?.matches(request) == true,"long HID++ framing and reply correlation")
check(HIDPPPacket(bytes:[0x11,0xFF,1,2,3,4,5]) == nil && HIDPPPacket(bytes:[]) == nil,"malformed/truncated reports rejected")
check(HIDPPPacket.normalized(Array(request.bytes().dropFirst()),reportID:0x11) == request.bytes(),"report ID normalized when IOKit strips it")
for change in 0..<4 {
    var other = request
    switch change { case 0:other.slot = 1; case 1:other.feature = 1; case 2:other.operation = 2; default:other.client = 3 }
    check(!other.matches(request),"unrelated replies cannot complete a request")
}
for error:UInt8 in [0xFF,0x8F] {
    let failure = HIDPPPacket(slot:request.slot,feature:error,operation:request.feature>>4,client:request.feature&15,payload:[0x4C,2,0])
    check(failure.isError(for:request),"HID++ error correlates to original command")
}
check(MouseDeviceFeature.identifier(0x19B0) == [0x19,0xB0,0] && MouseDeviceFeature.index([0,0,0]) == nil,"root feature discovery rejects missing feature")
check(MouseDeviceFeature.wheelState([0]) == .freeSpin && MouseDeviceFeature.wheelState([1]) == .ratchet && MouseDeviceFeature.wheelState([2]) == nil,"actual wheel state decodes strictly")
let notification = HIDPPPacket(slot:0xFF,feature:9,operation:1,client:0,payload:[0])
check(MouseDeviceFeature.wheelNotification(notification,slot:0xFF,index:9) == .freeSpin && MouseDeviceFeature.wheelNotification(notification,slot:1,index:9) == nil,"only matching device wheel notification switches mode")
check(MouseDeviceFeature.waveforms([0,0,0,0,0,0,0,0x12]) == 0x12,"waveform capabilities use big-endian documented offset")
check(MouseDeviceFeature.waveform(confirmation:false,mask:0x12) == 4 && MouseDeviceFeature.waveform(confirmation:true,mask:0x12) == 1 && MouseDeviceFeature.waveform(confirmation:true,mask:0) == nil,"use only advertised known waveforms")
check(DeviceHapticConfiguration(payload:[2,50,0]) == nil && DeviceHapticConfiguration(payload:[1,101,0]) == nil,"malformed haptic state cannot become a restore baseline")
// Fake firmware provides a bounded configuration lease, including intervening app changes.
final class FakeFirmware {
    var config = DeviceHapticConfiguration(enabled:false,intensity:25)
    var played:[UInt8] = [], writes:[[UInt8]] = [], waits:[TimeInterval] = []
    var rejectWrites = false, rejectReads = false, rejectPlay = false, quantize = false, failReadAfterWrite = false
    lazy var session:DeviceHapticSession = {
        let session = DeviceHapticSession { [unowned self] op,payload,reply in
            switch op {
            case 1:return self.rejectReads ? nil:self.config.payload
            case 2:
                self.writes.append(payload); guard !self.rejectWrites,let c = DeviceHapticConfiguration(payload:payload) else { return nil }
                self.config = c
                if self.failReadAfterWrite { self.rejectReads = true }
                if self.quantize && c.enabled { self.config.intensity = (c.intensity/10)*10 }
                return []
            case 4:
                check(!reply,"play is fire-and-forget"); guard !self.rejectPlay else { return nil }; self.played.append(payload[0]); return []
            default:return nil
            }
        }
        session.pause = { [unowned self] in self.waits.append($0) }; return session
    }()
}
let firmware = FakeFirmware(); firmware.quantize = true; let baseline = firmware.config
check(firmware.session.pulse(settings:RingHapticSettings(intensity:63),mask:0x12,confirmation:false),"hover pulse succeeds")
check(firmware.played == [4] && firmware.session.applied?.intensity == 60,"one hover, actual firmware strength readback")
check(firmware.session.pulse(settings:RingHapticSettings(intensity:63),mask:0x12,confirmation:true),"click pulse succeeds")
check(firmware.played == [4,1,1] && firmware.waits == [0.055],"click is two rapid pulses")
check(firmware.session.restore() && firmware.config == baseline,"leaving ring restores original device configuration")
_ = firmware.session.pulse(settings:RingHapticSettings(intensity:50),mask:0x12,confirmation:false)
firmware.config = DeviceHapticConfiguration(enabled:true,intensity:80)
check(firmware.session.restore() && firmware.config.intensity == 80,"restore preserves another application's intervening change")
_ = firmware.session.pulse(settings:RingHapticSettings(intensity:50),mask:0x12,confirmation:false)
firmware.config = DeviceHapticConfiguration(enabled:true,intensity:70)
_ = firmware.session.pulse(settings:RingHapticSettings(intensity:40),mask:0x12,confirmation:false)
check(firmware.session.restore() && firmware.config.intensity == 70,"new external baseline between pulses is retained")
_ = firmware.session.pulse(settings:RingHapticSettings(intensity:63),mask:0x12,confirmation:false)
firmware.config = DeviceHapticConfiguration(enabled:true,intensity:63)
check(firmware.session.restore() && firmware.config.intensity == 63,"external value equal to an earlier request is not mistaken for actual applied state")
let unread = FakeFirmware(); unread.failReadAfterWrite = true
check(!unread.session.pulse(settings:RingHapticSettings(intensity:60),mask:0x12,confirmation:false),"failed readback retains a pending lease")
unread.rejectReads = false; unread.failReadAfterWrite = false
check(unread.session.restore() && unread.config == baseline,"pending lease can restore when reads resume")
let rejected = FakeFirmware(); rejected.rejectWrites = true
check(!rejected.session.pulse(settings:RingHapticSettings(intensity:50),mask:0x12,confirmation:false) && rejected.played.isEmpty,"failed configuration cannot trigger an unconfigured pulse")
let offline = FakeFirmware(); offline.rejectReads = true
check(!offline.session.pulse(settings:RingHapticSettings(),mask:0x12,confirmation:false) && offline.writes.isEmpty,"failed baseline read cannot alter hardware")
let zero = FakeFirmware(); check(zero.session.pulse(settings:RingHapticSettings(intensity:0),mask:0x12,confirmation:true) && zero.played.isEmpty && zero.writes.isEmpty,"zero strength performs no hardware writes")
// Haptic selection follows pointer-highlight identities, separately for root/child/activation.
let store = SettingsStore(persistent:false); let controller = AppController(store:store)
let ring = RingView(frame:NSRect(origin:.zero,size:RingGeometry.size)); ring.controller = controller; controller.ring = ring; ring.loadConfiguration()
var selections:[UUID] = [], clicks = 0
ring.onHapticSelection = { selections.append($0) }; ring.onHapticClick = { clicks += 1 }
ring.prepare(); ring.movePointer(to:RingGeometry.point(0)); ring.movePointer(to:RingGeometry.point(0))
check(selections == [store.config.items[0].id],"hovering a root bubble pulses once")
ring.movePointer(to:RingGeometry.point(2)); ring.openFolder(2)
let child = RingGeometry.childPoint(parent:2,index:0,count:store.config.items[2].children.count)
ring.movePointer(to:child); ring.movePointer(to:child)
check(selections.suffix(2) == [store.config.items[2].id,store.config.items[2].children[0].id],"root submenu and child each pulse once")
let childButton = descendants(ring).compactMap{$0 as? NSButton}.first{$0.tag == 0 && $0.action == NSSelectorFromString("childPressed:")}!
press(childButton); check(clicks == 1,"child activation schedules one double-pulse request")
ring.prepare(armedAction:.volume); let oldSelections = selections.count; ring.movePointer(to:RingGeometry.point(0))
check(selections.count == oldSelections+1,"first pointer entry still pulses after armed action preparation")
// Native UI editing keeps mode selection independent of the mouse's actual mode.
let smooth = SmoothSettingsView(store:store,controller:controller)
let selector = descendants(smooth).compactMap{$0 as? NSSegmentedControl}.first!
let distance = descendants(smooth).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel() == "每格距离数值"}!
selector.selectedSegment = 1; _ = app.sendAction(selector.action!,to:selector.target,from:selector)
distance.doubleValue = 88; _ = app.sendAction(distance.action!,to:distance.target,from:distance)
check(store.config.freeWheelSmoothScroll.global.pixelsPerStep == 88 && store.config.smoothScroll.global.pixelsPerStep == 36,"free-spin form edits only its profile")
selector.selectedSegment = 0; _ = app.sendAction(selector.action!,to:selector.target,from:selector)
check(distance.doubleValue == 36,"ratchet form retains its separate value")
store.config.learningCount = 100
let setup = WheelSetupView(store:store,zoom:true)
let countField = descendants(setup).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel() == "每轮学习格数"}!
check(countField.integerValue == 100,"learning UI displays custom cell count")
let resetButton = descendants(setup).compactMap{$0 as? NSButton}.first{$0.title == "重置学习"}!
store.config = configuration; press(resetButton)
check(store.config.mouseHabits.adaptation.zoomProfile == nil && store.config.ringWheel.profile == learned,"reset button connects to the correct independent scope")
let release = AppRelease(info:["MouseRingReleaseLabel":"1.0 Preview 4","CFBundleVersion":"19","MouseRingReleaseDate":"2026-10-22"])
check(release.display == "版本 1.0 Preview 4（构建 19）" && appID == "local.mousering.preview","public identity and about version")
let icon = NSImage(contentsOfFile:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Orbit.icns").path)
let about = AboutView(release:release,icon:icon)
let aboutText = descendants(about).compactMap{$0 as? NSTextField}.map{$0.stringValue}.joined(separator:" ")
check(aboutText.contains(appName) && aboutText.contains("© 2026 MouseRing contributors") && aboutText.contains("发布于 2026 年 10 月 22 日") && !aboutText.lowercased().contains("mos"),"about uses public branding, date and copyright")
check(!AppController.opensSettingsAtLaunch([]) && AppController.opensSettingsAtLaunch(["app","--settings"]),"default launch is silent, explicit settings launch works")
var notifications:[String] = []; let desktop = DesktopController(send:{notifications.append($0)})
try desktop.toggle(); try desktop.toggle()
check(notifications == [DesktopController.notification,DesktopController.notification],"desktop uses direct Dock notifications for show and hide")
check(DesktopController().available,"direct desktop ABI is available on this Mac; no live toggle")
let output = CommandLine.arguments.dropFirst().first(where:{!$0.hasPrefix("--")})
if let output {
    store.config.learningCount = 100; setup.reloadFromStore()
    for (view,name) in [(about as NSView,"关于-Preview4.png"),(setup as NSView,"自动学习100格-Preview4.png")] {
        let host = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false); host.isReleasedWhenClosed = false; host.contentView = view
        view.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!; view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output+"/"+name))
    }
}
print("PASS: \(checks) learning, reset, target routing, held scrolling, dual profiles, native views, HID++ protocol, haptic lease, ring feedback, about and silent-launch checks. No global input, device I/O, or persistent settings.")

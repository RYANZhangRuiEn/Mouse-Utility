import AppKit
import Foundation

_ = NSApplication.shared
var checks = 0
func check(_ condition:@autoclosure ()->Bool,_ message:String) {
    guard condition() else { fputs("FAIL: \(message)\n",stderr); exit(1) }; checks += 1
}
func button(_ type:CGEventType,_ number:Int = 3,_ dx:Double = 0,_ dy:Double = 0) -> CGEvent {
    let event = CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:400,y:400),mouseButton:.center)!
    event.setIntegerValueField(.mouseEventButtonNumber,value:Int64(number))
    event.setDoubleValueField(.mouseEventDeltaX,value:dx); event.setDoubleValueField(.mouseEventDeltaY,value:dy)
    return event
}
func wheel(_ y:Int32,_ x:Int32 = 0,continuous:Bool = false,momentum:Bool = false,flags:CGEventFlags = []) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source:nil,units:continuous ? .pixel:.line,wheelCount:2,wheel1:y,wheel2:x,wheel3:0)!
    event.flags = flags; event.setIntegerValueField(.scrollWheelEventIsContinuous,value:continuous ? 1:0)
    if momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase,value:1) }
    return event
}
let router = MouseRouter()
var levels:[(DialAction,Double)] = []
var events:[CGEvent] = [], actions:[String] = [], keys:[KeyBinding] = [], detected:[Int] = []
router.output = { output in
    switch output {
    case .events(let value): events += value
    case .action(let value): actions.append(value)
    case .shortcut(let value): keys.append(value)
    case .detected(let value): detected.append(value)
    case .level(let action,let delta): levels.append((action,delta))
    }
}
func clear() { levels.removeAll(); events.removeAll(); actions.removeAll(); keys.removeAll(); detected.removeAll() }
var config = Configuration()
check(!config.mouseHabits.enabled,"upgrade preserves ordinary wheel by default")
check(!router.handle(.scrollWheel,wheel(1),config:config),"unconfigured scroll passes through")
check(!router.handle(.otherMouseDown,button(.otherMouseDown),config:config),"unconfigured button passes through")
config.mouseHabits = .screenshot
config.mouseBindings["2"] = "custom"
let originalItems = config.items
let encoded = try! JSONEncoder().encode(config)
let roundtrip = try! JSONDecoder().decode(Configuration.self,from:encoded)
check(roundtrip == config,"gesture and click configuration round trip")
check(config.items == originalItems,"mouse habits do not replace ring layout")

// Native events must decode as AppKit gestures, not ordinary Cmd+/- or scroll events.
for rotation in [false,true] {
    for phase:CGGesturePhase in [.began,.changed,.ended] {
        let cg = MouseEvents.gesture(rotation:rotation,value:0.06,phase:phase,at:CGPoint(x:100,y:200))!
        let event = NSEvent(cgEvent:cg)!
        check(event.type == (rotation ? .rotate:.magnify),"OS decodes the intended gesture type")
        check(event.phase == (phase == .began ? .began:phase == .changed ? .changed:.ended),"OS decodes complete gesture phase")
        check(abs((rotation ? Double(event.rotation):Double(event.magnification))-0.06)<0.00001,"OS decodes gesture amount")
        check(cg.flags.isEmpty && cg.getIntegerValueField(.eventSourceUserData) == MouseEvents.sentinel,"gesture drops modifiers and prevents recursion")
    }
}

// Hold side key + wheel zooms, ends on release, never replays a browser side-click.
clear(); check(router.handle(.otherMouseDown,button(.otherMouseDown),config:config),"held zoom captures button down")
check(events.isEmpty,"button alone does not start zoom")
check(router.handle(.scrollWheel,wheel(1),config:config,time:1),"zoom consumes original scrolling")
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.025))
check(events.count >= 2 && NSEvent(cgEvent:events[0])?.phase == .began && NSEvent(cgEvent:events[1])?.type == .magnify,"native zoom begins and changes")
check(keys.isEmpty,"pinch mode never substitutes keyboard zoom")
check(router.handle(.otherMouseUp,button(.otherMouseUp),config:config),"release consumed")
let zoomDeadline = Date(timeIntervalSinceNow:0.4)
while NSEvent(cgEvent:events.last!)?.phase != .ended && Date()<zoomDeadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01)) }
check(events.count > 4 && NSEvent(cgEvent:events.last!)?.phase == .ended,"release smoothly drains the remaining zoom then ends")
let magnifications = events.compactMap { NSEvent(cgEvent:$0) }.filter { $0.phase == .changed }.map { Double($0.magnification) }
check(magnifications.allSatisfy { $0>0 && $0<0.08 },"wheel pulse produces several small forward increments")
check(events.allSatisfy { $0.type != .otherMouseDown && $0.type != .otherMouseUp },"used zoom does not click")
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:config)
check(events.count == 2 && events[0].type == .otherMouseDown && events[1].type == .otherMouseUp,"unused hold preserves original click pair")
check(!router.handle(events[0].type,events[0],config:config),"synthetic replay cannot recurse")
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,2),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,2),config:config)
check(keys.count == 1 && keys[0].display == "⌃⌘D","middle click preserves screenshot shortcut")
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,2),config:config)
_ = router.handle(.scrollWheel,wheel(-1),config:config,time:2)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,2),config:config)
check(keys.isEmpty,"middle hold scroll suppresses lookup click")
check(events.count == 1 && events[0].getDoubleValueField(.scrollWheelEventDeltaAxis1) == 0 && events[0].getDoubleValueField(.scrollWheelEventDeltaAxis2)<0,"middle wheel converts vertical to horizontal")
for continuous in [false,true] {
    let from = wheel(7,continuous:continuous)
    from.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:2)
    from.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1,value:70)
    from.flags = [.maskControl,.maskShift]
    let converted = MouseEvents.horizontal(from:from)!
    let native = NSEvent(cgEvent:converted)!
    check(native.scrollingDeltaX != 0 && native.scrollingDeltaY == 0,"AppKit receives real horizontal displacement, not just changed fields")
    check(converted.getDoubleValueField(.scrollWheelEventRawDeltaAxis2) == 2 && converted.getDoubleValueField(.scrollWheelEventRawDeltaAxis1) == 0,"horizontal conversion transposes raw macOS scroll fields")
    check(converted.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2) == 70 && converted.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1) == 0,"horizontal conversion clears hidden accelerated vertical data")
    check(converted.flags.isEmpty,"held-button horizontal conversion does not retain zoom or shift modifiers")
    check(converted.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) == from.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),"horizontal preserves point precision")
    check(converted.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == from.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),"horizontal preserves fixed precision")
}
clear(); check(!router.handle(.scrollWheel,wheel(12),config:config,time:3),"unmodified vertical scroll remains ordinary")
_ = router.handle(.scrollWheel,wheel(0,1),config:config,time:4)
check(keys.last?.keyCode == 123,"thumbwheel maps left")
_ = router.handle(.scrollWheel,wheel(0,1),config:config,time:4.1)
check(keys.count == 1,"desktop animation spacing queues the next detent")
_ = router.handle(.scrollWheel,wheel(0,-1),config:config,time:4.5)
check(keys.count == 2 && keys.last?.keyCode == 124,"thumbwheel direction reversal")
let touchpad = wheel(0,10,continuous:true)
touchpad.setIntegerValueField(.scrollWheelEventScrollPhase,value:Int64(CGScrollPhase.changed.rawValue))
check(!router.handle(.scrollWheel,touchpad,config:config,time:5),"phased trackpad horizontal gestures preserved")
check(router.handle(.scrollWheel,wheel(0,20,continuous:true),config:config,time:5.1),"unphased high-resolution thumbwheel is handled")
check(keys.last?.keyCode == 123,"high-resolution thumbwheel sends desktop shortcut")

clear(); config.mouseHabits.zoomModifiers = UInt64(NSEvent.ModifierFlags([.command,.option]).rawValue)
check(!router.handle(.scrollWheel,wheel(1,flags:[.maskCommand,.maskAlternate]),config:config,time:7),"retired keyboard wheel modifiers cannot start zoom")
check(events.isEmpty && keys.isEmpty,"keyboard modifiers produce no synthetic zoom")
config.mouseHabits.reverseZoom = true
router.reset(); clear()
config.mouseHabits.zoomStyle = "shortcut"
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:config)
_ = router.handle(.scrollWheel,wheel(1),config:config,time:10)
check(keys.isEmpty && NSEvent(cgEvent:events.first!)?.type == .magnify,"legacy shortcut setting is ignored: zoom is native only")
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:config)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.4))
check(keys.isEmpty && events.allSatisfy { NSEvent(cgEvent:$0)?.type == .magnify },"legacy mode cannot send keyboard zoom or a stray click")
config.mouseHabits.zoomStyle = "pinch"; config.mouseHabits.reverseZoom = false

// Free pan, one-shot window navigation and rotation are separately selectable.
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,4),config:config)
_ = router.handle(.otherMouseDragged,button(.otherMouseDragged,4,12,-8),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,4),config:config)
check(events.count == 3 && events.allSatisfy { $0.type == .scrollWheel },"pan emits begin/change/end")
check(events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1)>0 && events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis2)<0,"two-dimensional pan preserves both axes")
config.mouseHabits.reverseMove["4"] = true
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,4),config:config)
_ = router.handle(.otherMouseDragged,button(.otherMouseDragged,4,12,-8),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,4),config:config)
check(events.count == 3 && events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1)<0 && events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis2)>0,"reverse movement flips both pan axes")
config.mouseHabits.reverseMove.removeValue(forKey:"4")
config.mouseBindings["5"] = "custom"; config.mouseHabits.shortcuts["5"] = .command("C",code:8)
for reversed in [false,true] {
    config.mouseHabits.reverseMove["5"] = reversed
    for (dx,dy,code,opposite) : (Double,Double,UInt16,UInt16) in [(50,0,124,123),(-50,0,123,124),(0,-50,126,125),(0,50,125,126)] {
        clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,5),config:config)
        _ = router.handle(.otherMouseDragged,button(.otherMouseDragged,5,dx/5,dy/5),config:config)
        check(keys.isEmpty,"desktop navigation ignores small accidental movement")
        for _ in 0..<3 { _ = router.handle(.otherMouseDragged,button(.otherMouseDragged,5,dx,dy),config:config) }
        _ = router.handle(.otherMouseDragged,button(.otherMouseDragged,5,-dy,-dx),config:config)
        _ = router.handle(.otherMouseUp,button(.otherMouseUp,5),config:config)
        check(keys.count == 1 && keys[0].keyCode == (reversed ? opposite:code),"all four navigation directions and reversals fire once per hold")
        check(keys[0].modifiers == UInt64(NSEvent.ModifierFlags.control.rawValue),"desktop and Mission Control navigation sends Control arrows")
        check(events.isEmpty && actions.isEmpty,"completed navigation never fires the assigned click or replays a mouse click")
    }
}
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,5),config:config)
_ = router.handle(.otherMouseDragged,button(.otherMouseDragged,5,2,2),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,5),config:config)
check(keys.count == 1 && keys[0].display == "⌘C","unused navigation hold preserves its click shortcut")
config.mouseHabits.move["8"] = .windows
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,8),config:config)
_ = router.handle(.otherMouseDragged,button(.otherMouseDragged,8,50,10),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,8),config:config)
check(keys.count == 1 && keys[0].keyCode == 124,"another button retains normal direction and selects dominant axis")
config.mouseHabits.move.removeValue(forKey:"8")
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,5),config:config)
config.mouseHabits.reverseMove["5"] = false
_ = router.handle(.otherMouseDragged,button(.otherMouseDragged,5,10,-50),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,5),config:config)
check(keys.count == 1 && keys[0].keyCode == 125,"movement direction is stable throughout a held press")
config.mouseBindings["5"] = "none"; config.mouseHabits.shortcuts.removeValue(forKey:"5")
config.mouseHabits.reverseMove.removeValue(forKey:"5")
clear(); config.mouseHabits.wheel["3"] = .rotate
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:config)
_ = router.handle(.scrollWheel,wheel(1),config:config,time:11)
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:config)
check(events.count == 3 && events.allSatisfy { NSEvent(cgEvent:$0)?.type == .rotate },"wheel rotation is a native gesture")
clear(); config.mouseHabits.wheel["3"] = .zoom
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:config)
_ = router.handle(.scrollWheel,wheel(10,momentum:true),config:config,time:12)
check(events.isEmpty && keys.isEmpty,"momentum cannot amplify zoom")
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:config)
check(events.isEmpty,"momentum use cannot leak a click")
clear(); router.detecting = true
check(router.handle(.otherMouseDown,button(.otherMouseDown,8),config:config),"detect captures any auxiliary button")
check(router.handle(.otherMouseUp,button(.otherMouseUp,8),config:config),"detect captures release")
check(detected == [8] && keys.isEmpty && events.isEmpty && actions.isEmpty,"detection identifies button without executing it")

// Bypass protects recording/settings and cancels a pending click on focus change.
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,2),config:config)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,2),config:config,bypass:true)
check(keys.isEmpty && actions.isEmpty,"switching to settings cancels pending click")
check(!router.handle(.otherMouseDown,button(.otherMouseDown),config:config,bypass:true),"settings bypass does not capture gestures")
check(!router.handle(.scrollWheel,wheel(1,flags:[.maskCommand,.maskAlternate]),config:config,bypass:true),"recording bypass does not capture modifier scroll")
config.mouseBindings["6"] = "showRing"
_ = router.handle(.otherMouseDown,button(.otherMouseDown,6),config:config,bypass:true)
_ = router.handle(.otherMouseUp,button(.otherMouseUp,6),config:config,bypass:true)
check(actions == ["showRing"],"ring toggle remains available while ring is open")


clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,2),config:config)
router.reset()
check(router.handle(.otherMouseUp,button(.otherMouseUp,2),config:config),"reset consumes the release of a suppressed down")
check(keys.isEmpty && actions.isEmpty,"reset never fires a pending click")
config.mouseHabits.wheel["8"] = .horizontal
clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,3),config:config)
_ = router.handle(.otherMouseDown,button(.otherMouseDown,8),config:config)
_ = router.handle(.scrollWheel,wheel(1),config:config,time:15)
check(events.count == 1 && events[0].type == .scrollWheel,"most recently held configured key has priority")
router.reset(); clear()

clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,2),config:config); router.reset()
check(router.handle(.otherMouseDragged,button(.otherMouseDragged,2,10,0),config:config),"focus-reset swallows unmatched drags until release")
_ = router.handle(.otherMouseUp,button(.otherMouseUp,2),config:config)
var oldObject = try! JSONSerialization.jsonObject(with:encoded) as! [String:Any]
oldObject.removeValue(forKey:"mouseHabits"); oldObject["schemaVersion"] = 3
let upgraded = try! JSONDecoder().decode(Configuration.self,from:JSONSerialization.data(withJSONObject:oldObject))
check(upgraded.items == config.items && !upgraded.mouseHabits.enabled,"0.3 upgrade preserves layout and does not enable new gestures")


for code:UInt16 in [123,124,125,126] {
    let binding = KeyBinding(name:"",keyCode:code,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"方向")
    let pair = try! InputSender.keyboardEvents(binding)
    check(pair.0.flags.contains(.maskControl) && pair.0.flags.contains(.maskSecondaryFn),"system arrows retain Control and function flags")
    check(pair.0.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue),"system arrows originate from HID state")
    check(pair.0.type == .keyDown && pair.1.type == .keyUp,"system arrow has paired key events")
}
let copyPair = try! InputSender.keyboardEvents(.command("C",code:8))
check(copyPair.0.flags.contains(.maskCommand) && !copyPair.0.flags.contains(.maskSecondaryFn),"ordinary shortcuts retain intended flags")
// New direction preferences preserve old navigation values and round-trip per button.
let legacyMovement = #"{"enabled":true,"move":{"5":"windows"},"reverseSpaces":true}"#.data(using:.utf8)!
let legacyRestored = try! JSONDecoder().decode(MouseHabits.self,from:legacyMovement)
check(legacyRestored.move["5"] == .windows && legacyRestored.reverseMove.isEmpty,"existing window navigation remains selected with normal movement direction")
var movePreferences = legacyRestored; movePreferences.reverseMove = ["5":true,"8":false]
let moveRestored = try! JSONDecoder().decode(MouseHabits.self,from:JSONEncoder().encode(movePreferences))
check(moveRestored == movePreferences,"per-button movement reverse survives save and restore")
check(moveRestored.reverseSpaces && !moveRestored.reverseZoom,"movement reverse preserves independent wheel directions")
movePreferences.reverseMove["0"] = true; movePreferences.reverseMove["32"] = true
check(movePreferences.sanitized().reverseMove == ["5":true,"8":false],"invalid imported movement button numbers are removed")
let inactiveLegacy = #"{"enabled":false,"wheel":{"5":"zoom"},"thumbSpaces":true}"#.data(using:.utf8)!
let migratedHabits = try! JSONDecoder().decode(MouseHabits.self,from:inactiveLegacy)
check(migratedHabits.enabled && migratedHabits.wheel["5"] == .zoom,"0.4 configured rules are activated on upgrade")
var paused = migratedHabits; paused.enabled = false; paused.manuallyPaused = true
let pausedRestored = try! JSONDecoder().decode(MouseHabits.self,from:JSONEncoder().encode(paused))
check(!pausedRestored.enabled && pausedRestored.manuallyPaused,"explicit pause remains paused after restart")
var newRule = MouseHabits(); newRule.wheel["3"] = .zoom; newRule.activateConfiguredRules()
check(newRule.enabled && !newRule.manuallyPaused,"choosing a new rule activates it")
check(MouseButtonIdentity.name(2) == "按键 3（中键）" && MouseButtonIdentity.name(3) == "按键 4" && MouseButtonIdentity.name(5) == "按键 6","selector and detection share one numbering convention")

for fps in [60.0,120.0] {
    var smoothing = ZoomInterpolation(); smoothing.append(0.18)
    var scale = 1.0, frames = 0
    while smoothing.pending && frames < 60 {
        let delta = smoothing.advance(seconds:1/fps)
        check(delta>=0 && delta<0.18,"smooth pulse stays bounded and monotonic")
        scale *= 1+delta; frames += 1
    }
    check(abs(log(scale)-0.18)<0.000001 && !smoothing.pending,"smooth pulse preserves requested scale")
    check(frames>2 && Double(frames)/fps < 0.25,"animation settles quickly at 60 and 120 Hz")
}
var reversal = ZoomInterpolation(); reversal.append(0.15); _ = reversal.advance(seconds:1/60)
reversal.append(-0.04)
check(reversal.advance(seconds:1/60)<0,"reversal responds on the next frame")
reversal.append(.infinity)
check(reversal.remaining.isFinite,"invalid smoothing delta ignored")
var dirty = config; dirty.mouseHabits.sensitivity = .infinity; dirty.mouseHabits.wheel["0"] = .zoom; dirty.mouseHabits.zoomModifiers = .max
let clean = dirty.sanitized()
check(clean.mouseHabits.sensitivity == 1 && clean.mouseHabits.wheel["0"] == nil,"invalid settings normalized")
check(clean.mouseHabits.zoomModifiers == 0,"retired keyboard modifiers are removed on import")
// A physical detent may be split across several accelerated reports. Learn the whole burst.
var learning = WheelLearner()
for i in 0..<12 {
    let sign = i<6 ? 1.0:-1.0
    for fragment in 0..<3 {
        learning.record(WheelSample(values:["raw":sign*2,"point":sign*Double(4+fragment),"line":sign],precise:true),time:Double(i)*0.6+Double(fragment)*0.02)
    }
    learning.idle(time:Double(i)*0.6+0.4)
}
let learned = learning.proposal!
check(learning.samples.count == 12 && learned.units["raw"] == 6,"learning groups split reports into one physical notch")
check(learning.positive == 6 && learning.negative == 6,"learning covers both wheel directions")
var calibrated = WheelInterpreter()
for i in 0..<10 {
    let motion = calibrated.consume(WheelSample(values:["raw":6,"point":Double(30+i*20)],precise:true),profile:learned,time:Double(i)*0.1)
    check(motion.steps == 1 && abs(motion.amount-1)<0.00001,"raw calibration keeps one notch despite accelerated pixel variation")
}
calibrated.reset()
for i in 0..<5 { check(calibrated.consume(WheelSample(values:["raw":1]),profile:learned,time:Double(i)*0.01).steps == 0,"fractional reports do not round up to full notches") }
check(calibrated.consume(WheelSample(values:["raw":1]),profile:learned,time:0.05).steps == 1,"six small reports accumulate to one learned notch")
check(calibrated.consume(WheelSample(values:["raw":18]),profile:learned,time:0.06).steps == 3,"fast multi-notch reports retain all steps")
check(calibrated.consume(WheelSample(values:["raw":-6]),profile:learned,time:0.07).steps == -1,"reversal responds without old fractional debt")
check(calibrated.consume(WheelSample(values:["raw":60],momentum:true),profile:learned,time:0.08).steps == 0,"synthetic momentum is not counted twice")
var bouncy = WheelLearner()
for i in 0..<12 {
    let sign = i<6 ? 1.0:-1.0
    bouncy.record(WheelSample(values:["raw":sign*6]),time:Double(i))
    bouncy.record(WheelSample(values:["raw":-sign]),time:Double(i)+0.015)
    bouncy.idle(time:Double(i)+0.4)
}
check(bouncy.proposal?.units["raw"] == 5 && bouncy.samples.count == 12,"small reverse bounce remains part of the same physical notch")
var oneWay = WheelLearner()
for i in 0..<12 { oneWay.record(WheelSample(values:["raw":6]),time:Double(i)); oneWay.flush() }
check(oneWay.proposal == nil,"one-direction learning cannot be saved as a complete profile")
var unstable = WheelLearner()
for i in 0..<12 { unstable.record(WheelSample(values:["raw":(i<6 ? 1.0:-1.0)*Double(i%3+1)]),time:Double(i)); unstable.flush() }
check(unstable.proposal == nil,"inconsistent physical-step samples are rejected")
var desktop = DesktopSteps()
check(desktop.append(3,time:0) == 1 && desktop.pending == 2,"three notches emit one desktop and retain two")
check(desktop.advance(time:0.1) == nil && desktop.pending == 2,"animation spacing does not discard queued notches")
check(desktop.advance(time:0.33) == 1 && desktop.advance(time:0.66) == 1 && desktop.pending == 0,"queued desktop notches drain in order")
_ = desktop.append(4,time:1)
check(desktop.append(-1,time:1.1) == nil && desktop.pending == -1,"desktop reversal discards the unexecuted old-direction tail")
check(desktop.advance(time:1.34) == -1,"desktop reversal emits the new direction")
var wheelSettings = WheelSettings(); wheelSettings.zoomProfile = learned; wheelSettings.mode = .smooth
let settingsRestored = try! JSONDecoder().decode(WheelSettings.self,from:JSONEncoder().encode(wheelSettings))
check(settingsRestored == wheelSettings,"learned wheel profiles, mode and step sizes survive restart")
check(legacyRestored.adaptation.levelStep == 0.1 && legacyRestored.adaptation.zoomStep == 0.1,"old configurations receive ten-percent wheel defaults")
var badWheel = WheelSettings(); badWheel.vertical.units = ["raw":.infinity,"point":-1,"bad":4]; badWheel.zoomStep = .nan; badWheel.levelStep = 20
let cleanWheel = badWheel.sanitized()
check(cleanWheel.vertical.units.isEmpty && cleanWheel.zoomStep == 0.1 && cleanWheel.levelStep == 0.2,"invalid wheel settings are bounded")
for number in [2,3,4,5,6,8,12,31] {
    var horizontalConfig = Configuration(); horizontalConfig.mouseHabits.enabled = true; horizontalConfig.mouseHabits.wheel[String(number)] = .horizontal
    router.reset(); clear()
    _ = router.handle(.otherMouseDown,button(.otherMouseDown,number),config:horizontalConfig)
    _ = router.handle(.scrollWheel,wheel(2),config:horizontalConfig)
    _ = router.handle(.otherMouseUp,button(.otherMouseUp,number),config:horizontalConfig)
    check(events.count == 1 && NSEvent(cgEvent:events[0])!.scrollingDeltaX != 0 && NSEvent(cgEvent:events[0])!.scrollingDeltaY == 0,"horizontal scrolling works with every auxiliary button identity")
}
for action:HeldWheelAction in [.volume,.brightness] {
    var levelConfig = Configuration(); levelConfig.mouseHabits.enabled = true; levelConfig.mouseHabits.wheel["3"] = action; levelConfig.mouseHabits.adaptation.vertical = learned
    router.reset(); clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown),config:levelConfig)
    let pulse = wheel(1); pulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:6)
    _ = router.handle(.scrollWheel,pulse,config:levelConfig)
    check(levels.isEmpty,"legacy held level binding cannot adjust outside the ring")
    _ = router.handle(.otherMouseUp,button(.otherMouseUp),config:levelConfig)
    check(events.isEmpty,"used level hold does not replay a click")
}
router.reset(); clear()
var detentConfig = Configuration(); detentConfig.mouseHabits.enabled = true; detentConfig.mouseHabits.wheel["3"] = .zoom
// Inject one learned detent in two reports, with no intermediate magnification in detent mode.
detentConfig.mouseHabits.adaptation.mode = .detent; detentConfig.mouseHabits.adaptation.zoomProfile = learned
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:detentConfig)
let halfPulse = wheel(1); halfPulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:3)
_ = router.handle(.scrollWheel,halfPulse,config:detentConfig)
check(events.isEmpty,"detent zoom waits for a complete calibrated notch")
_ = router.handle(.scrollWheel,halfPulse,config:detentConfig)
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:detentConfig)
let detentDeadline = Date(timeIntervalSinceNow:0.5)
while events.last.flatMap({NSEvent(cgEvent:$0)})?.phase != .ended && Date()<detentDeadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01)) }
let detentScale = events.compactMap { NSEvent(cgEvent:$0) }.filter { $0.type == .magnify && $0.phase == .changed }.reduce(1.0) { $0*(1+Double($1.magnification)) }
check(abs(detentScale-1.1)<0.000001,"one calibrated notch zooms by exactly ten percent after smoothing")
router.reset(); clear()
var smoothConfig = detentConfig; smoothConfig.mouseHabits.adaptation.mode = .smooth; smoothConfig.mouseHabits.sensitivity = 3
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:smoothConfig)
let finePulse = wheel(1); finePulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:1)
for _ in 0..<12 { _ = router.handle(.scrollWheel,finePulse,config:smoothConfig) }
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.025))
check(events.count>=2,"free-spin zoom responds to sub-detent input immediately")
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:smoothConfig)
let smoothDeadline = Date(timeIntervalSinceNow:0.6)
while events.last.flatMap({NSEvent(cgEvent:$0)})?.phase != .ended && Date()<smoothDeadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01)) }
let smoothChanges = events.compactMap { NSEvent(cgEvent:$0) }.filter { $0.type == .magnify && $0.phase == .changed }
let smoothScale = smoothChanges.reduce(1.0) { $0*(1+Double($1.magnification)) }
check(abs(smoothScale-1.21)<0.000001,"free-spin fractions conserve calibrated scale and ignore the legacy speed multiplier")
check(smoothChanges.count>2 && smoothChanges.allSatisfy { $0.magnification>0 && $0.magnification<0.15 },"free-spin emits small native increments through a complete smooth lifecycle")
// Known physical counts, selected-source conservation and real-percentage feedback.
var counted = CountedWheelLearner()
for sign in [1.0,-1.0] {
    counted.begin()
    for _ in 0..<40 { counted.record(WheelSample(values:["raw":sign*0.5,"point":sign*5])) }
    check(counted.finish(physicalCount:10),"known-count trial accepted")
}
let countedProfile = counted.proposal!
check(countedProfile.units["raw"] == 2 && countedProfile.samples == 20 && countedProfile.source == "raw","actual physical notches, not pause grouping, define zoom unit")
check(WheelSample(values:["raw":2,"point":1000]).normalized(countedProfile) == 1,"acceleration does not change calibrated zoom")
check(WheelSample(values:["point":1000]).normalized(countedProfile) == 0,"selected-source zero tails cannot fall back to accelerated pixels")
var slowFraction = WheelInterpreter()
_ = slowFraction.consume(WheelSample(values:["raw":1]),profile:countedProfile,time:1,expireAfterIdle:false)
check(slowFraction.consume(WheelSample(values:["raw":1]),profile:countedProfile,time:3,expireAfterIdle:false).steps == 1,"held zoom preserves a physical detent split over idle intervals")
check(AppZoomCalibration.fit(before:100,after:100,physicalSteps:3,step:0.1) == nil,"unchanged external application cannot be called adapted")
let feedbackFit = AppZoomCalibration.fit(before:100,after:pow(1.1,1.5)*100,physicalSteps:3,step:0.1)!
check(abs(feedbackFit.gain-2)<0.000001 && !feedbackFit.verified,"actual percent feedback scales the target app independently")
check(AppZoomCalibration.fit(before:100,after:133.1,physicalSteps:3,step:0.1,currentGain:2)?.verified == true,"only matching actual percent feedback is verified")
check(AppZoomCalibration.fit(before:133.1,after:100,physicalSteps:3,step:0.1)?.verified == true,"real percent verification is reversible")
router.reset(); clear(); router.applicationID = "com.google.Chrome"
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:detentConfig)
let wholePulse = wheel(1); wholePulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:6)
_ = router.handle(.scrollWheel,wholePulse,config:detentConfig)
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:detentConfig)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.4))
let chromiumChanges = events.compactMap { NSEvent(cgEvent:$0) }.filter { $0.phase == .changed }
check(chromiumChanges.count>2 && abs(Double(chromiumChanges[0].magnification)-0.4999)<0.00001,"Chromium startup uses native threshold activation before fine frames")
check(keys.isEmpty && events.allSatisfy { NSEvent(cgEvent:$0)?.type == .magnify },"Chromium adaptation remains entirely native gesture based")
check(events.enumerated().dropFirst().allSatisfy { events[$0.offset-1].timestamp <= $0.element.timestamp },"native gesture timestamps are monotonic")
router.reset(); clear(); router.applicationID = "com.microsoft.Word"
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:detentConfig)
_ = router.handle(.scrollWheel,wholePulse,config:detentConfig)
_ = router.handle(.otherMouseUp,button(.otherMouseUp),config:detentConfig)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.4))
check(events.compactMap { NSEvent(cgEvent:$0) }.allSatisfy { abs($0.magnification)<0.1 } && keys.isEmpty,"Word never receives the Chromium-specific activation shim or a zoom shortcut")
router.reset(); clear(); router.applicationID = ""
var independent = detentConfig
independent.mouseHabits.adaptation.zoomProfile = countedProfile
independent.mouseHabits.adaptation.vertical = learned
independent.mouseHabits.wheel["3"] = .volume
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:independent)
_ = router.handle(.scrollWheel,wholePulse,config:independent)
check(levels.isEmpty,"outside zoom calibration cannot enable a volume adjustment")
router.reset(); clear()
independent.mouseHabits.thumbSpaces = true
independent.mouseHabits.adaptation.horizontal = WheelProfile(units:["line":100000],samples:20,variation:0)
_ = router.handle(.scrollWheel,wheel(0,1),config:independent,time:30)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.4))
check(keys.count == 1,"side wheel uses legacy interpretation and ignores old horizontal learning")
// Regression: an unlearned raw/point packet must never become an 80-point level jump.
for mode:WheelMode in [.balanced,.detent,.smooth] {
    for action:HeldWheelAction in [.volume,.brightness] {
        var c = Configuration(); c.mouseHabits.enabled = true; c.mouseHabits.wheel["3"] = action; c.mouseHabits.adaptation.mode = mode
        router.reset(); clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown),config:c)
        let big = wheel(8,continuous:true); big.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:8); big.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,value:84)
        for j in 0..<8 { _ = router.handle(.scrollWheel,big,config:c,time:100+Double(j)*0.005) }
        check(levels.isEmpty,"unlearned levels remain inactive outside ring in every zoom mode")
        let reverse = big.copy()!; reverse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:-8)
        _ = router.handle(.scrollWheel,reverse,config:c,time:100.04)
        check(levels.isEmpty,"reversing an outside wheel cannot change levels")
    }
}
var physicalLevels = LevelWheelInterpreter()
let preciseProfile = WheelProfile(units:["raw":8,"point":84],samples:20,variation:0,source:"raw")
for j in 0..<20 {
    let m = physicalLevels.consume(WheelSample(values:["raw":8,"point":Double(80+j*30)],precise:true),profile:preciseProfile,time:Double(j)*0.005)
    check(m.steps == 1,"learned levels retain every fast physical notch despite pixel acceleration")
}
check(physicalLevels.consume(WheelSample(values:["point":800],precise:true),profile:preciseProfile,time:0.2).steps == 0,"learned raw-source tails are not counted again as level changes")
var guidance = GuidedWheelLearning(); _ = guidance.advance()
check(guidance.stage == .up && guidance.advance() == nil && guidance.failure == .noInput,"guided learning waits for actual main wheel input")
for _ in 0..<20 { guidance.record(WheelSample(values:["raw":4])) }
_ = guidance.advance(); check(guidance.stage == .down,"guided first ten physical notches advance to opposite direction")
for _ in 0..<20 { guidance.record(WheelSample(values:["raw":4])) }
check(guidance.advance() == nil && guidance.stage == .down && guidance.failure == .inconsistent,"wrong-direction second round is retryable without discarding first")
for _ in 0..<20 { guidance.record(WheelSample(values:["raw":-4])) }
let guidedProfile = guidance.advance()
check(guidance.stage == .done && guidedProfile?.units["raw"] == 8 && guidedProfile?.samples == 20,"ten plus ten learns whole physical detents, auto-completing after retry")
// Sparse Logitech report shapes must decode to real horizontal motion.
for precise in [false,true] {
    for field:CGEventField in [.scrollWheelEventRawDeltaAxis1,.scrollWheelEventFixedPtDeltaAxis1,.scrollWheelEventAcceleratedDeltaAxis1,.scrollWheelEventPointDeltaAxis1] {
        let sparse = wheel(0,continuous:precise)
        if field == .scrollWheelEventPointDeltaAxis1 { sparse.setIntegerValueField(field,value:8) }
        else { sparse.setDoubleValueField(field,value:field == .scrollWheelEventFixedPtDeltaAxis1 ? 0.25:8) }
        for reversed in [false,true] {
            let out = MouseEvents.horizontal(from:sparse,reverse:reversed)!, native = NSEvent(cgEvent:out)!
            check(native.scrollingDeltaX != 0 && native.scrollingDeltaY == 0,"raw/fixed/point-only reports yield nonzero pure horizontal AppKit scrolling")
            check((native.scrollingDeltaX<0) == reversed,"sparse horizontal native displacement honors reversal")
        }
    }
}
for number in [2,3,6,12,31] {
    var c = Configuration(); c.mouseHabits.enabled = true; c.mouseHabits.wheel[String(number)] = .horizontal; c.mouseHabits.reverseWheel[String(number)] = true
    router.reset(); clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown,number),config:c)
    c.mouseHabits.reverseWheel[String(number)] = false
    _ = router.handle(.scrollWheel,wheel(2),config:c)
    check(events.count == 1 && NSEvent(cgEvent:events[0])!.scrollingDeltaX<0,"every auxiliary identity captures its own wheel direction for the held gesture")
    _ = router.handle(.otherMouseUp,button(.otherMouseUp,number),config:c)
    check(events.count == 1 && keys.isEmpty && actions.isEmpty,"used reversed wheel hold never fires a stray click")
}
for action:HeldWheelAction in [.zoom,.rotate,.spaces] {
    var c = Configuration(); c.mouseHabits.enabled = true; c.mouseHabits.wheel["3"] = action; c.mouseHabits.reverseWheel["3"] = true
    c.mouseHabits.adaptation.vertical = learned; c.mouseHabits.adaptation.levelProfile = preciseProfile
    router.reset(); clear(); _ = router.handle(.otherMouseDown,button(.otherMouseDown),config:c)
    let pulse = wheel(1); pulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:8)
    _ = router.handle(.scrollWheel,pulse,config:c,time:200); _ = router.handle(.otherMouseUp,button(.otherMouseUp),config:c)
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.4))
    switch action {
    case .volume,.brightness: check(levels.count == 1 && levels[0].1<0,"per-button wheel reversal flips level actions")
    case .zoom,.rotate: check(events.compactMap{NSEvent(cgEvent:$0)}.filter{$0.phase == .changed}.allSatisfy{action == .zoom ? $0.magnification<0:$0.rotation<0} && !events.isEmpty && keys.isEmpty,"per-button zoom/rotation reversal preserves native-only gestures")
    case .spaces: check(!keys.isEmpty && keys.allSatisfy{$0.keyCode == 124},"per-button reversal flips desktop wheel navigation")
    default:break
    }
}
var reversalModel = MouseHabits(); reversalModel.reverseWheel = ["3":true,"12":false,"0":true,"32":true]
let reversalRestored = try! JSONDecoder().decode(MouseHabits.self,from:JSONEncoder().encode(reversalModel))
check(reversalRestored.reverseWheel == ["3":true,"12":false],"per-button wheel directions survive save and invalid imports are removed")
check(legacyRestored.reverseWheel.isEmpty,"legacy mouse settings retain normal wheel direction")
var withLevels = WheelSettings(); withLevels.levelProfile = preciseProfile; withLevels.zoomProfile = countedProfile
check(try! JSONDecoder().decode(WheelSettings.self,from:JSONEncoder().encode(withLevels)).zoomProfile == countedProfile,"zoom storage preserves its own calibration")
var scoped = Configuration()
scoped.ringWheel = RingWheelSettings(profile: preciseProfile, step: 0.1)
scoped.mouseHabits.adaptation.zoomProfile = countedProfile
scoped.mouseHabits.adaptation.zoomStep = 0.05
let scopedData = try! JSONEncoder().encode(scoped)
let scopedReloaded = try! JSONDecoder().decode(Configuration.self,from:scopedData)
check(scopedReloaded.ringWheel == scoped.ringWheel && scopedReloaded.mouseHabits.adaptation.zoomProfile == countedProfile && scopedReloaded.mouseHabits.adaptation.zoomStep == 0.05,"ring and zoom calibrations independently survive restart")
let json = try! JSONSerialization.jsonObject(with:scopedData) as! [String:Any]
let mouseJSON = json["mouseHabits"] as! [String:Any], zoomJSON = mouseJSON["adaptation"] as! [String:Any]
check(json["ringWheel"] != nil && zoomJSON["levelProfile"] == nil && zoomJSON["levelStep"] == nil && zoomJSON["vertical"] == nil,"new zoom storage contains no level or shared calibration")
var oldJSON = json
oldJSON.removeValue(forKey:"ringWheel")
var oldMouse = mouseJSON, oldWheel = zoomJSON
oldWheel["vertical"] = ["units":["raw":6],"samples":20,"variation":0,"source":"raw"]
oldWheel["levelStep"] = 0.2; oldMouse["adaptation"] = oldWheel; oldMouse["zoomModifiers"] = 1048576
oldMouse["wheel"] = ["3":"volume","4":"zoom"]; oldJSON["mouseHabits"] = oldMouse
let migratedScopes = try! JSONDecoder().decode(Configuration.self,from:JSONSerialization.data(withJSONObject:oldJSON))
check(migratedScopes.ringWheel.profile.units["raw"] == 6 && migratedScopes.ringWheel.step == 0.2 && migratedScopes.mouseHabits.adaptation.zoomProfile == countedProfile,"legacy shared profile is copied into independent ring storage without replacing working zoom")
check(migratedScopes.mouseHabits.zoomModifiers == 0 && migratedScopes.mouseHabits.wheel["3"] == nil && migratedScopes.mouseHabits.wheel["4"] == .zoom,"obsolete keyboard and outside level bindings are retired during migration")
router.reset(); clear()
var bypassed = detentConfig
_ = router.handle(.otherMouseDown,button(.otherMouseDown),config:bypassed)
check(!router.handle(.scrollWheel,wholePulse,config:bypassed,bypass:true) && events.isEmpty,"visible ring bypass prevents held zoom simulation")
router.reset()
print("PASS: \(checks) mouse routing and native gesture checks; no global input was posted.")

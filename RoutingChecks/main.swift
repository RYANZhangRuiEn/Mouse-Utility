import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var checks = 0
func check(_ condition:@autoclosure ()->Bool,_ text:String) { guard condition() else { fatalError(text) }; checks += 1 }
func event(_ y:Int32 = 1,_ x:Int32 = 0)->CGEvent {
    let e = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:2,wheel1:y,wheel2:x,wheel3:0)!
    e.setIntegerValueField(.eventTargetUnixProcessID,value:321); return e
}
let engine = SmoothScrollEngine(); engine.useDisplayClock = false; engine.resolveApplication = { _ in "reader" }
var posted:[CGEvent] = []; engine.post = { e,_ in posted.append(e) }
let tap = ScrollRoutingTap(engine:engine)
var reverse = SmoothScrollSettings(); reverse.enabled = false; reverse.global.reverseVertical = true
engine.configure(reverse)
let raw = event(2,3); raw.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:6)
raw.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:123)
let originalWindow = raw.getIntegerValueField(.mouseEventWindowUnderMousePointer), originalTarget = raw.getIntegerValueField(.eventTargetUnixProcessID)
check(!tap.handle(raw),"reverse-only returns the native event, never swallows and reposts it")
check(raw.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -2 && raw.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3,"native axis direction is changed in place")
check(raw.getDoubleValueField(.scrollWheelEventRawDeltaAxis1) == -6 && posted.isEmpty,"native raw units preserved without asynchronous output")
check(raw.getIntegerValueField(.mouseEventWindowUnderMousePointer) == originalWindow && raw.getIntegerValueField(.eventTargetUnixProcessID) == originalTarget,"reverse-only preserves the target envelope")
var inactiveAxis = SmoothScrollSettings(); inactiveAxis.global.smoothVertical = false; inactiveAxis.global.reverseVertical = true
engine.configure(inactiveAxis); let verticalOnly = event()
check(!tap.handle(verticalOnly) && verticalOnly.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1 && posted.isEmpty,"an idle smoothed axis does not force active unsmoothed input through reposting")
reverse.global.horizontalKey = ScrollTrigger.choices[2]; reverse.global.reverseHorizontal = true
engine.configure(reverse); let horizontal = event(); horizontal.flags = .maskShift
check(!tap.handle(horizontal) && horizontal.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0 && horizontal.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -1,"horizontal conversion without smoothing stays in the original stream")
// A fresh pixel event has no target window. A frame copied from a native envelope keeps it.
let view = NSScrollView(frame:NSRect(x:0,y:0,width:400,height:200)); view.documentView = NSView(frame:NSRect(x:0,y:0,width:1800,height:1800))
let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = view; window.orderFront(nil)
let native = NSEvent.mouseEvent(with:.mouseMoved,location:NSPoint(x:150,y:100),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
let reference = native.cgEvent!; reference.type = .scrollWheel
reference.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(ProcessInfo.processInfo.processIdentifier))
let frame = ScrollOutput.pixelFrame(reference:reference,x:12,y:-36)!
let fresh = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:-36,wheel2:12,wheel3:0)!
check(NSEvent(cgEvent:fresh)!.windowNumber == 0,"regression precondition: newly constructed pixels have no window")
check(NSEvent(cgEvent:frame)!.windowNumber == native.windowNumber,"copied frame keeps native window routing")
check(NSEvent(cgEvent:frame)!.locationInWindow == native.locationInWindow,"copied frame keeps window-local coordinates")
check(frame.getIntegerValueField(.eventTargetUnixProcessID) == ProcessInfo.processInfo.processIdentifier,"copied frame retains actual process target")
check(NSEvent(cgEvent:frame)!.scrollingDeltaX == 12 && NSEvent(cgEvent:frame)!.scrollingDeltaY == -36,"copied envelope carries the new native pixel payload")
check(!SmoothScrollEngine.isOrdinaryWheel(frame) && CGEventSource(event:frame)!.localEventsSuppressionInterval == 0,"output cannot loop or suppress subsequent physical input")
// The actual AppKit queue retains the addressed window, rather than direct view invocation.
app.postEvent(NSEvent(cgEvent:frame)!,atStart:false)
let queued = app.nextEvent(matching:.scrollWheel,until:Date(timeIntervalSinceNow:0.2),inMode:.default,dequeue:true)
check(queued?.windowNumber == window.windowNumber && queued?.scrollingDeltaY == -36,"frame survives native application event queue with its window")
window.orderOut(nil)
// No visible windows: automatic delivery must finish without screen-redraw callbacks.
let background = SmoothScrollEngine(); background.resolveApplication = { _ in "reader" }
var count = 0,total:Int64 = 0
background.post = { e,_ in count += 1; total += e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
check(background.consume(event(),foregroundPID:0),"background engine accepts a wheel impulse")
let deadline = Date(timeIntervalSinceNow:1.5)
while background.running && Date()<deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005)) }
check(!background.running && count>4 && total == 36,"background timer emits every pixel and stops without a visible window")
let absent = SmoothScrollEngine(); absent.resolveApplication = { _ in "reader" }
check(!absent.consume(event(),foregroundPID:0),"missing output never swallows the original event")
background.mayPost = { false }
check(!background.consume(event(),foregroundPID:0),"unavailable posting permission leaves physical input untouched")
print("PASS: \(checks) native routing envelope, in-place reversal, queue delivery, background timing and fail-open checks. No global events posted.")

import AppKit

_ = NSApplication.shared
var checks = 0
func check(_ condition:@autoclosure ()->Bool,_ message:String) { guard condition() else { fatalError(message) }; checks += 1 }
func near(_ a:Double,_ b:Double,_ tolerance:Double=0.000001)->Bool { abs(a-b)<=tolerance }
// Verify total displacement on different clocks, including jitter and long gaps.
for hz in [30.0,60,90,120,144] {
    for distance in [-118.75,-36.0,0.25,36,157.75] {
        var path = ScrollTrajectory(); path.append(distance,at:0,duration:0.18)
        var sum = 0.0, previous = 0.0
        for f in 0...Int(hz) {
            let v = path.advance(to:Double(f)/hz); sum += v
            check(v.sign == distance.sign || v==0,"trajectory cannot reverse a same-direction input")
            check(abs(sum)>=abs(previous),"cumulative displacement is monotone"); previous = sum
        }
        check(near(sum,distance) && !path.pending,"trajectory conserves total distance independent of display refresh")
    }
}
var jitter = ScrollTrajectory(); jitter.append(73.25,at:1,duration:0.2)
let sum = [0.0,1.002,1.019,1.018,1.09,1.21,2.4].reduce(0) { $0+jitter.advance(to:$1) }
check(near(sum,73.25),"stale timestamps and dropped frames cannot add or undo distance")
var reverse = ScrollTrajectory(); reverse.append(100,at:0,duration:0.2); let initial = reverse.advance(to:0.05)
reverse.append(-36,at:0.05,duration:0.2)
check(near(reverse.advance(to:1),-36) && initial>0,"reversal discards old undelivered motion")
var burst = ScrollTrajectory()
for i in 0..<5000 { burst.append(0.1,at:Double(i)*0.0011,duration:0.18) }
check(burst.count<=512 && near(burst.advance(to:8),500),"high report rates use bounded memory while conserving distance")
var bad = ScrollTrajectory(); bad.append(.nan,at:0,duration:1); bad.append(5,at:0,duration:0)
check(!bad.pending && bad.advance(to:.infinity)==0,"invalid input is ignored")
var tuning = ScrollTuning(); tuning.pixelsPerStep = .nan; tuning.transitionMilliseconds = -3; tuning.boostMultiplier = .infinity
tuning = tuning.sanitized(); check(tuning.pixelsPerStep==36 && tuning.transitionMilliseconds==40 && tuning.boostMultiplier==2.5,"settings reject invalid numbers")
var settings = SmoothScrollSettings(); settings.applications = [ScrollApplication(bundleID:"app.one",name:"One",enabled:false),ScrollApplication(bundleID:"app.two",name:"Two",useGlobal:false)]
settings.applications[1].options.pixelsPerStep = 74
check(settings.tuning(for:"app.one")==nil && settings.tuning(for:"app.two")?.pixelsPerStep==74,"application disable and independent tuning")
settings.onlyListed = true; check(settings.tuning(for:"app.three")==nil,"only-listed mode")
let restoredSettings = try JSONDecoder().decode(SmoothScrollSettings.self,from:JSONEncoder().encode(settings))
check(restoredSettings==settings,"settings roundtrip")
let engine = SmoothScrollEngine(); engine.resolveApplication = { _ in "app.test" }
func wheel(_ y:Int32=1,_ x:Int32=0)->CGEvent { CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:2,wheel1:y,wheel2:x,wheel3:0)! }
var outputs:[CGEvent] = [], destinations:[pid_t] = []
engine.post = { event,pid in outputs.append(event); destinations.append(pid) }
check(engine.consume(wheel(),foregroundPID:321),"ordinary mouse input is captured")
let start = ProcessInfo.processInfo.systemUptime
for i in 1...40 { engine.tick(at:start+Double(i)/120) }
check(outputs.count>4 && outputs.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)})==36,"one line is delivered as exactly 36 pixels across native frames")
check(outputs.allSatisfy { !SmoothScrollEngine.isOrdinaryWheel($0) && $0.getIntegerValueField(.scrollWheelEventIsContinuous)==1 } && !engine.running,"synthetic output bypasses reprocessing and timer stops")
outputs.removeAll(); _ = engine.consume(wheel(),foregroundPID:321); _ = engine.consume(wheel(-1),foregroundPID:654); engine.tick(at:ProcessInfo.processInfo.systemUptime+1)
check(outputs.count==1 && outputs[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1)==(-36) && destinations.last==654,"foreground change cancels the old trajectory")
let native = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:80,wheel2:0,wheel3:0)!
check(!engine.consume(native,foregroundPID:321),"native trackpad/high-resolution continuous input retains its own timing")
var custom = SmoothScrollSettings(); custom.global.horizontalKey = ScrollTrigger(device:.modifier,code:Int(NSEvent.ModifierFlags.shift.rawValue),label:"⇧ Shift"); custom.global.reverseHorizontal = true
engine.configure(custom); outputs.removeAll(); let shifted = wheel(); shifted.flags = .maskShift
_ = engine.consume(shifted,foregroundPID:321); engine.tick(at:ProcessInfo.processInfo.systemUptime+1)
check(outputs.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)}) == -36 && outputs.allSatisfy {$0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)==0},"held conversion uses horizontal reversal")
engine.reset(); check(!engine.running,"reset ends in-flight scrolling")
// Control keys pause tails and keep unrelated axis payloads intact.
custom = SmoothScrollSettings(); custom.global.bypassKey = ScrollTrigger.choices[1]
engine.configure(custom); outputs.removeAll(); _ = engine.consume(wheel(),foregroundPID:321)
let option = CGEvent(keyboardEventSource:nil,virtualKey:58,keyDown:true)!; option.type = .flagsChanged; option.flags = .maskAlternate
engine.observe(.flagsChanged,option)
check(!engine.running,"pressing bypass cancels the existing tail immediately")
let blocked = wheel(); blocked.flags = .maskAlternate
check(!engine.consume(blocked,foregroundPID:321),"bypass preserves original input when no transformation is requested")
custom = SmoothScrollSettings(); custom.global.smoothHorizontal = false
engine.configure(custom); engine.releaseKeys(); outputs.removeAll(); _ = engine.consume(wheel(1,2),foregroundPID:321); engine.tick(at:ProcessInfo.processInfo.systemUptime+1)
check(outputs.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)})==36 && outputs.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)})==20,"an unsmoothed axis retains ordinary line-to-pixel distance")
custom.global.boostKey = ScrollTrigger.choices[4]; custom.global.boostMultiplier = 3
engine.configure(custom); outputs.removeAll(); let boosted = wheel(); boosted.flags = .maskCommand
_ = engine.consume(boosted,foregroundPID:321); engine.tick(at:ProcessInfo.processInfo.systemUptime+1)
check(outputs.reduce(Int64(0),{$0+$1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)})==108,"boost applies only while its key is held")
engine.reset()
// Native AppKit receiver: test real scrolling behavior, not a painted test meter.
let view = NSScrollView(frame:NSRect(x:0,y:0,width:400,height:200)); view.documentView = NSView(frame:NSRect(x:0,y:0,width:400,height:2000))
let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false); window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = view; window.orderFront(nil)
view.contentView.scroll(to:NSPoint(x:0,y:500)); view.reflectScrolledClipView(view.contentView)
let origin = view.contentView.bounds.origin.y
outputs.removeAll(); engine.configure(SmoothScrollSettings()); engine.post = { event,_ in outputs.append(event); view.scrollWheel(with:NSEvent(cgEvent:event)!) }
_ = engine.consume(wheel(),foregroundPID:321)
let deadline = Date(timeIntervalSinceNow:2)
while engine.running && Date()<deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005)) }
check(!engine.running && outputs.count>3 && abs(view.contentView.bounds.origin.y-origin)>30,"finite native wheel frames scroll an actual NSScrollView")
window.orderOut(nil)
print("PASS: \(checks) independent trajectory, profiles, event isolation, target routing and native AppKit scroll checks")

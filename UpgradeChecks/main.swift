import AppKit

_ = NSApplication.shared
var checks = 0
func check(_ test: @autoclosure () -> Bool, _ message: String) { guard test() else { fputs("FAIL: \(message)\n", stderr); exit(1) }; checks += 1 }
func wait(_ condition: () -> Bool, seconds: Double = 3) {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition() && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
    check(condition(), "async operation completed")
}
func wheel(_ pixels: Int32 = 28) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: pixels, wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixels)); return event
}
let ramp = ColorRamp(red:[0,0.2,0.5,1],green:[0,0.3,0.7,1],blue:[0,0.2,0.8,1])
check(ramp.scaled(0).maximum == 0 && !ramp.scaled(1).differs(from:ramp), "color table reaches mathematical black and restores the baseline")
check(!ramp.scaled(0.5).differs(from:ramp.scaled(0.5)), "each dimming target derives from baseline without cumulative multiplication")
let policy = BrightnessSettings()
for step in 0...100 {
    let v = Double(step)/100, c = policy.components(v)
    check(abs(policy.combined(hardware:c.hardware,color:c.color)-v)<0.000001, "combined brightness maps monotonically over 0–100")
    check(c.hardware >= 0 && c.hardware <= 1 && c.color >= 0 && c.color <= 1, "components stay bounded")
}
check(policy.components(0.5).hardware == 0 && policy.components(0.5).color == 1, "hardware minimum maps to the continuous join at 50%")
check(policy.components(0).color == 0, "0% actually requests a black color table")
final class SlowBrightness: BrightnessIO {
    let lock = NSLock()
    var values: [UInt32:Double] = [3:0.5,1:0.8]
    private var recorded: [(UInt32,Double)] = []
    var writes: [(UInt32,Double)] { lock.lock(); defer {lock.unlock()}; return recorded }
    func read(display: HardwareDisplay, settings: BrightnessSettings) throws -> ControlValue { lock.lock(); defer {lock.unlock()}; return ControlValue(value: values[display.id] ?? 0.5) }
    func write(display: HardwareDisplay, value: Double, settings: BrightnessSettings) throws -> ControlValue {
        lock.lock(); recorded.append((display.id,value)); lock.unlock()
        Thread.sleep(forTimeInterval: 0.18)
        lock.lock(); values[display.id] = value; lock.unlock()
        return ControlValue(value:value)
    }
    func restoreDimming(blackOnly: Bool) {}
}
let slow = SlowBrightness(), controls = AsyncControls(audio:AudioController(),brightness:slow,preview:false)
controls.configure(display:HardwareDisplay(id:3,name:"test"))
controls.request(.brightness,force:true); wait { controls.cache[.brightness]?.value == 0.5 }
controls.adjust(.brightness,delta:-0.1); wait { slow.writes.count == 1 }
controls.adjust(.brightness,delta:-0.1); controls.adjust(.brightness,delta:-0.1); controls.adjust(.brightness,delta:0.1)
let desired = 0.3
var staleAcknowledgementOverwrote = false
let end = Date(timeIntervalSinceNow:0.65)
while Date() < end {
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))
    if abs((controls.cache[.brightness]?.value ?? -1)-desired)>0.00001 { staleAcknowledgementOverwrote = true }
}
check(!staleAcknowledgementOverwrote, "slow old hardware replies never overwrite the latest wheel target")
check(slow.writes.count == 2 && abs(slow.writes[0].1-0.4)<0.00001 && abs(slow.writes[1].1-0.3)<0.00001, "brightness writes coalesce to absolute latest targets")
for _ in 0..<10 { controls.adjust(.brightness,delta:-0.1) }; controls.adjust(.brightness,delta:0.1)
wait { slow.writes.count == 3 }
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.23))
check(abs((controls.cache[.brightness]?.value ?? -1)-0.1)<0.00001 && abs(slow.writes.last!.1-0.1)<0.00001, "saturation followed by reversal preserves the immediate positive step")
controls.adjust(.brightness,delta:0.1); wait { slow.writes.count == 4 }
controls.configure(display:HardwareDisplay(id:1,name:"second")); controls.request(.brightness,force:true)
wait { controls.cache[.brightness]?.value == 0.8 }
check(slow.writes.allSatisfy {$0.0 == 3}, "old display's delayed write cannot leak into the new display")
let model = Configuration(), restored = try! JSONDecoder().decode(Configuration.self,from:JSONEncoder().encode(model))
check(restored.smoothScroll == model.smoothScroll && restored.brightnessControl == model.brightnessControl, "Scrolling/brightness policy persist without replacing ring/zoom calibration")
print("PASS: \(checks) combined brightness, async ordering and migration checks; no global input or live brightness writes.")


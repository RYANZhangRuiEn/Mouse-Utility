import AppKit
import QuartzCore

/// Owns ordinary wheel input only. Ring control, calibration and held gestures
/// are routed before this engine by MouseInputController.
final class SmoothScrollEngine: NSObject {
    var post: ((CGEvent,pid_t)->Void)?
    var resolveApplication: (pid_t)->String? = { NSRunningApplication(processIdentifier:$0)?.bundleIdentifier }
    private var settings = SmoothScrollSettings()
    private var vertical = ScrollTrajectory(), horizontal = ScrollTrajectory()
    private var keys = Set<Int>(), buttons = Set<Int>()
    private var displayLink: CADisplayLink?
    private var fallback: Timer?
    private var target: pid_t = 0
    private var location = CGPoint.zero
    private var flags = CGEventFlags()
    private var remainderX = 0.0, remainderY = 0.0
    private(set) var running = false
    func configure(_ value: SmoothScrollSettings) {
        let clean = value.sanitized()
        if clean != settings { reset(); releaseKeys() }
        settings = clean
    }
    func observe(_ type: CGEventType,_ event: CGEvent) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown: keys.insert(code)
        case .keyUp: keys.remove(code)
        case .otherMouseDown: buttons.insert(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .otherMouseUp: buttons.remove(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .leftMouseDown,.rightMouseDown: reset()
        default: break
        }
        flags = event.flags
        if target > 0, let tuning = settings.tuning(for:resolveApplication(target)), tuning.bypassKey.matches(keys:keys,buttons:buttons,flags:flags) { reset() }
    }
    func releaseKeys() { keys.removeAll(); buttons.removeAll(); flags = [] }
    static func isOrdinaryWheel(_ event: CGEvent) -> Bool {
        // Native trackpad gestures and already smoothed input keep their own timing.
        event.type == .scrollWheel && event.getIntegerValueField(.eventSourceUserData) != MouseEvents.sentinel &&
        event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 &&
        event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0 && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
    }
    @discardableResult func consume(_ event: CGEvent,foregroundPID: pid_t) -> Bool {
        guard Self.isOrdinaryWheel(event), foregroundPID>0,
              let tuning = settings.tuning(for:resolveApplication(foregroundPID)) else { return false }
        if target != foregroundPID { reset() }
        flags = event.flags
        func held(_ key: ScrollTrigger)->Bool { key.matches(keys:keys,buttons:buttons,flags:flags) }
        let bypass = held(tuning.bypassKey), convert = held(tuning.horizontalKey)
        if bypass { reset() }
        let boost = held(tuning.boostKey) ? tuning.boostMultiplier:1
        var y = Self.input(event,axis:1), x = Self.input(event,axis:2)
        guard x != 0 || y != 0 else { return false }
        if convert { x += y; y = 0 }
        let transformed = convert || tuning.reverseVertical || tuning.reverseHorizontal || boost != 1
        let sy = tuning.smoothVertical && !bypass, sx = tuning.smoothHorizontal && !bypass
        guard transformed || (y != 0 && sy) || (x != 0 && sx) else { return false }
        location = event.location; target = foregroundPID
        let now = ProcessInfo.processInfo.systemUptime
        var directY = 0.0, directX = 0.0
        for (distance,smooth,reverse,isY) in [(y,sy,tuning.reverseVertical,true),(x,sx,tuning.reverseHorizontal,false)] {
            let amount = distance*(smooth ? tuning.pixelsPerStep:10)*boost*(reverse ? -1:1)
            if smooth {
                if isY { vertical.append(amount,at:now,duration:tuning.transitionMilliseconds/1000) }
                else { horizontal.append(amount,at:now,duration:tuning.transitionMilliseconds/1000) }
            } else if isY { directY = amount } else { directX = amount }
        }
        if directX != 0 || directY != 0 { send(x:directX,y:directY,finishing:false) }
        if vertical.pending || horizontal.pending { start() }
        return true
    }
    private static func input(_ event: CGEvent,axis: Int) -> Double {
        let lines = event.getDoubleValueField(axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1:.scrollWheelEventFixedPtDeltaAxis2)
        let integer = Double(event.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1:.scrollWheelEventDeltaAxis2))
        let v = lines != 0 ? lines:integer
        return v.isFinite ? clamp(v,-32,32):0
    }
    private func start() {
        guard !running else { return }; running = true
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(location,$0.frame,false) }) ?? NSScreen.main {
            let link = screen.displayLink(target:self,selector:#selector(frame(_:)))
            link.add(to:.main,forMode:.common); displayLink = link
        } else {
            let timer = Timer(timeInterval:1/120,target:self,selector:#selector(frame(_:)),userInfo:nil,repeats:true)
            RunLoop.main.add(timer,forMode:.common); fallback = timer
        }
    }
    @objc private func frame(_ sender: Any) { tick(at:ProcessInfo.processInfo.systemUptime) }
    func tick(at now: Double) {
        guard running else { return }
        let y = vertical.advance(to:now), x = horizontal.advance(to:now)
        let finished = !vertical.pending && !horizontal.pending
        send(x:x,y:y,finishing:finished)
        if finished { stopClock() }
    }
    private func send(x: Double,y: Double,finishing: Bool) {
        remainderX += x; remainderY += y
        // Continuous native scroll uses integer pixel deltas. Keep subpixels until
        // they cross a pixel boundary; round the final remainder exactly once.
        let px = finishing ? remainderX.rounded():remainderX.rounded(.towardZero)
        let py = finishing ? remainderY.rounded():remainderY.rounded(.towardZero)
        guard px != 0 || py != 0 else { return }
        remainderX -= px; remainderY -= py
        guard let event = CGEvent(scrollWheelEvent2Source:CGEventSource(stateID:.privateState),units:.pixel,wheelCount:2,wheel1:Int32(py),wheel2:Int32(px),wheel3:0) else { return }
        event.location = location; event.flags = flags
        event.setIntegerValueField(.eventSourceUserData,value:MouseEvents.sentinel)
        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,value:Int64(py)); event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,value:Int64(px))
        post?(event,target)
    }
    private func stopClock() { displayLink?.invalidate(); displayLink = nil; fallback?.invalidate(); fallback = nil; running = false }
    func reset() { stopClock(); vertical.reset(); horizontal.reset(); remainderX = 0; remainderY = 0; target = 0 }
    deinit { displayLink?.invalidate(); fallback?.invalidate() }
}

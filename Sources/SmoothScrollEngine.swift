import AppKit
import QuartzCore

/// Owns ordinary wheel input only. Ring control, calibration and held gestures
/// are routed before this engine by MouseInputController.
final class SmoothScrollEngine: NSObject {
    var post: ((CGEvent,pid_t)->Void)?
    var resolveApplication:(pid_t)->String? = { pid in
        guard pid>1,let app = NSRunningApplication(processIdentifier:pid),!app.isTerminated else { return nil }
        return app.bundleIdentifier ?? app.executableURL?.path
    }
    var mayPost:()->Bool = { true }
    var useDisplayClock = true
    private var convertedInput = false
    private var settings = SmoothScrollSettings()
    private var vertical = ScrollTrajectory(), horizontal = ScrollTrajectory()
    private var keys = Set<Int>(), buttons = Set<Int>()
    private var reference:CGEvent?
    private var activity:NSObjectProtocol?
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
    static func isOrdinaryWheel(_ event:CGEvent) -> Bool {
        guard event.type == .scrollWheel else { return false }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == MouseEvents.sentinel || marker == MouseEvents.externalSmoothingMarker { return false }
        if marker == MouseEvents.heldHorizontalMarker { return true }
        let phased = event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0 || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 || event.getIntegerValueField(.scrollWheelEventScrollCount) != 0
        if !phased && event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 { return true }
        // Logitech's mouse daemon may label physical high-resolution wheel input as continuous.
        // Other continuous input, including native trackpad and remote sessions, keeps its timing.
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        return pid>1 && NSRunningApplication(processIdentifier:pid)?.bundleIdentifier == "com.logitech.manager.daemon"
    }
    @discardableResult func consume(_ event: CGEvent,foregroundPID: pid_t,preserveOriginal:Bool = false) -> Bool {
        guard Self.isOrdinaryWheel(event),mayPost() else { return false }
        let annotated = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let destination = annotated>1 ? annotated:foregroundPID
        guard destination>1,let application = resolveApplication(destination),let tuning = settings.tuning(for:application) else { return false }
        let converted = event.getIntegerValueField(.eventSourceUserData) == MouseEvents.heldHorizontalMarker
        if target != destination || converted != convertedInput { reset() }
        convertedInput = converted
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
        if preserveOriginal && !(sy && y != 0) && !(sx && x != 0) {
            reset()
            ScrollOutput.transformInPlace(event,vertical:boost*(tuning.reverseVertical ? -1:1),horizontal:boost*(tuning.reverseHorizontal ? -1:1),convert:convert)
            return false // The native event itself is the result; no suppress-and-repost gap.
        }
        guard post != nil else { return false }
        reference = event.copy()
        guard reference != nil else { return false }
        location = event.location; target = destination
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
        let points = event.getDoubleValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1:.scrollWheelEventPointDeltaAxis2)
        let v = lines != 0 ? lines:integer != 0 ? integer:points/10
        return v.isFinite ? clamp(v,-32,32):0
    }
    private func start() {
        guard !running else { return }; running = true
        guard useDisplayClock else { return }
        // A background mouse utility cannot depend on visible-window redraw callbacks.
        // This finite timer exists only while a trajectory is pending.
        activity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"完成滚轮平滑")
        let timer = Timer(timeInterval:1/120,repeats:true) { [weak self] _ in self?.tick(at:ProcessInfo.processInfo.systemUptime) }
        timer.tolerance = 0.001
        RunLoop.main.add(timer,forMode:.common); fallback = timer
    }
    @objc private func frame(_ sender: Any) { tick(at:ProcessInfo.processInfo.systemUptime) }
    func tick(at now: Double) {
        guard running else { return }
        guard mayPost(),post != nil else { reset(); return }
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
        guard let reference,let event = ScrollOutput.pixelFrame(reference:reference,x:Int32(px),y:Int32(py)) else { reset(); return }
        event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(target))
        post?(event,target)
    }
    private func stopClock() { fallback?.invalidate(); fallback = nil; if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil; running = false }
    func reset() { stopClock(); vertical.reset(); horizontal.reset(); remainderX = 0; remainderY = 0; target = 0; reference = nil; convertedInput = false }
    deinit { fallback?.invalidate(); if let activity { ProcessInfo.processInfo.endActivity(activity) } }
}

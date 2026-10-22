import AppKit

/// Log-scale interpolation keeps a wheel pulse smooth and stops its tail promptly on reversal.
struct ZoomInterpolation {
    private(set) var remaining = 0.0
    private var direction = 0.0
    var pending:Bool { abs(remaining) > 0.00001 }
    mutating func append(_ amount:Double) {
        guard amount.isFinite, amount != 0 else{return}
        let nextDirection = amount > 0 ? 1.0:-1.0
        if direction != 0, direction != nextDirection { remaining = 0 }
        direction = nextDirection
        remaining = clamp(remaining+amount,-4,4)
    }
    mutating func advance(seconds:Double) -> Double {
        guard pending, seconds.isFinite, seconds > 0 else { return 0 }
        let alpha = 1-exp(-min(seconds,0.05)/0.025)
        var step = clamp(remaining*alpha,-0.15,0.15)
        if abs(remaining-step) < 0.0001 { step = remaining }
        remaining -= step
        return expm1(step)
    }
    mutating func reset() { remaining = 0; direction = 0 }
}

enum MouseOutput {
    case action(String)
    case shortcut(KeyBinding)
    case events([CGEvent])
    case detected(Int)
    case level(DialAction,Double)
}

/// Event construction is separate from posting so conversion can be tested without touching other apps.
enum MouseEvents {
    static let sentinel: Int64 = 0x4F524249544D
    static let externalSmoothingMarker:Int64 = 0x4D4F53534D4F4F54
    // Converted physical wheel: skip button arbitration, then visit the smoothing tap exactly once.
    static let heldHorizontalMarker: Int64 = 0x4F5242484F52
    static func isRouted(_ event:CGEvent) -> Bool {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        return marker == sentinel || marker == heldHorizontalMarker
    }
    @discardableResult static func mark(_ event:CGEvent,as marker:Int64 = sentinel) -> CGEvent {
        event.setIntegerValueField(.eventSourceUserData,value:marker)
        // On macOS 27 an event with existing source data may ignore an overwrite.
        // Replacing its source snapshot updates the tag without rebuilding its native payload.
        if event.getIntegerValueField(.eventSourceUserData) != marker,
           let source = CGEventSource(event:event) ?? CGEventSource(stateID:.privateState) {
            source.userData = marker; event.setSource(source)
        }
        return event
    }
    // Gesture format verified against ScrollToZoom (MIT); see THIRD_PARTY_NOTICES.md.
    static func gesture(rotation: Bool, value: Double, phase: CGGesturePhase, at location: CGPoint, basedOn reference:CGEvent? = nil) -> CGEvent? {
        guard value.isFinite, let event = CGEvent(source:reference.flatMap { CGEventSource(event:$0) } ?? CGEventSource(stateID:.hidSystemState)),
              let type = CGEventType(rawValue:29), let kind = CGEventField(rawValue:110),
              let phaseField = CGEventField(rawValue:132), let amount = CGEventField(rawValue:rotation ? 114 : 113) else { return nil }
        event.type = type; event.location = location; event.flags = []; event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(kind,value:rotation ? 5 : 8)
        event.setIntegerValueField(phaseField,value:Int64(phase.rawValue))
        event.setDoubleValueField(amount,value:value)
        return mark(event)
    }
    static func horizontal(from original:CGEvent,reverse:Bool = false) -> CGEvent? {
        let sign = reverse ? -1.0:1.0
        let line = original.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = original.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = original.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let raw = original.getDoubleValueField(.scrollWheelEventRawDeltaAxis1)
        let accelerated = original.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1)
        let originalPrecise = original.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // Some reports carry only raw/fixed data; starting with a zero native payload loses them.
        let fallback = line == 0 && point == 0
        let precise = originalPrecise || line == 0
        let pixels = point != 0 ? Double(point):line != 0 ? Double(line)*10:fixed != 0 ? fixed*10:raw != 0 ? raw*10:accelerated
        let delta = (precise ? pixels:Double(line))*sign
        guard delta.isFinite else{return nil}
        var integral = Int32(clamp(delta,-1_000_000,1_000_000).rounded())
        if integral == 0,delta != 0 { integral = delta>0 ? 1:-1 }
        let source = CGEventSource(event:original) ?? CGEventSource(stateID:.hidSystemState)
        guard let event = CGEvent(scrollWheelEvent2Source:source,units:precise ? .pixel:.line,wheelCount:2,wheel1:0,wheel2:integral,wheel3:0) else{return nil}
        event.location = original.location; event.timestamp = original.timestamp; event.flags = []
        for (vertical,horizontal) in [(CGEventField.scrollWheelEventDeltaAxis1,CGEventField.scrollWheelEventDeltaAxis2),(.scrollWheelEventPointDeltaAxis1,.scrollWheelEventPointDeltaAxis2)] {
            if !fallback { event.setIntegerValueField(horizontal,value:original.getIntegerValueField(vertical)*(reverse ? -1:1)) }
            event.setIntegerValueField(vertical,value:0)
        }
        for (vertical,horizontal) in [(CGEventField.scrollWheelEventFixedPtDeltaAxis1,CGEventField.scrollWheelEventFixedPtDeltaAxis2),(.scrollWheelEventRawDeltaAxis1,.scrollWheelEventRawDeltaAxis2),(.scrollWheelEventAcceleratedDeltaAxis1,.scrollWheelEventAcceleratedDeltaAxis2)] {
            if !fallback || horizontal != .scrollWheelEventFixedPtDeltaAxis2 { event.setDoubleValueField(horizontal,value:original.getDoubleValueField(vertical)*sign) }
            event.setDoubleValueField(vertical,value:0)
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:precise ? 1:0)
        for field:CGEventField in [.scrollWheelEventScrollPhase,.scrollWheelEventMomentumPhase,.scrollWheelEventScrollCount,CGEventField(rawValue:137)!] { event.setIntegerValueField(field,value:original.getIntegerValueField(field)) }
        return mark(event,as:heldHorizontalMarker)
    }
    static func vertical(from original:CGEvent) -> CGEvent? {
        guard let event = original.copy() else{return nil}
        for (vertical,horizontal) in [(CGEventField.scrollWheelEventDeltaAxis1,CGEventField.scrollWheelEventDeltaAxis2),(.scrollWheelEventPointDeltaAxis1,.scrollWheelEventPointDeltaAxis2)] {
            event.setIntegerValueField(vertical,value:original.getIntegerValueField(horizontal)); event.setIntegerValueField(horizontal,value:0)
        }
        for (vertical,horizontal) in [(CGEventField.scrollWheelEventFixedPtDeltaAxis1,CGEventField.scrollWheelEventFixedPtDeltaAxis2),(.scrollWheelEventRawDeltaAxis1,.scrollWheelEventRawDeltaAxis2),(.scrollWheelEventAcceleratedDeltaAxis1,.scrollWheelEventAcceleratedDeltaAxis2)] {
            event.setDoubleValueField(vertical,value:original.getDoubleValueField(horizontal)); event.setDoubleValueField(horizontal,value:0)
        }
        return event
    }
    static func pan(dx:Double,dy:Double,phase:CGScrollPhase,at point:CGPoint) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source:CGEventSource(stateID:.privateState),units:.pixel,wheelCount:2,
                                  wheel1:Int32(clamp(dy,-1000,1000).rounded()),wheel2:Int32(clamp(dx,-1000,1000).rounded()),wheel3:0) else { return nil }
        event.location = point; event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase,value:Int64(phase.rawValue))
        return mark(event)
    }
    static func physicalDelta(_ event:CGEvent, horizontal:Bool = false) -> Double {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var value = event.getDoubleValueField(continuous ? (horizontal ? .scrollWheelEventPointDeltaAxis2:.scrollWheelEventPointDeltaAxis1)
                                                        : (horizontal ? .scrollWheelEventDeltaAxis2:.scrollWheelEventDeltaAxis1))
        if continuous, value == 0 {
            let fixed = event.getDoubleValueField(horizontal ? .scrollWheelEventFixedPtDeltaAxis2:.scrollWheelEventFixedPtDeltaAxis1)
            let line = event.getDoubleValueField(horizontal ? .scrollWheelEventDeltaAxis2:.scrollWheelEventDeltaAxis1)
            value = fixed != 0 ? fixed:line*10
        }
        if let field = CGEventField(rawValue:137), event.getIntegerValueField(field) != 0 { value = -value }
        return value.isFinite ? value : 0
    }
}

/// Stateful click/hold arbitration; consumes only configured combinations and preserves ordinary clicks.
final class MouseRouter {
    struct Press {
        var down: CGEvent
        var click: String
        var wheel: HeldWheelAction
        var move: HeldMoveAction
        var reverseMove = false
        var reverseWheel = false
        var used = false
        var navigationFired = false
        var dx = 0.0, dy = 0.0
        var order: UInt64
    }
    var output: ((MouseOutput)->Void)?
    var onWheelMotion: ((WheelMotion)->Void)?
    private(set) var presses: [Int:Press] = [:]
    private var sequence: UInt64 = 0
    private var gestureRotation: Bool?
    var applicationID = ""
    private var gestureReference:CGEvent?
    private var startupGesture:DispatchWorkItem?
    private var gesturePoint = CGPoint.zero
    private var zoomInterpolation = ZoomInterpolation()
    private var zoomTimer:DispatchSourceTimer?
    private var frameInterval = 1.0/60
    private var lastFrame = 0.0
    private var endAfterDrain = false
    private var panPoint: CGPoint?
    private var idle: DispatchWorkItem?
    private var desktopSteps = DesktopSteps()
    private var desktopTask:DispatchWorkItem?
    private var heldWheel = WheelInterpreter()
    private var heldLevels = LevelWheelInterpreter()
    private var wheelContext = ""
    private var sideTime = -Double.infinity, sideInputTime = 0.0, sideRemainder = 0.0
    private var suppressMomentumUntil = 0.0
    private var detectingButton: Int?
    private var suppressedReleases = Set<Int>()
    var detecting = false
    private(set) var forwardedScrollToSmoother = false
    func reset() {
        suppressedReleases.formUnion(presses.keys)
        if let detectingButton { suppressedReleases.insert(detectingButton) }
        finishGesture(); presses.removeAll(); detecting = false; detectingButton = nil
        desktopTask?.cancel(); desktopTask = nil; desktopSteps.reset(); heldWheel.reset(); heldLevels.reset(); wheelContext = ""; sideTime = -.infinity; sideInputTime = 0; sideRemainder = 0
    }
    private func emit(_ events:[CGEvent?]) { let ready = events.compactMap { $0 }; if !ready.isEmpty { output?(.events(ready)) } }
    func finishGesture() {
        idle?.cancel(); idle = nil
        startupGesture?.cancel(); startupGesture = nil
        zoomTimer?.cancel(); zoomTimer = nil; zoomInterpolation.reset(); endAfterDrain = false
        if let rotation = gestureRotation { emit([MouseEvents.gesture(rotation:rotation,value:0,phase:.ended,at:gesturePoint,basedOn:gestureReference)]) }
        if let panPoint { emit([MouseEvents.pan(dx:0,dy:0,phase:.ended,at:panPoint)]) }
        gestureRotation = nil; panPoint = nil
    }
    private func armEnd() {
        idle?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.requestGestureEnd() }
        idle = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:task)
    }
    private func requestGestureEnd() {
        if gestureRotation == false, zoomInterpolation.pending {
            endAfterDrain = true
        } else { finishGesture() }
    }
    private func gesture(rotation:Bool,value:Double,at point:CGPoint) {
        if gestureRotation != rotation {
            finishGesture(); gestureRotation = rotation; gesturePoint = point
            let screenPoint = NSPoint(x:point.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-point.y)
            let fps = NSScreen.screens.first { $0.frame.contains(screenPoint) }?.maximumFramesPerSecond ?? 60
            frameInterval = 1/Double(min(120,max(60,fps)))
            emit([MouseEvents.gesture(rotation:rotation,value:0,phase:.began,at:point,basedOn:gestureReference)])
        }
        if !rotation,zoomTimer == nil,gestureRotation == false,["com.google.Chrome","com.google.Chrome.beta","com.google.Chrome.canary","com.microsoft.edgemac","com.operasoftware.Opera"].contains(applicationID),startupGesture == nil {
            let shim = value>0 ? 0.4999:-0.3329
            let task = DispatchWorkItem { [weak self] in
                guard let self,self.gestureRotation == false else{return}
                self.emit([MouseEvents.gesture(rotation:false,value:shim,phase:.changed,at:self.gesturePoint,basedOn:self.gestureReference)])
            }
            startupGesture = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.008,execute:task)
        }
        if rotation { emit([MouseEvents.gesture(rotation:true,value:value,phase:.changed,at:gesturePoint,basedOn:gestureReference)]) }
        else {
            endAfterDrain = false; zoomInterpolation.append(value)
            if zoomTimer == nil {
                lastFrame = ProcessInfo.processInfo.systemUptime
                let timer = DispatchSource.makeTimerSource(queue:.main)
                timer.schedule(deadline:.now()+max(frameInterval,1.0/60),repeating:frameInterval,leeway:.milliseconds(1))
                timer.setEventHandler { [weak self] in
                    guard let self else{return}
                    let now = ProcessInfo.processInfo.systemUptime
                    self.tickZoom(seconds:now-self.lastFrame); self.lastFrame = now
                }
                zoomTimer = timer; timer.resume()
            }
        }
        armEnd()
    }
    private func tickZoom(seconds:Double) {
        let delta = zoomInterpolation.advance(seconds:seconds)
        if delta != 0 { emit([MouseEvents.gesture(rotation:false,value:delta,phase:.changed,at:gesturePoint,basedOn:gestureReference)]) }
        if !zoomInterpolation.pending {
            zoomTimer?.cancel(); zoomTimer = nil
            if endAfterDrain { finishGesture() }
        }
    }
    func testZoomPulse(at point:CGPoint) { gesture(rotation:false,value:0.18,at:point) }
    private func sendSpace(_ step:Int) {
        let left = step>0
        output?(.shortcut(KeyBinding(name:"",keyCode:left ? 123:124,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:left ? "←":"→")))
    }
    private func armDesktop() {
        desktopTask?.cancel(); desktopTask = nil
        guard desktopSteps.pending != 0 else{return}
        let task = DispatchWorkItem { [weak self] in
            guard let self else{return}
            if let step = self.desktopSteps.advance(time:ProcessInfo.processInfo.systemUptime) { self.sendSpace(step) }
            self.armDesktop()
        }
        desktopTask = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.33,execute:task)
    }
    private func spaces(steps:Int,time:Double,reverse:Bool) {
        if let step = desktopSteps.append(steps*(reverse ? -1:1),time:time) { sendSpace(step) }
        armDesktop()
    }
    private func legacySideWheel(delta:Double,time:Double,continuous:Bool,reverse:Bool) {
        let amount = delta*(reverse ? -1:1)
        if time-sideInputTime>0.35 || amount*sideRemainder<0 { sideRemainder = 0 }
        sideInputTime = time; sideRemainder += amount/(continuous ? 10:1)
        guard abs(sideRemainder)>=1,time-sideTime>=0.35 else{return}
        sendSpace(sideRemainder>0 ? 1:-1); sideTime = time; sideRemainder = 0
    }
    /// true means the original event has been consumed. All replayed events carry a loop-prevention marker.
    func handle(_ type:CGEventType,_ event:CGEvent,config:Configuration,bypass:Bool = false,time:Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        forwardedScrollToSmoother = false
        guard !MouseEvents.isRouted(event) else { return false }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .otherMouseUp, suppressedReleases.remove(button) != nil { return true }
        if type == .otherMouseDragged, suppressedReleases.contains(button) { return true }
        if type == .otherMouseDown { suppressedReleases.remove(button) }
        if detecting, type != .otherMouseDown && type != .otherMouseUp { return false }
        if type == .otherMouseUp, let detected = detectingButton, detected == button {
            detectingButton = nil; detecting = false; output?(.detected(button)); return true
        }
        if type == .otherMouseUp, let press = presses.removeValue(forKey:button) {
            heldWheel.reset(); heldLevels.reset(); wheelContext = ""
            requestGestureEnd()
            if !press.used && !bypass {
                if press.click == "custom", let key = config.mouseHabits.shortcuts[String(button)] { output?(.shortcut(key)) }
                else if press.click != "none" { output?(.action(press.click)) }
                else if let down = press.down.copy(), let up = event.copy() { output?(.events([MouseEvents.mark(down),MouseEvents.mark(up)])) }
            }
            return true
        }
        if bypass {
            if type == .otherMouseDown, config.mouseBindings[String(button)] == "showRing" {
                guard let down = event.copy() else { return false }
                sequence += 1; presses[button] = Press(down:down,click:"none",wheel:.none,move:.none,used:true,order:sequence)
                output?(.action("showRing")); return true
            }
            if !presses.isEmpty || gestureRotation != nil || panPoint != nil { reset() }
            return false
        }
        if type == .otherMouseDown, (2...31).contains(button) {
            if detecting { detectingButton = button; return true }
            let key = String(button), habits = config.mouseHabits
            let storedWheel = habits.wheel[key] ?? .none
            let wheel: HeldWheelAction = habits.enabled && storedWheel != .volume && storedWheel != .brightness ? storedWheel : .none
            let move = habits.enabled ? habits.move[key] ?? .none:.none
            let click = config.mouseBindings[key] ?? "none"
            guard click != "none" || wheel != .none || move != .none, let down = event.copy() else { return false }
            sequence += 1
            var press = Press(down:down,click:click,wheel:wheel,move:move,reverseMove:habits.reverseMove[key] ?? false,reverseWheel:habits.reverseWheel[key] ?? false,order:sequence)
            if wheel == .none, move == .none, click != "custom" { output?(.action(click)); press.used = true }
            presses[button] = press
            return true
        }
        if type == .otherMouseDragged, var press = presses[button] {
            let direction = press.reverseMove ? -1.0:1.0
            let dx = event.getDoubleValueField(.mouseEventDeltaX)*direction, dy = event.getDoubleValueField(.mouseEventDeltaY)*direction
            guard dx.isFinite,dy.isFinite else { return true }
            press.dx += dx; press.dy += dy
            switch press.move {
            case .none: break
            case .pan:
                if abs(press.dx)+abs(press.dy) >= 3 {
                    press.used = true
                    if panPoint == nil { finishGesture(); panPoint = press.down.location; emit([MouseEvents.pan(dx:0,dy:0,phase:.began,at:press.down.location)]) }
                    emit([MouseEvents.pan(dx:-dx,dy:-dy,phase:.changed,at:panPoint!)])
                }
            case .windows:
                if !press.navigationFired, max(abs(press.dx),abs(press.dy)) >= 45 {
                    let horizontal = abs(press.dx) > abs(press.dy)
                    let code:UInt16 = horizontal ? (press.dx < 0 ? 123:124):(press.dy < 0 ? 126:125)
                    output?(.shortcut(KeyBinding(name:"",keyCode:code,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"方向")))
                    press.used = true; press.navigationFired = true
                }
            }
            presses[button] = press
            // Preserve cursor movement for configured click/hold keys without exposing an unmatched drag.
            return true
        }
        guard config.mouseHabits.enabled else { return false }
        if type == .flagsChanged {
            let required = config.mouseHabits.zoomModifiers
            if required != 0, event.flags.rawValue & required != required { requestGestureEnd() }
            return false
        }
        guard type == .scrollWheel else { return false }
        let habits = config.mouseHabits
        let active = presses.filter { $0.value.wheel != .none }.max { $0.value.order < $1.value.order }
        let mode = active?.value.wheel ?? .none
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        if mode != .none {
            if let active { presses[active.key]?.used = true }
            if momentum { return true }
            let settings = habits.adaptation
            let context = (active.map { String($0.key) } ?? "keyboard")+mode.rawValue
            if context != wheelContext { heldWheel.reset(); heldLevels.reset(); wheelContext = context }
            let motion:WheelMotion
            if mode == .volume || mode == .brightness {
                motion = heldLevels.consume(WheelSample(event),profile:settings.levelProfile ?? settings.vertical,time:time)
            } else {
                motion = heldWheel.consume(WheelSample(event),profile:mode == .zoom ? (settings.zoomProfile ?? WheelProfile()):settings.vertical,time:time,expireAfterIdle:mode != .zoom)
            }
            let reverse = active?.value.reverseWheel ?? false
            let wheelSign = reverse ? -1.0:1.0
            onWheelMotion?(motion)
            suppressMomentumUntil = time+0.25
            switch mode {
            case .none: break
            case .horizontal:
                let converted = MouseEvents.horizontal(from:event,reverse:reverse)
                forwardedScrollToSmoother = converted != nil
                emit([converted])
            case .spaces: spaces(steps:motion.steps,time:time,reverse:habits.reverseSpaces != reverse)
            case .zoom:
                let sign = (habits.reverseZoom ? -1.0:1.0)*wheelSign
                let amount = settings.mode == .detent ? Double(motion.steps):motion.amount
                let gain = settings.appZoom[applicationID]?.gain ?? 1
                let value = amount*log1p(settings.zoomStep)*sign*gain
                if value != 0 { gestureReference = event.copy(); gesture(rotation:false,value:value,at:event.location) }

            case .rotate:
                let amount = settings.mode == .detent ? Double(motion.steps):motion.amount
                let value = clamp(amount*2*habits.sensitivity*wheelSign,-45,45)
                if value != 0 { gesture(rotation:true,value:value,at:event.location) }
            case .volume,.brightness:
                let amount = Double(motion.steps)*wheelSign
                _ = amount // Retired: levels are handled exclusively by RingView.
            }
            return true
        }
        if momentum, time < suppressMomentumUntil { return true }
        if habits.thumbSpaces {
            let x = MouseEvents.physicalDelta(event,horizontal:true), y = MouseEvents.physicalDelta(event)
            // High-resolution mouse wheels may be continuous too; actual touchpad scrolling carries phases.
            let phased = event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            if !phased, abs(x) > abs(y), x != 0 {
                if !momentum { legacySideWheel(delta:x,time:time,continuous:event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,reverse:habits.reverseSpaces) }
                return true
            }
        }
        return false
    }
    deinit { zoomTimer?.cancel(); idle?.cancel(); startupGesture?.cancel(); desktopTask?.cancel() }
}


final class MouseInputController {
    static let eventTapLocation:CGEventTapLocation = .cgSessionEventTap
    let router = MouseRouter(), smoother = SmoothScrollEngine()
    private lazy var scrollTap = ScrollRoutingTap(engine:smoother)
    var foregroundPID:pid_t = 0
    var onAction:((String)->Void)?, onShortcut:((KeyBinding)->Void)?, onDetected:((Int)->Void)?
    var onLevel:((DialAction,Double)->Void)?
    var directScroll:((CGEvent)->Bool)?
    var localPractice:()->Bool = { false }
    var bypass:(CGEventType)->Bool = { _ in false }
    var bypassScrolling:(CGEvent)->Bool = { _ in false }
    var onStatus:((String)->Void)?
    private var tap:CFMachPort?, source:CFRunLoopSource?
    private var currentProxy:CGEventTapProxy?
    var postRoutedEvent:(CGEvent,CGEventTapProxy?)->Void = { event,proxy in
        if let proxy { event.tapPostEvent(proxy) } else { event.post(tap:.cgSessionEventTap) }
    }
    private var signature = Data(), lastStatus = -TimeInterval.infinity
    private var detectionRequested = false, detectionTimeout:DispatchWorkItem?
    private var externallySmoothed = false
    private var observedWheelMode:MasterWheelMode?
    private(set) var activeWheelMode:MasterWheelMode = .ratchet
    var config = Configuration()
    init() {
        smoother.mayPost = { InputSender.trusted }
        smoother.post = { event,pid in if !RecorderButton.isCapturing { event.post(tap:.cgSessionEventTap) } }
        scrollTap.bypass = { [weak self] event in self?.bypassScrolling(event) ?? true }
        router.output = { [weak self] output in
            guard let self else { return }
            switch output {
            case .action(let raw):self.onAction?(raw)
            case .shortcut(let key):self.onShortcut?(key)
            case .level(let kind,let delta):self.onLevel?(kind,delta)
            case .events(let events):events.forEach { self.postRoutedEvent($0,self.currentProxy) }
            case .detected(let number):
                self.detectionTimeout?.cancel(); self.detectionRequested = false
                DispatchQueue.main.async { self.onDetected?(number); _ = self.configure(self.config,force:true) }
            }
        }
    }
    func setWheelMode(_ mode:MasterWheelMode?) {
        observedWheelMode = mode
        let mode = config.wheelProfileSelection.resolve(observedWheelMode)
        guard mode != activeWheelMode else { return }; activeWheelMode = mode
        smoother.configure(config.scrolling(for:mode)); if tap != nil { _ = updateScrollTap() }
    }
    private var required:Bool { config.mouseHabits.enabled || config.mouseBindings.values.contains { $0 != "none" } || detectionRequested || config.needsSmoothListening }
    private func updateScrollTap() -> Bool {
        guard !externallySmoothed,config.scrolling(for:activeWheelMode).needsListening else { scrollTap.stop(); return true }
        let success = scrollTap.start(); if !success { onStatus?("平滑监听未就绪 · 保留系统滚动") }; return success
    }
    @discardableResult func configure(_ config:Configuration,force:Bool = false) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let baseSignature = ((try? encoder.encode(config.mouseHabits)) ?? Data()) + ((try? encoder.encode(config.mouseBindings)) ?? Data()) + ((try? encoder.encode(config.smoothScroll)) ?? Data()) + ((try? encoder.encode(config.freeWheelSmoothScroll)) ?? Data())
        let next = baseSignature + ((try? encoder.encode(config.wheelProfileSelection)) ?? Data())
        let changed = signature != next; signature = next; self.config = config
        externallySmoothed = NSRunningApplication.runningApplications(withBundleIdentifier:"com.caldis.Mos").contains { !$0.isTerminated }
        activeWheelMode = config.wheelProfileSelection.resolve(observedWheelMode)
        smoother.configure(config.scrolling(for:activeWheelMode))
        guard required else { stop(cancelDetection:false); return true }
        guard InputSender.trusted else { stop(cancelDetection:false); onStatus?("需要辅助功能授权，当前尚未监听"); return false }
        if !force,let tap,CGEvent.tapIsEnabled(tap:tap) { if changed { router.reset() }; return updateScrollTap() }
        stop(cancelDetection:false)
        let types:[CGEventType] = [.otherMouseDown,.otherMouseUp,.otherMouseDragged,.scrollWheel,.flagsChanged,.keyDown,.keyUp,.leftMouseDown,.rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1)<<$1.rawValue }
        let callback:CGEventTapCallBack = { proxy,type,event,context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MouseInputController>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.router.reset(); owner.smoother.reset()
                if InputSender.trusted,let tap = owner.tap { CGEvent.tapEnable(tap:tap,enable:true) }
                return Unmanaged.passUnretained(event)
            }
            return owner.handleInput(type,event,proxy:proxy) ? nil:Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap:Self.eventTapLocation,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:callback,userInfo:Unmanaged.passUnretained(self).toOpaque())
        if let tap { source = CFMachPortCreateRunLoopSource(nil,tap,0); CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes); CGEvent.tapEnable(tap:tap,enable:true) }
        router.detecting = detectionRequested
        onStatus?(tap == nil ? "鼠标监听未就绪":"鼠标监听已开启")
        return tap != nil && updateScrollTap()
    }
    @discardableResult func handleInput(_ type:CGEventType,_ event:CGEvent,proxy:CGEventTapProxy? = nil) -> Bool {
        currentProxy = proxy; defer { currentProxy = nil }
        guard !MouseEvents.isRouted(event),event.getIntegerValueField(.eventSourceUserData) != MouseEvents.externalSmoothingMarker else { return false }
        if type == .scrollWheel,!RecorderButton.isCapturing,directScroll?(event) == true { smoother.reset(); router.reset(); return true }
        if localPractice() { router.reset(); smoother.reset(); return false }
        let bypassed = bypass(type) && !router.detecting
        if RecorderButton.isCapturing { smoother.reset(); smoother.releaseKeys() } else { smoother.observe(type,event) }
        let used = router.handle(type,event,config:config,bypass:bypassed)
        if used && type == .scrollWheel && !router.forwardedScrollToSmoother { smoother.reset() }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .otherMouseDown { onStatus?("收到："+MouseButtonIdentity.name(Int(event.getIntegerValueField(.mouseEventButtonNumber)))) }
        else if type == .scrollWheel,now-lastStatus>0.3 { lastStatus = now; onStatus?(used ? "收到滚轮 · 已转换":"收到滚轮") }
        return used
    }
    @discardableResult func detect(timeout:@escaping ()->Void) -> Bool {
        guard InputSender.trusted else { return false }
        detectionTimeout?.cancel(); detectionRequested = true
        guard configure(config,force:true) else { detectionRequested = false; return false }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.detectionRequested = false; self.router.reset(); timeout(); _ = self.configure(self.config,force:true)
        }
        detectionTimeout = deadline; DispatchQueue.main.asyncAfter(deadline:.now()+8,execute:deadline); return true
    }
    func cancelDetection() { if detectionRequested { detectionRequested = false; _ = configure(config,force:true) } }
    func resetScrolling() { smoother.reset() }
    func refreshExternalApps() { refreshRuntimeState() }
    func refreshRuntimeState() {
        let other = NSRunningApplication.runningApplications(withBundleIdentifier:"com.caldis.Mos").contains { !$0.isTerminated }
        let lostGestureTap = tap.map { !CGEvent.tapIsEnabled(tap:$0) } ?? true
        let lostScrollTap = !other && config.scrolling(for:activeWheelMode).needsListening && !scrollTap.enabled
        if other != externallySmoothed || required && InputSender.trusted && (lostGestureTap || lostScrollTap) { _ = configure(config,force:true) }
    }
    func stop(cancelDetection:Bool = true) {
        if cancelDetection { detectionRequested = false }
        if !detectionRequested { detectionTimeout?.cancel(); detectionTimeout = nil }
        scrollTap.stop(); router.reset(); smoother.reset(); smoother.releaseKeys()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let tap { CFMachPortInvalidate(tap) }; source = nil; tap = nil
    }
    deinit { stop() }
}

import AppKit

/// The system assigns the actual target window before this stage. Gesture arbitration stays earlier.
final class ScrollRoutingTap {
    static let location:CGEventTapLocation = .cgAnnotatedSessionEventTap
    let engine:SmoothScrollEngine
    var bypass:(CGEvent)->Bool = { _ in false }
    private var port:CFMachPort?, source:CFRunLoopSource?
    var enabled:Bool { port.map { CGEvent.tapIsEnabled(tap:$0) } ?? false }
    init(engine:SmoothScrollEngine) { self.engine = engine }
    func start() -> Bool {
        if enabled { return true }; stop()
        let callback:CGEventTapCallBack = { _,type,event,context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ScrollRoutingTap>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.engine.reset()
                if InputSender.trusted,let port = owner.port { CGEvent.tapEnable(tap:port,enable:true) }
                return Unmanaged.passUnretained(event)
            }
            return owner.handle(event) ? nil:Unmanaged.passUnretained(event)
        }
        port = CGEvent.tapCreate(tap:Self.location,place:.tailAppendEventTap,options:.defaultTap,eventsOfInterest:CGEventMask(1)<<CGEventType.scrollWheel.rawValue,callback:callback,userInfo:Unmanaged.passUnretained(self).toOpaque())
        if let port { source = CFMachPortCreateRunLoopSource(nil,port,0); CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes); CGEvent.tapEnable(tap:port,enable:true) }
        return enabled
    }
    func handle(_ event:CGEvent) -> Bool {
        guard SmoothScrollEngine.isOrdinaryWheel(event) else { return false }
        let converted = event.getIntegerValueField(.eventSourceUserData) == MouseEvents.heldHorizontalMarker
        defer { if converted { MouseEvents.mark(event) } }
        guard !RecorderButton.isCapturing,!bypass(event) else { engine.reset(); return false }
        return engine.consume(event,foregroundPID:0,preserveOriginal:true)
    }
    func stop() {
        engine.reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil; port = nil
    }
    deinit { stop() }
}
enum ScrollInteractionScope {
    static func bypass(targetPID:pid_t,ownPID:pid_t,recording:Bool,ring:Bool,practice:Bool,settings:Bool,applicationList:Bool,learningPage:Bool = false) -> Bool {
        if recording || ring { return true }
        guard targetPID == ownPID else { return false }
        return learningPage ? practice:practice || (settings && !applicationList)
    }
}

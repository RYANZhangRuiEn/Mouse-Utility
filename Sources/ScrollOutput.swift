import AppKit

/// Keeps the system's complete routing envelope, including fields the host does not interpret.
enum ScrollOutput {
    static let integerAxes:[(CGEventField,CGEventField)] = [(.scrollWheelEventDeltaAxis1,.scrollWheelEventDeltaAxis2),(.scrollWheelEventPointDeltaAxis1,.scrollWheelEventPointDeltaAxis2)]
    static let doubleAxes:[(CGEventField,CGEventField)] = [(.scrollWheelEventFixedPtDeltaAxis1,.scrollWheelEventFixedPtDeltaAxis2),(.scrollWheelEventRawDeltaAxis1,.scrollWheelEventRawDeltaAxis2),(.scrollWheelEventAcceleratedDeltaAxis1,.scrollWheelEventAcceleratedDeltaAxis2)]
    static func transformInPlace(_ event:CGEvent,vertical:Double,horizontal:Double,convert:Bool) {
        for (y,x) in integerAxes {
            let vy = Double(event.getIntegerValueField(y)),vx = Double(event.getIntegerValueField(x))
            event.setIntegerValueField(y,value:Int64((convert ? 0:vy*vertical).rounded()))
            event.setIntegerValueField(x,value:Int64(((convert ? vx+vy:vx)*horizontal).rounded()))
        }
        for (y,x) in doubleAxes {
            let vy = event.getDoubleValueField(y),vx = event.getDoubleValueField(x)
            event.setDoubleValueField(y,value:convert ? 0:vy*vertical)
            event.setDoubleValueField(x,value:(convert ? vx+vy:vx)*horizontal)
        }
    }
    static func pixelFrame(reference:CGEvent,x:Int32,y:Int32) -> CGEvent? {
        guard let event = reference.copy(),let source = CGEventSource(stateID:.hidSystemState),
              let payload = CGEvent(scrollWheelEvent2Source:source,units:.pixel,wheelCount:2,wheel1:y,wheel2:x,wheel3:0) else { return nil }
        source.localEventsSuppressionInterval = 0
        for (a,b) in integerAxes { for field in [a,b] { event.setIntegerValueField(field,value:payload.getIntegerValueField(field)) } }
        for (a,b) in doubleAxes { for field in [a,b] { event.setDoubleValueField(field,value:payload.getDoubleValueField(field)) } }
        for field:CGEventField in [.scrollWheelEventDeltaAxis3,.scrollWheelEventPointDeltaAxis3,.scrollWheelEventFixedPtDeltaAxis3] { event.setDoubleValueField(field,value:0) }
        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase,value:0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase,value:0)
        event.setIntegerValueField(.scrollWheelEventScrollCount,value:0)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        // Assign source only after copying the routing envelope; never suppress physical input.
        event.setSource(source); MouseEvents.mark(event)
        return event
    }
}

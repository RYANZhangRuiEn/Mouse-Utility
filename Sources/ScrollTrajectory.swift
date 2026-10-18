import Foundation

/// A finite displacement is spread over a quintic trajectory. The differences of
/// its cumulative integral sum to exactly the input distance at any frame rate.
/// No velocity feedback, peak detector, rolling filter or asymptotic dead zone.
struct ScrollTrajectory {
    private struct Pulse { var amount: Double; var start: Double; var duration: Double; var delivered: Double = 0 }
    private var pulses: [Pulse] = []
    var pending: Bool { !pulses.isEmpty }
    var count: Int { pulses.count }
    static func cumulative(_ unitTime: Double) -> Double {
        let u = min(1,max(0,unitTime))
        return u*u*u*(10+u*(-15+6*u))
    }
    mutating func append(_ distance: Double, at time: Double, duration: Double) {
        guard distance.isFinite, time.isFinite, duration.isFinite, duration > 0, distance != 0 else { return }
        // A reversal cancels the undelivered tail, rather than pulling against it.
        if let last = pulses.last, last.amount.sign != distance.sign { pulses.removeAll(keepingCapacity:true) }
        // Inputs within one millisecond share a pulse; preserve a bounded queue.
        if let i = pulses.indices.last, abs(pulses[i].start-time)<0.001, pulses[i].delivered == 0 {
            pulses[i].amount += distance
        } else {
            if pulses.count >= 512 {
                // Fold the remaining distance into a fresh trajectory; never drop it.
                let remainder = pulses.reduce(0) { $0+$1.amount-$1.delivered }
                pulses = [Pulse(amount:remainder+distance,start:time,duration:duration)]
            } else { pulses.append(Pulse(amount:distance,start:time,duration:duration)) }
        }
    }
    mutating func advance(to time: Double) -> Double {
        guard time.isFinite else { return 0 }
        var output = 0.0
        for i in pulses.indices {
            let progress = Self.cumulative((time-pulses[i].start)/pulses[i].duration)
            let target = pulses[i].amount*progress
            // A stale timestamp cannot undo already emitted displacement.
            if abs(target) >= abs(pulses[i].delivered) { output += target-pulses[i].delivered; pulses[i].delivered = target }
        }
        pulses.removeAll { time >= $0.start+$0.duration }
        return output
    }
    mutating func reset() { pulses.removeAll(keepingCapacity:true) }
}

import AppKit

enum WheelMode:String,Codable,CaseIterable {
    case balanced, detent, smooth
    var title:String {
        switch self {
        case .balanced:return "默认：连续缩放，调节按格"
        case .detent:return "齿格：一格一步"
        case .smooth:return "无极：连续调节"
        }
    }
}
struct WheelProfile:Codable,Equatable {
    var units:[String:Double] = [:]
    var samples = 0
    var variation = 0.0
    var source:String? = nil
    var learnedAt:Date? = nil
    var upNotches:Int? = nil, downNotches:Int? = nil
    var calibrated:Bool { !units.isEmpty && (samples >= 8 || ((upNotches ?? 0)>0 && (downNotches ?? 0)>0)) }
    func sanitized() -> Self {
        var result = self
        result.units = units.filter { ["raw","point","fixed","line"].contains($0.key) && $0.value.isFinite && $0.value >= 0.00001 && $0.value <= 1_000_000 }
        if let source,!result.units.keys.contains(source) { result.source = nil }
        result.samples = max(0,min(10000,samples)); result.variation = variation.isFinite ? clamp(variation):1
        return result
    }
}
struct WheelSettings:Codable,Equatable {
    var mode:WheelMode = .balanced
    var vertical = WheelProfile(), horizontal = WheelProfile()
    var zoomProfile:WheelProfile? = nil
    var levelProfile:WheelProfile? = nil
    var appZoom:[String:AppZoomCalibration] = [:]
    var zoomStep = 0.10
    var levelStep = 0.10
    init() {}
    private enum CodingKeys:String,CodingKey { case mode,vertical,horizontal,zoomProfile,levelProfile,appZoom,zoomStep,levelStep }
    init(from decoder:Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy:CodingKeys.self)
        mode = try c.decodeIfPresent(WheelMode.self,forKey:.mode) ?? .balanced
        vertical = try c.decodeIfPresent(WheelProfile.self,forKey:.vertical) ?? WheelProfile()
        horizontal = try c.decodeIfPresent(WheelProfile.self,forKey:.horizontal) ?? WheelProfile()
        zoomProfile = try c.decodeIfPresent(WheelProfile.self,forKey:.zoomProfile)
        levelProfile = try c.decodeIfPresent(WheelProfile.self,forKey:.levelProfile)
        appZoom = try c.decodeIfPresent([String:AppZoomCalibration].self,forKey:.appZoom) ?? [:]
        zoomStep = try c.decodeIfPresent(Double.self,forKey:.zoomStep) ?? 0.10
        levelStep = try c.decodeIfPresent(Double.self,forKey:.levelStep) ?? 0.10
        self = sanitized()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(zoomProfile ?? (vertical.calibrated ? vertical : nil), forKey: .zoomProfile)
        try c.encode(appZoom, forKey: .appZoom); try c.encode(zoomStep, forKey: .zoomStep)
    }
    func sanitized() -> Self {
        var result = self; result.vertical = vertical.sanitized(); result.horizontal = horizontal.sanitized()
        result.zoomProfile = zoomProfile?.sanitized()
        result.levelProfile = levelProfile?.sanitized()
        result.appZoom = appZoom.filter { $0.value.gain.isFinite && (0.05...10).contains($0.value.gain) }
        result.zoomStep = zoomStep.isFinite ? clamp(zoomStep,0.01,0.5):0.10
        result.levelStep = levelStep.isFinite ? clamp(levelStep,0.01,0.2):0.10
        return result
    }
}

/// Ring-only calibration. Never read by the outside mouse gesture router.
struct RingWheelSettings: Codable, Equatable {
    var profile = WheelProfile()
    var step = 0.10
    func sanitized() -> Self { Self(profile: profile.sanitized(), step: step.isFinite ? clamp(step, 0.01, 0.2) : 0.1) }
}

/// A single axis. Prefer the public raw delta over accelerated screen pixels when present.
struct WheelSample {
    var values:[String:Double]
    var precise:Bool
    var phased = false
    var momentum = false
    init(values:[String:Double],precise:Bool = false,phased:Bool = false,momentum:Bool = false) {
        self.values = values.filter { $0.value.isFinite && $0.value != 0 }
        self.precise = precise; self.phased = phased; self.momentum = momentum
    }
    init(_ event:CGEvent,horizontal:Bool = false) {
        let sign = event.getIntegerValueField(CGEventField(rawValue:137)!) != 0 ? -1.0:1.0
        var fields:[String:Double] = [:]
        fields["raw"] = event.getDoubleValueField(horizontal ? .scrollWheelEventRawDeltaAxis2:.scrollWheelEventRawDeltaAxis1)*sign
        fields["point"] = Double(event.getIntegerValueField(horizontal ? .scrollWheelEventPointDeltaAxis2:.scrollWheelEventPointDeltaAxis1))*sign
        fields["fixed"] = event.getDoubleValueField(horizontal ? .scrollWheelEventFixedPtDeltaAxis2:.scrollWheelEventFixedPtDeltaAxis1)*sign
        fields["line"] = Double(event.getIntegerValueField(horizontal ? .scrollWheelEventDeltaAxis2:.scrollWheelEventDeltaAxis1))*sign
        self.init(values:fields,precise:event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                  phased:event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0,momentum:event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0)
    }
    var order:[String] { precise ? ["raw","point","fixed","line"]:["raw","fixed","line","point"] }
    var nonzero:Bool { !values.isEmpty }
    func normalized(_ profile:WheelProfile) -> Double {
        if let source = profile.source,let unit = profile.units[source],unit>0 { return clamp((values[source] ?? 0)/unit,-64,64) }
        for key in order {
            if let value = values[key],let unit = profile.units[key],unit>0 { return clamp(value/unit,-64,64) }
        }
        for key in order {
            if let value = values[key] {
                let unit = key == "point" || (key == "fixed" && precise) ? 12.0:1.0
                return clamp(value/unit,-64,64)
            }
        }
        return 0
    }
}
struct WheelMotion {
    var amount:Double = 0
    var steps:Int = 0
}
/// Keeps fractional detents; no per-event rounding, so split reports and fast bursts conserve motion.
struct WheelInterpreter {
    private var remainder = 0.0, lastTime = -Double.infinity, direction = 0.0
    mutating func reset() { remainder = 0; lastTime = -.infinity; direction = 0 }
    mutating func consume(_ sample:WheelSample,profile:WheelProfile,time:Double,expireAfterIdle:Bool = true) -> WheelMotion {
        guard !sample.momentum else{return WheelMotion()}
        let amount = sample.normalized(profile)
        guard amount.isFinite,amount != 0 else{return WheelMotion()}
        let sign = amount>0 ? 1.0:-1.0
        if (expireAfterIdle && time-lastTime>0.6) || direction != sign { remainder = 0 }
        direction = sign; lastTime = time
        remainder += amount
        let steps = Int((abs(remainder)+0.000001).rounded(.down)) * (remainder>0 ? 1:-1)
        remainder -= Double(steps)
        return WheelMotion(amount:amount,steps:steps)
    }
}

/// Slow, isolated detents are bursts of reports. Medians reject acceleration and accidental multi-notch outliers.
struct WheelLearner {
    private(set) var samples:[[String:Double]] = []
    private(set) var reports = 0
    private var burst:[String:Double] = [:]
    private var lastTime = -Double.infinity
    mutating func reset() { self = WheelLearner() }
    mutating func record(_ sample:WheelSample,time:Double) {
        guard !sample.momentum,sample.nonzero else{return}
        if time-lastTime>0.22 { flush() }
        lastTime = time; reports += 1
        for (key,value) in sample.values { burst[key,default:0] += value }
    }
    mutating func idle(time:Double) { if time-lastTime>0.22 { flush() } }
    mutating func flush() {
        if !burst.isEmpty,samples.count<80 { samples.append(burst) }
        burst.removeAll()
    }
    var positive:Int { samples.filter { ($0["raw"] ?? $0["fixed"] ?? $0["point"] ?? $0["line"] ?? 0)>0 }.count }
    var negative:Int { samples.count-positive }
    private func median(_ values:[Double]) -> Double {
        let sorted = values.sorted(), count = sorted.count
        return count%2 == 0 ? (sorted[count/2-1]+sorted[count/2])/2:sorted[count/2]
    }
    var proposal:WheelProfile? {
        guard samples.count>=8,positive>=4,negative>=4 else{return nil}
        var units:[String:Double] = [:], variations:[String:Double] = [:]
        for key in ["raw","point","fixed","line"] {
            let values = samples.compactMap { $0[key].map(abs) }.filter { $0>0.00001 }
            guard values.count*5>=samples.count*4 else{continue}
            let middle = median(values), spread = median(values.map { abs($0-middle) })/middle
            // At least 75% must represent the same isolated detent, including both directions.
            let stable = values.filter { abs($0-middle)/middle <= 0.25 }.count
            guard spread<=0.2,stable*4>=values.count*3 else{continue}
            units[key] = middle; variations[key] = spread
        }
        guard let best = ["raw","point","fixed","line"].first(where:{units[$0] != nil}) else{return nil}
        return WheelProfile(units:units,samples:samples.count,variation:variations[best] ?? 0)
    }
}

/// Desktop animations require spacing. Retain detents instead of losing them to a cooldown.
struct DesktopSteps {
    private(set) var pending = 0
    private var lastTime = -Double.infinity, direction = 0
    mutating func reset() { self = DesktopSteps() }
    mutating func append(_ steps:Int,time:Double) -> Int? {
        guard steps != 0 else{return nil}
        let sign = steps>0 ? 1:-1
        if direction != sign { pending = 0 }
        direction = sign; pending = max(-16,min(16,pending+steps))
        return advance(time:time)
    }
    mutating func advance(time:Double) -> Int? {
        guard pending != 0,time-lastTime>=0.32 else{return nil}
        let sign = pending>0 ? 1:-1; pending -= sign; lastTime = time
        return sign
    }
}

/// Percentage feedback is measured in the real target application. A fitted gain is not called verified
/// until a subsequent real-software measurement agrees with the requested percentage.
struct AppZoomCalibration:Codable,Equatable {
    var gain:Double
    var before:Double
    var after:Double
    var physicalSteps:Int
    var step:Double
    var verified:Bool
    static func fit(before:Double,after:Double,physicalSteps:Int,step:Double,currentGain:Double = 1) -> Self? {
        guard before.isFinite,after.isFinite,before>0,after>0,before != after,(1...1000).contains(physicalSteps) else{return nil}
        let observed = log(after/before)
        let desired = (observed>0 ? 1.0:-1.0)*Double(physicalSteps)*log1p(step)
        let gain = currentGain*desired/observed
        guard gain.isFinite,(0.05...10).contains(gain) else{return nil}
        return Self(gain:gain,before:before,after:after,physicalSteps:physicalSteps,step:step,verified:abs(observed-desired)<=log(1.03))
    }
}

/// Physical notch counts are provided by the user, never inferred from a pause in input reports.
struct CountedWheelLearner {
    struct Trial { var units:[String:Double]; var count:Int; var positive:Bool }
    private(set) var trials:[Trial] = []
    private(set) var reports = 0
    private var sums:[String:Double] = [:], masses:[String:Double] = [:]
    mutating func begin() { sums.removeAll(); masses.removeAll(); reports = 0 }
    mutating func record(_ sample:WheelSample) {
        guard sample.nonzero,!sample.momentum else{return}
        reports += 1
        for (key,value) in sample.values { sums[key,default:0] += value; masses[key,default:0] += abs(value) }
    }
    @discardableResult mutating func finish(physicalCount:Int) -> Bool {
        guard (1...1000).contains(physicalCount),reports>0 else{return false}
        var units:[String:Double] = [:]
        for (key,total) in sums where abs(total)>0.00001 {
            if abs(total)/(masses[key] ?? 1)>0.8 { units[key] = abs(total)/Double(physicalCount) }
        }
        guard let source = ["raw","fixed","line","point"].first(where:{units[$0] != nil}) else{return false}
        trials.append(Trial(units:units,count:physicalCount,positive:(sums[source] ?? 0)>0)); begin(); return true
    }
    var physicalCount:Int { trials.reduce(0){$0+$1.count} }
    var proposal:WheelProfile? {
        guard trials.contains(where:{$0.positive}),trials.contains(where:{!$0.positive}) else{return nil}
        var units:[String:Double] = [:]
        for key in ["raw","fixed","line","point"] {
            let values = trials.compactMap{$0.units[key]}.sorted()
            guard values.count == trials.count,let first = values.first,let last = values.last,last<=first*1.35 else{continue}
            units[key] = trials.reduce(0) { $0+($1.units[key] ?? 0)*Double($1.count) }/Double(physicalCount)
        }
        guard let source = ["raw","fixed","line","point"].first(where:{units[$0] != nil}) else{return nil}
        return WheelProfile(units:units,samples:physicalCount,variation:0,source:source)
    }
}

/// The side wheel deliberately retains the pre-calibration interpretation.
struct SideWheelSteps {
    private var remainder = 0.0, lastTime = 0.0
    mutating func reset() { remainder = 0; lastTime = 0 }
    mutating func consume(delta:Double,precise:Bool,momentum:Bool,time:Double) -> Int {
        guard !momentum,delta.isFinite,delta != 0 else{return 0}
        if time-lastTime>0.25 || delta*remainder<0 { remainder = 0 }
        lastTime = time
        if !precise { return (delta>0 ? 1:-1)*min(3,max(1,Int(min(3,abs(delta)).rounded()))) }
        remainder = clamp(remainder+delta,-48,48)
        let steps = Int(remainder/12); remainder -= Double(steps)*12
        return max(-3,min(3,steps))
    }
}

/// Conservative fallback avoids interpreting accelerated reports as many physical detents.
struct LevelWheelInterpreter {
    private var calibrated = WheelInterpreter()
    private var currentProfile:WheelProfile?
    private var lastEmission = -Double.infinity, lastInput = -Double.infinity
    private var direction = 0
    private var fallbackSource:String?
    mutating func reset() { self = LevelWheelInterpreter() }
    mutating func consume(_ sample:WheelSample,profile:WheelProfile,time:Double) -> WheelMotion {
        guard !sample.momentum,sample.nonzero,time.isFinite else{return WheelMotion()}
        let profile = profile.sanitized()
        if currentProfile != profile { reset(); currentProfile = profile }
        if profile.calibrated {
            var locked = profile
            if locked.source == nil { locked.source = ["raw","fixed","line","point"].first { locked.units[$0] != nil } }
            return calibrated.consume(sample,profile:locked,time:time,expireAfterIdle:false)
        }
        if time-lastInput>0.12 { fallbackSource = nil }
        lastInput = time
        if fallbackSource == nil { fallbackSource = sample.order.first { sample.values[$0] != nil } }
        guard let source = fallbackSource,let value = sample.values[source],value != 0 else{return WheelMotion()}
        let sign = value>0 ? 1:-1
        guard sign != direction || time-lastEmission>=0.12 else{return WheelMotion()}
        direction = sign; lastEmission = time
        return WheelMotion(amount:Double(sign),steps:sign)
    }
}
struct GuidedWheelLearning {
    enum Stage { case ready, up, down, done }
    enum Failure { case noInput, inconsistent }
    private(set) var stage:Stage = .ready
    private(set) var failure:Failure?
    private var learner = CountedWheelLearner()
    var active:Bool { stage == .up || stage == .down }
    var hasInput:Bool { learner.reports>0 }
    mutating func reset() { self = GuidedWheelLearning() }
    mutating func record(_ sample:WheelSample) { if active { learner.record(sample) } }
    mutating func advance() -> WheelProfile? {
        failure = nil
        switch stage {
        case .ready: learner = CountedWheelLearner(); learner.begin(); stage = .up
        case .up,.down:
            var candidate = learner
            guard candidate.finish(physicalCount:10) else {
                failure = learner.reports == 0 ? .noInput:.inconsistent; learner.begin(); return nil
            }
            if stage == .up { learner = candidate; stage = .down }
            else if let profile = candidate.proposal,profile.calibrated { learner = candidate; stage = .done; return profile }
            else { failure = .inconsistent; learner.begin() }
        case .done: break
        }
        return nil
    }
}

enum WheelLearningScope { case zoom, levels }
extension Configuration {
    mutating func resetWheelLearning(_ scope:WheelLearningScope) {
        switch scope {
        case .zoom:
            mouseHabits.adaptation.zoomProfile = nil
            mouseHabits.adaptation.appZoom.removeAll()
            // Legacy fallback must be empty too, or export/sanitization revives deleted measurements.
            mouseHabits.adaptation.vertical = WheelProfile()
            mouseHabits.adaptation.horizontal = WheelProfile()
        case .levels:
            ringWheel.profile = WheelProfile()
            mouseHabits.adaptation.levelProfile = nil
        }
    }
}

/// Counts isolated detent bursts before the smooth engine creates frames. Short split reports
/// form one detent; integer multiples may represent a small burst of consecutive detents.
/// New wheels bootstrap from the first slow detent, so the guide explicitly requests ratchet mode.
struct AutomaticWheelLearning {
    enum Stage { case ready, up, down, done }
    private(set) var stage:Stage = .ready
    private(set) var target = 10, progress = 0
    private(set) var message = ""
    private(set) var profile:WheelProfile?
    private var learner = CountedWheelLearner()
    private var burst:[String:Double] = [:]
    private var source:String?, firstSign = 0.0, unit = 0.0
    private var lastTime = -Double.infinity
    var active:Bool { stage == .up || stage == .down }
    mutating func begin(count:Int) { self = Self(); target = max(1,min(100,count)); stage = .up; learner.begin() }
    mutating func reset() { self = Self() }
    mutating func record(_ sample:WheelSample,time:Double) {
        guard active,!sample.momentum,sample.nonzero,time.isFinite else { return }
        if time-lastTime>=0.085 { flushBurst() }
        guard active else { return }
        if source == nil { source = ["raw","fixed","line","point"].first { sample.values[$0] != nil } }
        guard let source,let value = sample.values[source],value != 0 else { return }
        let sign = value>0 ? 1.0:-1.0
        if firstSign == 0 { firstSign = sign }
        let expected = stage == .up ? firstSign:-firstSign
        if sign != expected {
            // Finish a last pending upward detent before accepting the first downward one.
            if !burst.isEmpty { flushBurst() }
            guard active,sign == (stage == .up ? firstSign:-firstSign) else { message = "请反向滚动"; return }
        }
        message = ""; lastTime = time
        for (key,v) in sample.values { burst[key,default:0] += v }
    }
    mutating func idle(time:Double) { if active,time-lastTime>=0.085 { flushBurst() } }
    private mutating func flushBurst() {
        guard active,let source,let mass = burst[source],mass != 0 else { burst.removeAll(); return }
        let values = burst; burst.removeAll()
        let expected = stage == .up ? firstSign:-firstSign
        guard mass*expected>0 else { return }
        if unit == 0 { unit = abs(mass) }
        let ratio = abs(mass)/unit
        // Incomplete fragments are retained, never rounded into a full notch.
        guard ratio>=0.7 else { burst = values; return }
        let count = max(1,Int(ratio.rounded()))
        guard count<=12,abs(ratio-Double(count))<=0.35 else { message = "请逐格慢滚"; return }
        let accepted = min(count,target-progress),fraction = Double(accepted)/Double(count)
        learner.record(WheelSample(values:values.mapValues { $0*fraction }))
        progress += accepted
        guard progress == target else { return }
        var candidate = learner
        guard candidate.finish(physicalCount:target) else { progress = 0; learner.begin(); message = "请重试本轮"; return }
        if stage == .up { learner = candidate; stage = .down; progress = 0; message = "请向下滚动" }
        else if var learned = candidate.proposal {
            learned.learnedAt = Date(); learned.upNotches = target; learned.downNotches = target
            profile = learned; learner = candidate; stage = .done; message = "已保存"
        } else { progress = 0; learner.begin(); message = "两轮不一致，请重试向下这一轮" }
    }
}

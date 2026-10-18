import AppKit

// Public preview settings. Units are pixels, milliseconds and a dimensionless multiplier.
struct ScrollTrigger: Codable, Equatable {
    enum Device: String, Codable { case none, modifier, keyboard, mouse }
    var device: Device = .none
    var code = 0
    var label = "未设置"
    var modifiers: UInt64 = 0
    static let choices: [ScrollTrigger] = [ScrollTrigger()] + [
        (NSEvent.ModifierFlags.option,"⌥ Option"),(.shift,"⇧ Shift"),(.control,"⌃ Control"),(.command,"⌘ Command")
    ].map { ScrollTrigger(device:.modifier,code:Int($0.0.rawValue),label:$0.1) } + (2...6).map {
        ScrollTrigger(device:.mouse,code:$0,label:MouseButtonIdentity.name($0))
    }
    func matches(keys: Set<Int>, buttons: Set<Int>, flags: CGEventFlags) -> Bool {
        switch device {
        case .none: return false
        case .modifier: return flags.rawValue & UInt64(max(0,code)) != 0
        case .mouse: return buttons.contains(code)
        case .keyboard: return keys.contains(code) && flags.rawValue & modifiers == modifiers
        }
    }
}
struct ScrollTuning: Codable, Equatable {
    var smoothVertical = true
    var smoothHorizontal = true
    var reverseVertical = false
    var reverseHorizontal = false
    var pixelsPerStep = 36.0
    var transitionMilliseconds = 180.0
    var boostMultiplier = 2.5
    var boostKey = ScrollTrigger()
    var horizontalKey = ScrollTrigger()
    var bypassKey = ScrollTrigger()
    func sanitized() -> ScrollTuning {
        var value = self
        value.pixelsPerStep = pixelsPerStep.isFinite ? clamp(pixelsPerStep,1,160):36
        value.transitionMilliseconds = transitionMilliseconds.isFinite ? clamp(transitionMilliseconds,40,500):180
        value.boostMultiplier = boostMultiplier.isFinite ? clamp(boostMultiplier,1,6):2.5
        for key in [\ScrollTuning.boostKey,\.horizontalKey,\.bypassKey] {
            let trigger = value[keyPath:key]
            if (trigger.device == .keyboard && !(0...255).contains(trigger.code)) || (trigger.device == .mouse && !(2...31).contains(trigger.code)) || (trigger.device == .modifier && !ScrollTrigger.choices.contains(trigger)) { value[keyPath:key] = ScrollTrigger() }
        }
        return value
    }
}
struct ScrollApplication: Codable, Equatable {
    var bundleID: String
    var name: String
    var enabled = true
    var useGlobal = true
    var options = ScrollTuning()
}
struct SmoothScrollSettings: Codable, Equatable {
    var enabled = true
    var onlyListed = false
    var global = ScrollTuning()
    var applications: [ScrollApplication] = []
    var needsListening: Bool { enabled }
    func tuning(for bundleID: String?) -> ScrollTuning? {
        guard enabled else { return nil }
        if let rule = applications.first(where: { $0.bundleID == bundleID }) {
            guard rule.enabled else { return nil }
            return (rule.useGlobal ? global:rule.options).sanitized()
        }
        return onlyListed ? nil:global.sanitized()
    }
    func sanitized() -> SmoothScrollSettings {
        var value = self; value.global = global.sanitized()
        var seen = Set<String>()
        value.applications = applications.prefix(256).filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }.map { rule in
            var v = rule; v.name = String(v.name.prefix(100)); v.options = rule.options.sanitized(); return v
        }
        return value
    }
}

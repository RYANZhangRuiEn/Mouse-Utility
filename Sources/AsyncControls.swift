import AppKit

struct ControlValue {
    var value: Double?
    var muted = false
    var name = ""
    var backend = ""
    var error: String?
    var percentage: String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "…" }
}

/// Owned by main. HAL and DisplayServices work is isolated on separate serial queues.
/// Pointer changes use cached values; wheel writes coalesce at 30 Hz with immediate UI feedback.
final class AsyncControls {
    private let audio: AudioController
    private let brightness: BrightnessIO
    private let audioQueue = DispatchQueue(label: "orbit.audio", qos: .userInitiated)
    private let displayQueue = DispatchQueue(label: "orbit.display", qos: .userInitiated)
    private let preview: Bool
    private(set) var cache: [DialAction: ControlValue] = [:]
    private var readTime: [DialAction: TimeInterval] = [:]
    private var reading = Set<DialAction>()
    private var writing = Set<DialAction>()
    private var scheduled = Set<DialAction>()
    private var pending: [DialAction: BoundedAdjustment] = [:]
    private var revision: [DialAction: Int] = [:]
    private var targetScreen: HardwareDisplay?
    private var displayGeneration = 0
    private var displaySettings = BrightnessSettings()
    var onUpdate: ((DialAction) -> Void)?
    init(audio: AudioController, brightness: BrightnessIO, preview: Bool) {
        self.audio = audio; self.brightness = brightness; self.preview = preview
        if preview { cache[.volume] = ControlValue(value: 0.48, name: "演示"); cache[.brightness] = ControlValue(value: 0.72, name: "演示") }
    }
    func configure(display: HardwareDisplay?, settings: BrightnessSettings = BrightnessSettings()) {
        let changed = display != targetScreen || settings != displaySettings
        targetScreen = display; displaySettings = settings
        if changed {
            displayGeneration += 1; pending.removeValue(forKey: .brightness)
            if !preview { cache.removeValue(forKey: .brightness) }
            readTime.removeValue(forKey: .brightness)
        }
    }
    func request(_ action: DialAction, force: Bool = false) {
        let action: DialAction = action == .mute ? .volume : action
        guard action.adjustable else { return }
        if preview { onUpdate?(action); return }
        guard !reading.contains(action), !writing.contains(action) else { return }
        if !force, let last = readTime[action], Date.timeIntervalSinceReferenceDate - last < 0.8 { return }
        reading.insert(action)
        let version = revision[action] ?? 0
        if action == .volume {
            audioQueue.async {
                let result: Result<ControlValue, Error> = Result { let state = try self.audio.snapshot(); return ControlValue(value: state.value, muted: state.muted, name: state.name) }
                DispatchQueue.main.async { self.completeRead(action, version: version, result: result) }
            }
        } else {
            let screen = targetScreen, generation = displayGeneration, settings = displaySettings
            displayQueue.async {
                let result: Result<ControlValue, Error> = Result {
                    guard let screen else { throw ControlFailure(message: "所选屏幕未连接") }
                    return try self.brightness.read(display: screen, settings: settings)
                }
                DispatchQueue.main.async {
                    guard generation == self.displayGeneration else { self.reading.remove(action); self.request(action, force: true); return }
                    self.completeRead(action, version: version, result: result)
                }
            }
        }
    }
    private func completeRead(_ action: DialAction, version: Int, result: Result<ControlValue, Error>) {
        reading.remove(action); readTime[action] = Date.timeIntervalSinceReferenceDate
        if version == (revision[action] ?? 0) || cache[action]?.value == nil {
            switch result {
            case .success(var value):
                if let original = pending[action], let current = value.value {
                    let batch = original.rebased(minimum: 0)
                    pending[action] = batch; value.value = batch.apply(to: current)
                }
                cache[action] = value
            case .failure(let error): cache[action] = ControlValue(value: nil, error: error.localizedDescription)
            }
            onUpdate?(action)
        }
        if pending[action] != nil { schedule(action) }
    }
    func adjust(_ action: DialAction, delta: Double) {
        guard action.adjustable else { return }
        revision[action, default: 0] += 1
        let minimum = 0.0
        pending[action, default: BoundedAdjustment(minimum: minimum)].append(delta)
        if var value = cache[action], let current = value.value {
            value.value = clamp(current + delta, minimum)
            if action == .volume && value.value! > 0 { value.muted = false }
            value.error = nil; cache[action] = value; onUpdate?(action)
        }
        if action == .brightness, cache[action]?.value == nil { cache[action] = ControlValue(value: nil); request(action, force: true) }
        schedule(action)
    }
    private func schedule(_ action: DialAction) {
        guard !scheduled.contains(action), !writing.contains(action) else { return }
        scheduled.insert(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == .brightness ? 0.065 : 1.0 / 30)) { self.scheduled.remove(action); self.flush(action) }
    }
    private func flush(_ action: DialAction) {
        guard !writing.contains(action), let batch = pending[action] else { return }
        if preview { pending.removeValue(forKey: action); return }
        if action == .brightness && cache[action]?.value == nil {
            if cache[action]?.error != nil { pending.removeValue(forKey: action); return }
            request(action, force: true); return
        }
        pending.removeValue(forKey: action); writing.insert(action)
        if action == .volume {
            audioQueue.async {
                let result: Result<ControlValue, Error> = Result {
                    _ = try self.audio.adjust(transform: batch.apply)
                    let state = try self.audio.snapshot()
                    return ControlValue(value: state.value, muted: state.muted, name: state.name)
                }
                DispatchQueue.main.async { self.completeWrite(action, result: result) }
            }
        } else if let screen = targetScreen {
            let generation = displayGeneration, settings = displaySettings, version = revision[action] ?? 0
            // The cache already contains all user deltas. Send an absolute target, never
            // apply a new delta to lagging hardware readback or an old async acknowledgement.
            guard let target = cache[action]?.value else { writing.remove(action); return }
            displayQueue.async {
                let result = Result { try self.brightness.write(display: screen, value: target, settings: settings) }
                DispatchQueue.main.async {
                    guard generation == self.displayGeneration else { self.writing.remove(action); self.request(action, force: true); return }
                    self.writing.remove(action); self.readTime[action] = Date.timeIntervalSinceReferenceDate
                    if version == (self.revision[action] ?? 0) {
                        switch result {
                        case .success(let value): self.cache[action] = value
                        case .failure(let error): self.pending.removeValue(forKey: action); self.cache[action] = ControlValue(value: nil, error: error.localizedDescription)
                        }
                        self.onUpdate?(action)
                    }
                    if self.pending[action] != nil { self.schedule(action) }
                }
            }
        } else { completeWrite(action, result: .failure(ControlFailure(message: "所选屏幕未连接"))) }
    }
    func restoreDisplayDimming(blackOnly: Bool = false, completion: (() -> Void)? = nil) {
        displayGeneration += 1; revision[.brightness, default: 0] += 1
        pending.removeValue(forKey: .brightness); cache.removeValue(forKey: .brightness); readTime.removeValue(forKey: .brightness)
        if preview { completion?(); return }
        displayQueue.async {
            self.brightness.restoreDimming(blackOnly: blackOnly)
            DispatchQueue.main.async { self.reading.remove(.brightness); self.writing.remove(.brightness); completion?() }
        }
    }

    private func completeWrite(_ action: DialAction, result: Result<ControlValue, Error>) {
        writing.remove(action); readTime[action] = Date.timeIntervalSinceReferenceDate
        switch result {
        case .success(var value):
            if let next = pending[action], let current = value.value { value.value = next.apply(to: current) }
            cache[action] = value
        case .failure(let error): pending.removeValue(forKey: action); cache[action] = ControlValue(value: nil, error: error.localizedDescription)
        }
        onUpdate?(action)
        if pending[action] != nil { schedule(action) }
    }
    func toggleMute(completion: @escaping (Result<Bool, Error>) -> Void) {
        if preview { cache[.volume]?.muted.toggle(); completion(.success(cache[.volume]?.muted ?? false)); return }
        let beforeMute = pending.removeValue(forKey: .volume)
        audioQueue.async {
            let result: Result<Bool, Error> = Result {
                if let beforeMute { _ = try self.audio.adjust(transform: beforeMute.apply) }
                return try self.audio.toggleMute()
            }
            DispatchQueue.main.async { self.readTime.removeValue(forKey: .volume); self.request(.volume, force: true); completion(result) }
        }
    }
}

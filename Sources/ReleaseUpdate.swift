import AppKit

/// Separate from mouse-profile exports: importing a profile cannot re-enable checks.
final class UpdatePreferences {
    private let defaults: UserDefaults?
    var automatic: Bool { didSet { defaults?.set(automatic,forKey:"updates.automatic") } }
    var lastAttempt: Date? { didSet { defaults?.set(lastAttempt,forKey:"updates.lastAttempt") } }
    var lastNotifiedTag: String? { didSet { defaults?.set(lastNotifiedTag,forKey:"updates.lastNotifiedTag") } }
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        automatic = defaults?.object(forKey:"updates.automatic") as? Bool ?? true
        lastAttempt = defaults?.object(forKey:"updates.lastAttempt") as? Date
        lastNotifiedTag = defaults?.string(forKey:"updates.lastNotifiedTag")
    }
}

final class ReleaseUpdateChecker {
    enum Outcome { case available(PublishedRelease), current, failed(Error) }
    typealias Fetch = (@escaping (Result<Data,Error>) -> Void) -> ReleaseRequest
    static let interval: TimeInterval = 24 * 60 * 60
    let preferences: UpdatePreferences
    var onResult: ((Outcome,Bool) -> Void)?
    var onState: (() -> Void)?
    private(set) var checking = false
    private(set) var available: PublishedRelease?
    private let current: String
    private let now: () -> Date
    private let fetch: Fetch
    private var running = false
    private var timer: Timer?
    private var request: ReleaseRequest?
    private var token: UUID?
    private var manualRequest = false
    init(current: String = ReleaseCatalog.currentTag, preferences: UpdatePreferences = UpdatePreferences(), now: @escaping () -> Date = Date.init, fetch: Fetch? = nil) {
        self.current = current; self.preferences = preferences; self.now = now
        self.fetch = fetch ?? { GitHubReleaseRequest(tag:current,completion:$0) }
    }
    func start() { guard !running else { return }; running = true; configureTimer(); checkIfDue() }
    func stop() { running = false; timer?.invalidate(); timer = nil; cancelRequest() }
    func setAutomatic(_ enabled: Bool) {
        preferences.automatic = enabled
        if !enabled && !manualRequest { cancelRequest() }
        configureTimer(); onState?()
        if enabled { checkIfDue() }
    }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard running && preferences.automatic else { return }
        let next = Timer(timeInterval:60*60,repeats:true) { [weak self] _ in self?.checkIfDue() }
        next.tolerance = 60; timer = next; RunLoop.main.add(next,forMode:.common)
    }
    func checkIfDue() {
        guard running && preferences.automatic else { return }
        if let last = preferences.lastAttempt {
            let elapsed = now().timeIntervalSince(last)
            if elapsed >= 0 && elapsed < Self.interval { return }
        }
        check(manual:false)
    }
    func check(manual: Bool) {
        guard running && (manual || preferences.automatic) else { return }
        if checking { manualRequest = manualRequest || manual; return }
        checking = true; manualRequest = manual; preferences.lastAttempt = now()
        let id = UUID(); token = id; onState?()
        request = fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.running, self.token == id else { return }
                let manual = self.manualRequest
                self.request = nil; self.token = nil; self.checking = false; self.manualRequest = false
                do {
                    let release = try ReleaseCatalog.newest(in:result.get(),after:self.current)
                    self.available = release; self.onState?()
                    if let release {
                        if manual || self.preferences.lastNotifiedTag != release.tag {
                            self.preferences.lastNotifiedTag = release.tag; self.onResult?(.available(release),manual)
                        }
                    } else if manual { self.onResult?(.current,true) }
                } catch { self.onState?(); if manual { self.onResult?(.failed(error),true) } }
            }
        }
    }
    private func cancelRequest() {
        token = nil; request?.cancel(); request = nil; checking = false; manualRequest = false; onState?()
    }
    deinit { timer?.invalidate(); request?.cancel() }
}

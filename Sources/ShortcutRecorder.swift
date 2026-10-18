import AppKit
import Carbon

protocol ShortcutRecordingShield: AnyObject {
    var failureReason: String { get }
    func start(receive: @escaping (NSEvent) -> Void, interrupted: @escaping () -> Void) -> Bool
    func stop()
}

/// A short-lived, frontmost-only shield. Never changes the user's shortcut preferences.
final class SystemShortcutRecordingShield: ShortcutRecordingShield {
    private let includeMouse: Bool
    init(includeMouse: Bool = false) { self.includeMouse = includeMouse }
    private var token: UnsafeMutableRawPointer?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var receive: ((NSEvent) -> Void)?
    private var interrupted: (() -> Void)?
    private(set) var failureReason = "无法开始录制，请重试"
    func start(receive: @escaping (NSEvent) -> Void, interrupted: @escaping () -> Void) -> Bool {
        stop()
        guard InputSender.trusted else {
            failureReason = "请先在“外观与系统”授权辅助功能"
            InputSender.requestAccessibility()
            return false
        }
        guard !IsSecureEventInputEnabled(), NSApp.isActive else {
            failureReason = "请关闭密码输入后，回到设置再录制"
            return false
        }
        token = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
        guard token != nil, GetSymbolicHotKeyMode() & OptionBits(kHIHotKeyModeAllDisabled) != 0 else {
            failureReason = "系统快捷键拦截未启用，请检查辅助功能权限"; stop(); return false
        }
        self.receive = receive; self.interrupted = interrupted
        let mask = ([CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14] + (includeMouse ? [CGEventType.otherMouseDown.rawValue,CGEventType.otherMouseUp.rawValue] : []))
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let shield = Unmanaged<SystemShortcutRecordingShield>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let interrupted = shield.interrupted; shield.stop(); interrupted?()
                return Unmanaged.passUnretained(event)
            }
            guard NSApp.isActive else {
                let interrupted = shield.interrupted; shield.stop(); interrupted?()
                return Unmanaged.passUnretained(event)
            }
            if let key = NSEvent(cgEvent: event) { shield.receive?(key) }
            return nil
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { failureReason = "无法拦截快捷键，请检查辅助功能权限"; stop(); return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        guard let source else { failureReason = "录制监听启动失败，请重试"; stop(); return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; receive = nil; interrupted = nil
        if let token { PopSymbolicHotKeyMode(token); self.token = nil }
    }
    deinit { stop() }
}

final class RecorderButton: NSButton {
    private static weak var active: RecorderButton?
    static var isCapturing: Bool { active?.recording == true }
    var binding: KeyBinding?
    var onRecord: ((KeyBinding) -> Void)?
    private(set) var recording = false
    private let shield: ShortcutRecordingShield
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var candidate: KeyBinding?
    private var heldKeys = Set<UInt16>()
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var cancelling = false
    private var recordingHint: String?
    override var acceptsFirstResponder: Bool { true }
    init(shield: ShortcutRecordingShield = SystemShortcutRecordingShield()) {
        self.shield = shield
        super.init(frame: .zero)
        bezelStyle = .rounded; target = self; action = #selector(begin)
        setAccessibilityLabel("录制此菜单项的快捷键")
        toolTip = "录制期间拦截组合键；全部松开后保存。Esc 取消，切换窗口自动结束。"
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateTitle() {
        title = recording ? (candidate.map { $0.display + " · 松开按键完成" } ?? recordingHint ?? "请按快捷键… Esc 取消")
                          : (recordingHint ?? ((binding?.display ?? "未设置") + "   点击录制"))
    }
    @objc func begin() {
        if recording { cancelRecording(); return }
        Self.active?.cancelRecording()
        guard let window, window.makeFirstResponder(self) else { return }
        recordingHint = nil; candidate = nil; cancelling = false; heldKeys.removeAll(); heldModifiers = []
        guard shield.start(receive: { [weak self] event in self?.capture(event) },
                           interrupted: { [weak self] in self?.cancelRecording(message: "录制已中断，请点击重试") }) else {
            recordingHint = shield.failureReason; updateTitle(); return
        }
        recording = true; Self.active = self
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown { self.cancelRecording(); return event }
            self.capture(event); return nil
        }
        let center = NotificationCenter.default
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?),
                               (NSWindow.willCloseNotification, window as AnyObject?),
                               (NSApplication.didResignActiveNotification, nil),
                               (NSApplication.willTerminateNotification, nil)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.cancelRecording() })
        }
        updateTitle()
    }
    /// Called by both the OS tap and the app monitor; the tap consumes events before normal delivery.
    private func capture(_ event: NSEvent) {
        guard recording else { return }
        heldModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.type {
        case .keyDown:
            heldKeys.insert(event.keyCode)
            if event.keyCode == 53, candidate == nil { cancelling = true }
            else if candidate == nil, !cancelling, !event.isARepeat {
                let special: [UInt16: String] = [36:"↩",48:"⇥",49:"空格",51:"⌫",53:"Esc",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"PgUp",121:"PgDn",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
                let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键 \(event.keyCode)"
                candidate = KeyBinding(name: binding?.name ?? "", keyCode: event.keyCode, modifiers: UInt64(heldModifiers.rawValue), keyLabel: label)
            }
        case .keyUp: heldKeys.remove(event.keyCode)
        case .flagsChanged: break
        case .systemDefined:
            recordingHint = "媒体键请使用功能类型设置，Esc 取消"
        default: return
        }
        if heldKeys.isEmpty, heldModifiers.isEmpty, candidate != nil || cancelling {
            let completed = cancelling ? nil : candidate
            finish()
            if let completed { binding = completed; updateTitle(); onRecord?(completed) }
        } else { updateTitle() }
    }
    func cancelRecording(message: String? = nil) { finish(); recordingHint = message; updateTitle() }
    private func finish() {
        recording = false; if Self.active === self { Self.active = nil }
        shield.stop()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        candidate = nil; heldKeys.removeAll(); heldModifiers = []; cancelling = false; recordingHint = nil
        updateTitle()
    }
    override func resignFirstResponder() -> Bool { cancelRecording(); return true }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if window != nil, newWindow !== window { cancelRecording() }; super.viewWillMove(toWindow: newWindow) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { capture(event); return true }; return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { if recording { capture(event) } else { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if recording { capture(event) } else { super.keyUp(with: event) } }
    override func flagsChanged(with event: NSEvent) { if recording { capture(event) } else { super.flagsChanged(with: event) } }
    deinit {
        shield.stop()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

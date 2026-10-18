import AppKit
import Carbon
import Combine

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let store: SettingsStore
    let audio = AudioController()
    let brightness = BrightnessController()
    @Published var accessibilityGranted = InputSender.trusted
    var panel: DialPanel!
    var ring: RingView!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var settingsView: SettingsView?
    private let mouseInput = MouseInputController()
    private var mouseInputReady = false
    private var mouseStatus = ""
    private var probeWindow:NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var foregroundObserver: NSObjectProtocol?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var previousApp: NSRunningApplication?
    private var anchor = NSPoint.zero
    private var feedbackUntil: TimeInterval = 0
    private let preview = CommandLine.arguments.contains("--preview")
    lazy var controls = AsyncControls(audio: audio, brightness: brightness, preview: preview)
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var feedbackToken = 0
    private var explicitExit = false
    private var clickShields: [NSWindow] = []

    init(store: SettingsStore = SettingsStore()) { self.store = store; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeMainMenu()
        makePanel(); makeMenu()
        mouseInput.onAction = { [weak self] value in DispatchQueue.main.async { self?.performMouseBinding(value) } }
        mouseInput.onShortcut = { [weak self] key in
            guard let self, !self.preview, !RecorderButton.isCapturing else { return }
            DispatchQueue.main.async {
                do { try InputSender.shortcut(key) }
                catch { self.mouseStatus = error.localizedDescription; self.settingsView?.setMouseStatus(self.mouseStatus) }
            }
        }
        mouseInput.directScroll = { [weak self] event in
            guard let self else { return false }
            if self.panel?.isVisible == true { self.ring.hardwareScroll(event); return true }
            if NSApp.isActive, let window = self.probeWindow, window.isVisible,
               let setup = (window.contentView as? NSScrollView)?.documentView as? WheelSetupView { return setup.receiveHardwareScroll(event) }
            return false
        }
        mouseInput.localPractice = { [weak self] in
            guard let window = self?.probeWindow else{return false}
            return NSApp.isActive && window.isVisible && window.frame.contains(NSEvent.mouseLocation)
        }
        mouseInput.onStatus = { [weak self] value in self?.mouseStatus = value; self?.settingsView?.setMouseStatus(value) }
        mouseInput.bypass = { [weak self] type in
            if RecorderButton.isCapturing { return true }
            guard type == .scrollWheel || type == .otherMouseDragged else { return false }
            let point = NSEvent.mouseLocation
            let settings = NSApp.isActive && self?.settingsWindow?.isVisible == true && self?.settingsWindow?.frame.contains(point) == true
            let ring = self?.panel?.isVisible == true
            return settings || ring
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        mouseInput.router.applicationID = previousApp?.bundleIdentifier ?? ""
        mouseInput.foregroundPID = previousApp?.processIdentifier ?? 0
        foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.previousApp = app
            self.mouseInput.router.reset(); self.mouseInput.resetScrolling(); self.mouseInput.router.applicationID = app.bundleIdentifier ?? ""; self.mouseInput.foregroundPID = app.processIdentifier
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.mouseInput.refreshExternalApps(); self?.settingsView?.reloadFromStore()
                if self?.panel?.isVisible == true { self?.controls.request(.brightness, force: true) }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.mouseInput.resetScrolling(); self?.hideRing(); self?.controls.restoreDisplayDimming(blackOnly: true)
        })
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }; self.hideRing()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.ring.escape(); return nil }
            if event.type != .keyDown && event.window != self.panel { self.hideRing(); return nil }
            return event
        }
        controls.onUpdate = { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.renderCached()
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.configureTarget(); self?.refresh()
        }
        subscription = store.$config.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ring.loadConfiguration(); self.settingsView?.reloadFromStore(); self.updateMouseTap(); self.configureTarget()
                if self.panel.isVisible { self.refresh() }
            }
        }
        updateMouseTap()
        if !CommandLine.arguments.contains("--background") { showSettings() }
    }
    private func makePanel() {
        panel = DialPanel(contentRect: NSRect(origin: .zero, size: RingGeometry.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "鼠环"
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ring = RingView(frame: NSRect(origin: .zero, size: RingGeometry.size)); ring.controller = self
        ring.loadConfiguration(); panel.contentView = ring
    }
    private func makeMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ","); settingsItem.target = self; appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: "关闭界面，保留后台", action: #selector(closeToBackground), keyEquivalent: "q"); closeItem.target = self; appMenu.addItem(closeItem)
        let quitItem = NSMenuItem(title: "完全退出鼠环", action: #selector(quit), keyEquivalent: ""); quitItem.target = self; appMenu.addItem(quitItem)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)) }
        NSApp.mainMenu = main
    }
    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "鼠环")
        statusItem.button?.toolTip = "鼠环"
        let menu = NSMenu()
        let items: [(String, Selector, String)] = [("打开圆环", #selector(menuOpen), ""), ("设置…", #selector(menuSettings), ","), ("恢复屏幕可见", #selector(restoreDisplayVisibility), ""), ("完全退出鼠环", #selector(quit), "")]
        for (index, item) in items.enumerated() { if index == 3 { menu.addItem(.separator()) }; let entry = NSMenuItem(title: item.0, action: item.1, keyEquivalent: item.2); entry.target = self; menu.addItem(entry) }
        statusItem.menu = menu
    }
    @objc private func menuOpen() { toggleRing() }
    @objc private func menuSettings() { showSettings() }
    @objc func restoreDisplayVisibility() { controls.restoreDisplayDimming { [weak self] in self?.refresh() } }
    @objc private func quit() { explicitExit = true; NSApp.terminate(nil) }
    @objc func closeToBackground() {
        settingsView?.cancelRecording(); mouseInput.cancelDetection(); stopPermissionTimer()
        ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop()
        settingsWindow?.orderOut(nil); probeWindow?.orderOut(nil); hideRing(); store.flush()
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword:AEKeyword(kAEQuitReason))?.enumCodeValue
        if explicitExit || [DescType(kAEQuitAll),DescType(kAEShutDown),DescType(kAERestart),DescType(kAEReallyLogOut)].contains(reason ?? 0) {
            controls.restoreDisplayDimming { sender.reply(toApplicationShouldTerminate: true) }; return .terminateLater
        }
        closeToBackground(); return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop()
        settingsView?.cancelRecording(); store.flush()
        removeMouseTap()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let foregroundObserver { NSWorkspace.shared.notificationCenter.removeObserver(foregroundObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        timer?.invalidate()
    }
    func showRing(select action: DialAction? = nil) {
        settingsView?.cancelRecording(); mouseInput.cancelDetection()
        if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = current }
        settingsWindow?.orderOut(nil); probeWindow?.orderOut(nil)
        ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop()
        stopPermissionTimer(); NSApp.setActivationPolicy(.accessory)
        anchor = NSEvent.mouseLocation
        let armedSlot = action.flatMap { kind in store.config.items.firstIndex(where: { $0.action == kind }) }
        ring.prepare(armedSlot: armedSlot, armedAction: armedSlot == nil ? action : nil)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(store.config.appearance.scale, min((visible.width - 16) / RingGeometry.size.width, (visible.height - 16) / RingGeometry.size.height))
        let frame = RingGeometry.frame(near: anchor, screen: visible, scale: scale)
        panel.setFrame(frame, display: false); ring.frame = NSRect(origin: .zero, size: frame.size); ring.setScale(scale)
        configureTarget(); feedbackUntil = 0; feedbackToken += 1
        showClickShields()
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(ring)
        renderCached()
        controls.request(.volume, force: true); controls.request(.brightness, force: true)
    }
    private func showClickShields() {
        clickShields.forEach { $0.orderOut(nil) }; clickShields.removeAll()
        for screen in NSScreen.screens {
            let window = ClickShieldWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            window.hasShadow = false; window.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = ClickShieldView(frame: NSRect(origin: .zero, size: screen.frame.size)); view.onCancel = { [weak self] in self?.hideRing() }
            window.contentView = view; window.orderFrontRegardless(); clickShields.append(window)
        }
    }
    func hideRing() { clickShields.forEach { $0.orderOut(nil) }; clickShields.removeAll(); panel?.orderOut(nil); ring?.prepare(); feedbackToken += 1; feedbackUntil = 0 }
    func toggleRing() { panel.isVisible ? hideRing() : showRing() }
    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        let selectedID = ring?.activeItem?.id
        hideRing()
        if settingsWindow == nil {
            let height = min(660, max(600, (NSScreen.main?.visibleFrame.height ?? 900) - 70))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "鼠环设置"; w.isReleasedWhenClosed = false; w.delegate = self
            let view = SettingsView(store: store, controller: self); settingsView = view
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 980, height: height))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
            view.frame = NSRect(x: 0, y: 0, width: 964, height: 660); view.autoresizingMask = [.width]
            scroll.documentView = view; w.contentView = scroll
            w.minSize = NSSize(width: 960, height: 650); w.center(); settingsWindow = w
        }
        if let selectedID { settingsView?.selectItem(id: selectedID) }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        settingsView?.setMouseStatus(mouseStatus)
        checkPermissions()
        if timer == nil {
            timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermissions() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }
    private func checkPermissions() {
        let access = InputSender.trusted
        if accessibilityGranted != access { accessibilityGranted = access; updateMouseTap() }
        settingsView?.refreshPermission()
    }
    private func stopPermissionTimer() { timer?.invalidate(); timer = nil }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == probeWindow { ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop() }
        if notification.object as? NSWindow == settingsWindow { settingsView?.cancelRecording(); stopPermissionTimer(); mouseInput.cancelDetection() }
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self else{return}
            let visible = [self.settingsWindow,self.probeWindow].compactMap{$0}.contains { $0 !== closing && $0.isVisible }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
    func openFromSettings() {
        settingsWindow?.orderOut(nil)
        previousApp?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showRing() }
    }
    func requestPermissions() {
        InputSender.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func removeMouseTap() { mouseInput.stop() }
    private func updateMouseTap() {
        guard !preview else { return }
        _ = mouseInput.configure(store.config, force: accessibilityGranted && !mouseInputReady)
        mouseInputReady = accessibilityGranted
    }
    func cancelMouseDetection() { mouseInput.cancelDetection() }
    @discardableResult func detectMouseButton(receive: @escaping (Int)->Void, timeout: @escaping ()->Void) -> Bool {
        mouseInput.onDetected = receive
        guard accessibilityGranted else { requestPermissions(); return false }
        return mouseInput.detect(timeout:timeout)
    }
    func testMouseClick(_ button:Int) {
        guard !RecorderButton.isCapturing else { return }
        let key = String(button), raw = store.config.mouseBindings[key] ?? "none"
        if raw == "custom", let binding = store.config.mouseHabits.shortcuts[key] {
            do { try InputSender.shortcut(binding) } catch { settingsView?.setMouseStatus(error.localizedDescription) }
        } else if raw != "none" { performMouseBinding(raw) }
        else { settingsView?.setMouseStatus("此按键保持原点击；先选择单击动作再测试") }
    }
    func showWheelSetup(zoom: Bool = false) {
        NSApp.setActivationPolicy(.regular)
        settingsView?.cancelRecording(); mouseInput.cancelDetection()
        if let old = probeWindow { ((old.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop(); old.orderOut(nil); probeWindow = nil }
        if probeWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = zoom ? "缩放手感" : "音量与亮度手感"; window.isReleasedWhenClosed = false; window.delegate = self
            let content = WheelSetupView(store:store, zoom:zoom)
            let scroll = NSScrollView(frame:window.contentLayoutRect); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.documentView = content; window.contentView = scroll; window.center(); probeWindow = window
        }
        ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.reloadFromStore()
        hideRing(); probeWindow?.makeKeyAndOrderFront(nil)
    }

    private func configureTarget() {
        controls.configure(display: brightness.target(store.config.displayTarget, anchor: anchor), settings: store.config.brightnessControl)
    }
    func refresh() {
        guard ring != nil else { return }
        feedbackUntil = 0
        renderCached()
        if panel.isVisible { controls.request(.volume, force: true); controls.request(.brightness, force: true) }
    }
    func hoverChanged() {
        feedbackUntil = 0; feedbackToken += 1
        renderCached()
        if let item = ring.activeItem { controls.request(item.action) }
    }
    private func renderCached() {
        for action: DialAction in [.volume, .brightness] {
            let cached = controls.cache[action]
            ring.setProgress(action, value: cached?.error == nil ? (cached?.muted == true ? 0 : cached?.value) : nil)
        }
        guard Date.timeIntervalSinceReferenceDate >= feedbackUntil else { return }
        guard let item = ring.activeItem else { ring.setStatus(""); return }
        let action = item.action, title = item.title
        if action.adjustable {
            guard let value = controls.cache[action] else { ring.setStatus(title + " · …"); return }
            if let error = value.error { ring.setStatus(title + " · " + error); return }
            ring.setStatus(title + " · " + (value.muted && action == .volume ? "静音" : value.percentage))
        } else if action == .mute { ring.setStatus(controls.cache[.volume]?.muted == true ? "取消静音" : title) }
        else if action == .shortcut { ring.setStatus(title + " · " + (item.shortcut?.display ?? "未设置快捷键")) }
        else if action == .submenu { ring.setStatus(title + " · " + String(item.children.count) + " 项") }
        else { ring.setStatus(title) }
    }
    func adjust(_ action: DialAction, steps: Int) {
        guard action.adjustable, panel?.isVisible == true else { return }
        feedbackUntil = 0; feedbackToken += 1
        controls.adjust(action, delta: Double(steps) * store.config.ringWheel.step)
    }
    func adjustContinuous(_ action: DialAction, delta: Double) {
        guard action.adjustable, panel?.isVisible == true else { return }
        feedbackUntil = 0; feedbackToken += 1; controls.adjust(action, delta: delta)
    }
    private func performMouseBinding(_ raw: String) {
        guard !RecorderButton.isCapturing else { return }
        if raw == "showRing" { toggleRing(); return }
        if raw.hasPrefix("item:"), let id = UUID(uuidString: String(raw.dropFirst(5))), let item = store.config.find(id: id) {
            if item.action == .submenu, let index = store.config.items.firstIndex(where: { $0.id == id }) { showRing(); ring.openFolder(index) }
            else if item.action.adjustable { showRing(select: item.action) }
            else { performItem(item, fromMouse: true) }
        } else if raw == "middleClick" {
            guard InputSender.trusted, !preview else { return }
            let point = CGEvent(source:nil)?.location ?? .zero
            for kind:CGEventType in [.otherMouseDown,.otherMouseUp] {
                if let event = CGEvent(mouseEventSource:CGEventSource(stateID:.privateState),mouseType:kind,mouseCursorPosition:point,mouseButton:.center) {
                    MouseEvents.mark(event).post(tap:.cghidEventTap)
                }
            }
        } else if let kind = DialAction(rawValue: raw), kind.adjustable { showRing(select: kind) }
        else if let kind = DialAction(rawValue: raw) { performItem(MenuItem(kind), fromMouse: true) }
    }
    func performItem(_ item: MenuItem, fromMouse: Bool = false) {
        let action = item.action
        if action.adjustable { hoverChanged(); return }
        if action == .none { return }
        if action == .submenu {
            if let index = store.config.items.firstIndex(where: { $0.id == item.id }) { ring.openFolder(index) }
            return
        }
        if preview { feedback("演示", detail: item.title + (item.shortcut.map { " · " + $0.display } ?? ""), error: false); return }
        do {
            switch action {
            case .mute:
                controls.toggleMute { [weak self] result in
                    switch result {
                    case .success(let muted): self?.feedback(muted ? "已静音" : "已恢复", detail: "", error: false)
                    case .failure(let error): self?.feedback("不可用", detail: error.localizedDescription, error: true)
                    }
                }
            case .previous, .playPause, .next:
                try InputSender.media(action == .previous ? 18 : action == .next ? 17 : 16)
                feedback("已发送", detail: item.title, error: false)
            case .shortcut:
                guard let binding = item.shortcut else { throw ControlFailure(message: "先在设置中为此项录制快捷键") }
                guard InputSender.trusted else { throw ControlFailure(message: "需要辅助功能授权 · 菜单栏 → 设置") }
                if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = current }
                guard let target = previousApp, !target.isTerminated, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw ControlFailure(message: "请先打开目标应用，再呼出圆环") }
                hideRing(); target.activate(options: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
                    do { try InputSender.shortcut(binding) } catch { self.showRing(); self.feedback("未发送", detail: error.localizedDescription, error: true) }
                }
            default: break
            }
        } catch {
            if fromMouse && !panel.isVisible { showRing() }
            feedback("需要设置", detail: error.localizedDescription, error: true)
        }
    }
    private func feedback(_ value: String, detail: String, error: Bool) {
        let text = detail.isEmpty ? value : value + " · " + detail
        ring.setStatus(text)
        feedbackUntil = Date.timeIntervalSinceReferenceDate + 2
        feedbackToken += 1; let token = feedbackToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard token == self.feedbackToken else { return }
            self.feedbackUntil = 0; self.renderCached()
        }
    }
}

final class ClickShieldWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class ClickShieldView: NSView {
    var onCancel: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onCancel?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func scrollWheel(with event: NSEvent) { }
}

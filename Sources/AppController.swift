import AppKit
import Carbon
import Combine

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, ObservableObject {
    let store: SettingsStore
    let audio = AudioController()
    let brightness = BrightnessController()
    @Published var accessibilityGranted = InputSender.trusted
    var panel: DialPanel!
    var ring: RingView!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var updateWindow: NSPanel?
    private let updatePreferences: UpdatePreferences
    private lazy var updateChecker = ReleaseUpdateChecker(preferences:updatePreferences)
    var desktopController = DesktopController()
    private var settingsView: SettingsView?
    private let mouseInput = MouseInputController()
    private let haptics = MasterMouseController()
    private var runtimeStarted = false
    var hapticStatus:String { haptics.status }
    var wheelMode:MasterWheelMode? { haptics.wheelMode }
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

    init(store: SettingsStore = SettingsStore(), updatePreferences: UpdatePreferences = UpdatePreferences()) {
        self.store = store; self.updatePreferences = updatePreferences; super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeStarted = true
        NSApp.setActivationPolicy(.accessory)
        haptics.onStatus = { [weak self] text in self?.settingsView?.setHapticStatus(text) }
        haptics.onWheelMode = { [weak self] mode in
            guard let self,self.runtimeStarted else { return }
            self.mouseInput.setWheelMode(mode); self.settingsView?.refreshWheelMode()
        }
        makeMainMenu()
        makePanel(); makeMenu()
        if !preview { haptics.start(); haptics.configure(store.config.ringHaptics) }
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
               NSWindow.windowNumber(at:NSEvent.mouseLocation,belowWindowWithWindowNumber:0) == window.windowNumber,
               let setup = (window.contentView as? NSScrollView)?.documentView as? WheelSetupView { return setup.receiveHardwareScroll(event) }
            return false
        }
        mouseInput.localPractice = { [weak self] in
            guard let window = self?.probeWindow else{return false}
            guard NSApp.isActive,window.isVisible,NSWindow.windowNumber(at:NSEvent.mouseLocation,belowWindowWithWindowNumber:0) == window.windowNumber,let view = (window.contentView as? NSScrollView)?.documentView as? WheelSetupView else { return false }
            return view.canvasContains(NSEvent.mouseLocation)
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
        mouseInput.bypassScrolling = { [weak self] event in
            guard let self else { return true }
            let point = NSEvent.mouseLocation
            let learningPage = self.probeWindow.map { window in
                window.isVisible && NSWindow.windowNumber(at:point,belowWindowWithWindowNumber:0) == window.windowNumber
            } ?? false
            return ScrollInteractionScope.bypass(
                targetPID:pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)),ownPID:ProcessInfo.processInfo.processIdentifier,
                recording:RecorderButton.isCapturing,ring:self.panel?.isVisible == true,
                practice:learningPage && (self.probeWindow.map { $0.isVisible && ((($0.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.canvasContains(point) == true) } ?? false),
                settings:self.settingsWindow.map { $0.isVisible && $0.frame.contains(point) } ?? false,
                applicationList:self.settingsView?.allowsSmoothScrolling(at:point) == true,learningPage:learningPage)
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
                self.ring.loadConfiguration(); self.haptics.configure(self.store.config.ringHaptics); self.settingsView?.reloadFromStore(); self.updateMouseTap(); self.configureTarget()
                if self.panel.isVisible { self.refresh() }
            }
        }
        updateMouseTap()
        startRuntimeTimer()
        if !preview {
            updateChecker.onResult = { [weak self] outcome,manual in self?.presentUpdateResult(outcome,manual:manual) }
            updateChecker.onState = { [weak self] in
                guard let self else { return }
                (self.updateWindow?.contentView as? UpdatePromptView)?.setAutomatic(self.updatePreferences.automatic)
            }
            updateChecker.start()
        }
        if Self.opensSettingsAtLaunch(CommandLine.arguments) { showSettings() }
    }
    static func opensSettingsAtLaunch(_ arguments:[String]) -> Bool { arguments.contains("--settings") }
    private func makePanel() {
        panel = DialPanel(contentRect: NSRect(origin: .zero, size: RingGeometry.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = appName
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ring = RingView(frame: NSRect(origin: .zero, size: RingGeometry.size)); ring.controller = self
        ring.onHapticSelection = { [weak self] _ in self?.ringHapticHover() }
        ring.onHapticClick = { [weak self] in self?.ringHapticClick() }
        ring.loadConfiguration(); panel.contentView = ring
    }
    private func makeMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let aboutItem = NSMenuItem(title:"关于 " + appName,action:#selector(showAbout),keyEquivalent:""); aboutItem.target = self; appMenu.addItem(aboutItem)
        appendUpdateMenuItems(to:appMenu)
        appMenu.addItem(.separator())
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
        statusItem.button?.toolTip = appName
        let menu = NSMenu()
        let items: [(String, Selector, String)] = [("打开圆环", #selector(menuOpen), ""), ("设置…", #selector(menuSettings), ","), ("恢复屏幕可见", #selector(restoreDisplayVisibility), ""), ("关于 " + appName, #selector(showAbout), ""), ("完全退出鼠环", #selector(quit), "")]
        for (index, item) in items.enumerated() { if index == 3 { menu.addItem(.separator()) }; let entry = NSMenuItem(title: item.0, action: item.1, keyEquivalent: item.2); entry.target = self; menu.addItem(entry) }
        let quit = menu.items.last!; menu.removeItem(quit)
        appendUpdateMenuItems(to:menu); menu.addItem(.separator()); menu.addItem(quit)
        statusItem.menu = menu
    }
    func appendUpdateMenuItems(to menu:NSMenu) {
        for (title,action) in [("检查更新…",#selector(checkForUpdates)),("自动检查更新",#selector(toggleAutomaticUpdates))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
    }
    func validateMenuItem(_ item:NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticUpdates) { item.state = updatePreferences.automatic ? .on:.off }
        if item.action == #selector(checkForUpdates) {
            item.title = updateChecker.checking ? "正在检查更新…" : updateChecker.available.map { "发现新版本 \($0.tag)…" } ?? "检查更新…"
            return !updateChecker.checking
        }
        return true
    }
    @objc func toggleAutomaticUpdates() { updateChecker.setAutomatic(!updatePreferences.automatic) }
    @objc func checkForUpdates() {
        guard !preview else { return }
        updateChecker.check(manual:true)
    }
    private func presentUpdateResult(_ outcome:ReleaseUpdateChecker.Outcome,manual:Bool) {
        switch outcome {
        case .available(let release):
            updateWindow?.close()
            let window = NSPanel(contentRect:NSRect(x:0,y:0,width:440,height:220),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
            window.title = "鼠环更新"; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = true
            let view = UpdatePromptView(release:release,current:ReleaseCatalog.currentTag,automatic:updatePreferences.automatic)
            view.onAutomatic = { [weak self] in self?.updateChecker.setAutomatic($0) }
            view.onLater = { [weak window] in window?.close() }
            view.onDownload = { [weak window] in
                guard ReleaseCatalog.validPage(release.page,tag:release.tag) else { return }
                NSWorkspace.shared.open(release.page); window?.close()
            }
            window.contentView = view; window.center(); updateWindow = window
            window.orderFrontRegardless()
        case .current, .failed:
            guard manual else { return }
            let alert = NSAlert(); alert.messageText = "没有更新的版本"
            alert.informativeText = "当前版本：" + ReleaseCatalog.currentTag
            if case .failed(let error) = outcome { alert.messageText = "检查更新未完成"; alert.informativeText = error.localizedDescription }
            alert.addButton(withTitle:"好"); NSApp.activate(ignoringOtherApps:true); alert.runModal()
        }
    }
    @objc private func menuOpen() { toggleRing() }
    @objc private func menuSettings() { showSettings() }
    @objc func showAbout() {
        hideRing()
        NSApp.setActivationPolicy(.regular)
        if aboutWindow == nil {
            let window = AboutView.makeWindow()
            window.delegate = self; aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps:true); aboutWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func restoreDisplayVisibility() { controls.restoreDisplayDimming { [weak self] in self?.refresh() } }
    @objc private func quit() { explicitExit = true; NSApp.terminate(nil) }
    @objc func closeToBackground() {
        settingsView?.cancelRecording(); mouseInput.cancelDetection()
        ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop()
        settingsWindow?.orderOut(nil); probeWindow?.orderOut(nil); aboutWindow?.orderOut(nil); updateWindow?.orderOut(nil); hideRing(); store.flush()
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword:AEKeyword(kAEQuitReason))?.enumCodeValue
        if explicitExit || [DescType(kAEQuitAll),DescType(kAEShutDown),DescType(kAERestart),DescType(kAEReallyLogOut)].contains(reason ?? 0) {
            runtimeStarted = false; updateChecker.stop(); updateWindow?.close(); stopPermissionTimer(); mouseInput.stop()
            controls.restoreDisplayDimming { self.haptics.stop { sender.reply(toApplicationShouldTerminate:true) } }; return .terminateLater
        }
        closeToBackground(); return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        updateChecker.stop()
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
        settingsView?.cancelRecording(); mouseInput.cancelDetection(); mouseInput.resetScrolling()
        if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = current }
        settingsWindow?.orderOut(nil); probeWindow?.orderOut(nil)
        ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop()
        NSApp.setActivationPolicy(.accessory)
        anchor = NSEvent.mouseLocation
        let armedSlot = action.flatMap { kind in store.config.items.firstIndex(where: { $0.action == kind }) }
        ring.prepare(armedSlot: armedSlot, armedAction: armedSlot == nil ? action : nil)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(store.config.appearance.scale, min((visible.width - 16) / RingGeometry.size.width, (visible.height - 16) / RingGeometry.size.height))
        let frame = RingGeometry.frame(near: anchor, screen: visible, scale: scale)
        panel.setFrame(frame, display: false); ring.frame = NSRect(origin: .zero, size: frame.size); ring.setScale(scale)
        configureTarget(); feedbackUntil = 0; feedbackToken += 1
        if runtimeStarted && !preview { haptics.start(); haptics.configure(store.config.ringHaptics); haptics.beginRing() }
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
    func hideRing() { if runtimeStarted && panel?.isVisible == true { haptics.endRing() }; clickShields.forEach { $0.orderOut(nil) }; clickShields.removeAll(); panel?.orderOut(nil); ring?.prepare(); feedbackToken += 1; feedbackUntil = 0 }
    func toggleRing() { panel.isVisible ? hideRing() : showRing() }
    func showSettings() {
        if runtimeStarted && !preview { haptics.start(); haptics.configure(store.config.ringHaptics) }
        NSApp.setActivationPolicy(.regular)
        let selectedID = ring?.activeItem?.id
        hideRing()
        if settingsWindow == nil {
            let height = min(660, max(600, (NSScreen.main?.visibleFrame.height ?? 900) - 70))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = appName+" 设置"; w.isReleasedWhenClosed = false; w.delegate = self
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
        startRuntimeTimer()
    }
    private func startRuntimeTimer() {
        guard timer == nil else { return }
        timer = Timer(timeInterval:2,repeats:true) { [weak self] _ in self?.checkPermissions() }
        RunLoop.main.add(timer!,forMode:.common)
    }
    private func checkPermissions() {
        let access = InputSender.trusted
        if accessibilityGranted != access { accessibilityGranted = access; updateMouseTap() }
        if !preview { mouseInput.refreshRuntimeState(); haptics.start() }
        settingsView?.refreshPermission()
    }
    private func stopPermissionTimer() { timer?.invalidate(); timer = nil }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == probeWindow { ((probeWindow?.contentView as? NSScrollView)?.documentView as? WheelSetupView)?.stop() }
        if notification.object as? NSWindow == settingsWindow { settingsView?.cancelRecording(); mouseInput.cancelDetection() }
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self else{return}
            let visible = [self.settingsWindow,self.probeWindow,self.aboutWindow].compactMap{$0}.contains { $0 !== closing && $0.isVisible }
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
    func testRingHaptics() {
        guard runtimeStarted,!preview else { return }
        haptics.start(userInitiated:true); haptics.configure(store.config.ringHaptics); haptics.test()
    }
    private func ringHapticHover() { if runtimeStarted && !preview && panel?.isVisible == true { haptics.hover() } }
    private func ringHapticClick() { if runtimeStarted && !preview && panel?.isVisible == true { haptics.confirm() } }
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
            case .showDesktop:
                hideRing()
                try desktopController.toggle()
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

import AppKit

private final class WheelCanvas:NSView {
    var receive:((NSEvent)->Void)?
    var receiveButton:((NSEvent)->Void)?
    var zoom = 1.0, offset = 0.0, level = 0.5, desktop = 3
    var kind:HeldWheelAction = .volume
    var prompt:String?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 12; layer?.borderWidth = 1; layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityLabel("滚轮适配试用区域")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func scrollWheel(with event:NSEvent) { receive?(event) }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self) }
    override func otherMouseDown(with event:NSEvent) { window?.makeFirstResponder(self); receiveButton?(event) }
    override func otherMouseUp(with event:NSEvent) { receiveButton?(event) }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState(); context.clip(to:bounds.insetBy(dx:1,dy:1))
        if let prompt {
            let a:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:21,weight:.medium),.foregroundColor:NSColor.labelColor]
            let size = prompt.size(withAttributes:a); prompt.draw(at:NSPoint(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2),withAttributes:a)
        } else if kind == .zoom || kind == .horizontal {
            context.translateBy(x:bounds.midX+offset,y:bounds.midY); context.scaleBy(x:zoom,y:zoom)
            for x in -24...24 { for y in -8...8 {
                let rect = NSRect(x:CGFloat(x)*56-22,y:CGFloat(y)*56-22,width:44,height:44)
                NSColor.controlAccentColor.withAlphaComponent((x+y)%2 == 0 ? 0.65:0.2).setFill()
                NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8).fill()
            } }
        } else if kind == .spaces {
            for i in 0..<7 {
                let box = NSRect(x:30+CGFloat(i)*98,y:76,width:84,height:66)
                (i == desktop ? NSColor.controlAccentColor:NSColor.quaternaryLabelColor).setFill()
                NSBezierPath(roundedRect:box,xRadius:8,yRadius:8).fill()
                let label = "桌面 \(i+1)"; label.draw(at:NSPoint(x:box.minX+13,y:box.midY-8),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor])
            }
        } else {
            let text = "\(Int((level*100).rounded()))%"
            let a:[NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:26,weight:.medium),.foregroundColor:NSColor.labelColor]
            let size = text.size(withAttributes:a); text.draw(at:NSPoint(x:bounds.midX-size.width/2,y:35),withAttributes:a)
            let track = NSRect(x:70,y:100,width:bounds.width-140,height:16)
            NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect:track,xRadius:12,yRadius:12).fill()
            NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect:NSRect(x:track.minX,y:track.minY,width:track.width*level,height:16),xRadius:12,yRadius:12).fill()
        }
        context.restoreGState()
    }
    func apply(_ event:CGEvent) {
        guard let native = NSEvent(cgEvent:event) else{return}
        if native.type == .magnify { zoom = clamp(zoom*(1+Double(native.magnification)),0.1,8) }
        if native.type == .scrollWheel { offset = clamp(offset+Double(native.scrollingDeltaX)*(native.hasPreciseScrollingDeltas ? 1:10),-1200,1200) }
        needsDisplay = true
    }
    var descriptionText:String {
        switch kind {
        case .horizontal:return "横向位移 \(Int(offset)) px"
        case .spaces:return "桌面 \(desktop+1)（本地预览）"
        case .volume,.brightness:return "\(kind == .volume ? "音量":"亮度") \(Int((level*100).rounded()))%（本地预览）"
        default:return "缩放 \(Int((zoom*100).rounded()))%"
        }
    }
}

private final class WheelFlippedView:NSView { override var isFlipped:Bool { true } }

private final class WheelLearningProgress:NSView {
    var count = 0 { didSet { needsDisplay = true } }
    var total = 10 { didSet { needsDisplay = true } }
    override var isFlipped:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        let columns = min(10,total), rows = (total+columns-1)/columns
        let gap:CGFloat = 8, width = (bounds.width-CGFloat(columns-1)*gap)/CGFloat(columns)
        let height = min(CGFloat(12),(bounds.height-CGFloat(rows-1)*4)/CGFloat(rows))
        for index in 0..<total {
            let box = NSRect(x:CGFloat(index%columns)*(width+gap),y:CGFloat(index/columns)*(height+4),width:width,height:height)
            (index<count ? NSColor.controlAccentColor:NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect:box,xRadius:min(height/2,5),yRadius:min(height/2,5)).fill()
        }
        setAccessibilityLabel("学习进度 \(count) / \(total) 格")
    }
}

/// Fixed-count guidance; detailed software-percentage feedback stays collapsed by default.
final class WheelSetupView:NSView {
    let store:SettingsStore
    private let scope = NSPopUpButton(), step = NSPopUpButton()
    private let steps = NSTextField(labelWithString:""), instruction = NSTextField(wrappingLabelWithString:""), hint = NSTextField(wrappingLabelWithString:"")
    private let primary = NSButton(title:"开始学习",target:nil,action:nil), restart = NSButton(title:"重新开始",target:nil,action:nil)
    private let status = NSTextField(wrappingLabelWithString:""), live = NSTextField(labelWithString:"")
    private let more = NSButton(checkboxWithTitle:"更多设置",target:nil,action:nil), advanced = WheelFlippedView()
    private let canvas = WheelCanvas(frame:NSRect(x:24,y:272,width:632,height:162))
    private let mode = NSPopUpButton(), zoomStep = NSPopUpButton(), levelStep = NSPopUpButton(), effect = NSPopUpButton()
    private let target = NSPopUpButton(), before = NSTextField(string:"100"), after = NSTextField(string:""), actualCount = NSTextField(string:"3")
    private let feedback = NSTextField(wrappingLabelWithString:"")
    private let configuredKeys = NSButton(checkboxWithTitle:"按配置的键试用",target:nil,action:nil)
    private let router = MouseRouter()
    private var wizard = AutomaticWheelLearning(), holdingPreview = false
    private let progress = WheelLearningProgress(), learningCount = NSTextField(string:"10"), countStepper = NSStepper()
    private var learningIdle:DispatchWorkItem?, savedRound = false
    private var layoutShift:CGFloat = 0
    override var isFlipped:Bool { true }
    private let zoomScope: Bool
    private var levelIntegrator = LevelWheelInterpreter()
    private var targetID:String { target.selectedItem?.representedObject as? String ?? "com.google.Chrome" }
    init(store:SettingsStore, zoom:Bool = false) {
        self.store = store; self.zoomScope = zoom; super.init(frame:NSRect(x:0,y:0,width:680,height:616))
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label(zoom ? "缩放手感" : "音量与亮度手感",24,18,632,34,24,true)
        label("齿格挡 · 逐格慢滚",24,60,632,26,12)
        label("每轮",24,105,52,24,13)
        learningCount.frame = NSRect(x:78,y:100,width:66,height:27); learningCount.alignment = .center
        learningCount.target = self; learningCount.action = #selector(learningCountChanged); learningCount.setAccessibilityLabel("每轮学习格数"); addSubview(learningCount)
        countStepper.frame = NSRect(x:151,y:99,width:20,height:29); countStepper.minValue = 1; countStepper.maxValue = 100; countStepper.increment = 1
        countStepper.target = self; countStepper.action = #selector(learningCountChanged); countStepper.setAccessibilityLabel("学习格数微调"); addSubview(countStepper)
        label("格",183,105,42,24,13)
        step.frame = NSRect(x:438,y:100,width:218,height:30); step.target = self; step.action = #selector(stepChanged); step.setAccessibilityLabel("每格变化"); addSubview(step)
        steps.frame = NSRect(x:24,y:148,width:632,height:26); steps.font = .systemFont(ofSize:13,weight:.medium); steps.textColor = .secondaryLabelColor; addSubview(steps)
        instruction.frame = NSRect(x:24,y:185,width:632,height:32); instruction.font = .systemFont(ofSize:21,weight:.semibold); addSubview(instruction)
        hint.frame = NSRect(x:24,y:242,width:632,height:24); hint.font = .systemFont(ofSize:12); hint.textColor = .secondaryLabelColor; addSubview(hint)
        progress.frame = NSRect(x:24,y:219,width:632,height:22); addSubview(progress)
        canvas.receive = { [weak self] in self?.receive($0) }; canvas.receiveButton = { [weak self] event in if let cg = event.cgEvent { self?.receiveButton(cg) } }; addSubview(canvas)
        button(primary,438,450,218,#selector(advance)); button(restart,24,450,126,#selector(restartLearning))
        button(NSButton(title:"重置试用",target:nil,action:nil),164,450,126,#selector(resetPreview))
        let resetLearning = NSButton(title:"重置学习",target:nil,action:nil)
        resetLearning.toolTip = zoom ? "清除缩放的滚轮学习和全部应用比例校准；保留音量与亮度学习。" : "清除音量与亮度的滚轮学习；保留缩放学习。"
        resetLearning.setAccessibilityLabel(zoom ? "重置缩放学习":"重置音量与亮度学习")
        button(resetLearning,304,450,120,#selector(resetLearningData))
        status.frame = NSRect(x:24,y:501,width:632,height:45); status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor; addSubview(status)
        live.frame = NSRect(x:24,y:550,width:632,height:21); live.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium); addSubview(live)
        more.isHidden = !zoom; more.frame = NSRect(x:24,y:581,width:632,height:25); more.target = self; more.action = #selector(toggleMore); addSubview(more)
        buildAdvanced()
        router.output = { [weak self] output in
            guard let self else{return}
            switch output {
            case .events(let events): events.forEach(self.canvas.apply)
            case .level(_,let delta): self.canvas.level = clamp(self.canvas.level+delta); self.canvas.needsDisplay = true
            case .shortcut(let key): if self.canvas.kind == .spaces { self.canvas.desktop = max(0,min(6,self.canvas.desktop+(key.keyCode == 123 ? -1:1))); self.canvas.needsDisplay = true }
            default:break
            }
            self.refreshLive()
        }
        canvas.kind = zoom ? .zoom : .volume
        reloadFromStore()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat = 24,_ size:CGFloat = 12,_ bold:Bool = false,parent:NSView? = nil) {
        let field = NSTextField(wrappingLabelWithString:text); field.frame = NSRect(x:x,y:y,width:w,height:h); field.font = .systemFont(ofSize:size,weight:bold ? .semibold:.regular); (parent ?? self).addSubview(field)
    }
    private func button(_ b:NSButton,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ action:Selector,parent:NSView? = nil) {
        b.frame = NSRect(x:x,y:y,width:w,height:32); b.bezelStyle = .rounded; b.target = self; b.action = action; (parent ?? self).addSubview(b)
    }
    private func percentages(_ popup:NSPopUpButton,_ values:[Int],_ value:Double,prefix:String = "") {
        popup.removeAllItems()
        for number in values { popup.addItem(withTitle:prefix+"\(number)%"); popup.lastItem?.representedObject = Double(number)/100 }
        if !popup.itemArray.contains(where:{ abs(($0.representedObject as? Double ?? -1)-value)<0.00001 }) { popup.addItem(withTitle:prefix+"\(Int((value*100).rounded()))%"); popup.lastItem?.representedObject = value }
        popup.select(popup.itemArray.first { abs(($0.representedObject as? Double ?? -1)-value)<0.00001 })
    }
    private func buildAdvanced() {
        advanced.frame = NSRect(x:24,y:622,width:632,height:335); advanced.isHidden = true; addSubview(advanced)
        label("缩放模式",0,6,110,24,13,parent:advanced)
        mode.frame = NSRect(x:120,y:0,width:512,height:30)
        for (title,value) in [("连续（无极滚轮）",WheelMode.smooth),("每格一档",.detent)] { mode.addItem(withTitle:title); mode.lastItem?.representedObject = value.rawValue }
        mode.target = self; mode.action = #selector(optionsChanged); mode.setAccessibilityLabel("滚轮适配方式"); advanced.addSubview(mode)
        label("真实软件比例校准（可选）",0,64,400,24,14,true,parent:advanced)
        target.frame = NSRect(x:0,y:104,width:200,height:30)
        for (title,id) in [("Google Chrome","com.google.Chrome"),("Microsoft Word","com.microsoft.Word")] { target.addItem(withTitle:title); target.lastItem?.representedObject = id }
        target.target = self; target.action = #selector(targetChanged); target.setAccessibilityLabel("真实缩放目标软件"); advanced.addSubview(target)
        button(NSButton(title:"打开 Chrome 实测页",target:nil,action:nil),422,104,210,#selector(openChromeTrial),parent:advanced)
        for (field,x,text) in [(before,CGFloat(0),"起始百分比"),(after,CGFloat(152),"结束百分比"),(actualCount,CGFloat(304),"实际滚动格数")] {
            field.frame = NSRect(x:x,y:156,width:130,height:26); field.setAccessibilityLabel(text); advanced.addSubview(field); label(text,x,188,142,20,11,parent:advanced)
        }
        button(NSButton(title:"校准实际比例",target:nil,action:nil),464,154,168,#selector(fitPercentage),parent:advanced)
        feedback.frame = NSRect(x:0,y:232,width:632,height:60); feedback.font = .systemFont(ofSize:12); advanced.addSubview(feedback)
    }
    func reloadFromStore() {
        let s = store.config.mouseHabits.adaptation
        mode.selectItem(at:s.mode == .detent ? 1:0)
        percentages(zoomStep,[1,5,10,15,20,25,50],s.zoomStep)
        if !wizard.active { learningCount.integerValue = store.config.learningCount; countStepper.integerValue = store.config.learningCount }
        refreshStep(); refreshGuide(); refreshFeedback(); refreshLive()
    }
    private func refreshStep() {
        let s = store.config.mouseHabits.adaptation
        percentages(step,zoomScope ? [1,5,10,15,20,25,50]:[1,2,4,5,10,20],zoomScope ? s.zoomStep:store.config.ringWheel.step,prefix:"每格 ")
    }
    @objc private func scopeChanged() { endPreview(); wizard.reset(); canvas.kind = zoomScope ? .zoom:.volume; refreshStep(); resetPreview(); refreshGuide() }
    @objc private func stepChanged() {
        let value = step.selectedItem?.representedObject as? Double ?? 0.1
        if zoomScope { store.config.mouseHabits.adaptation.zoomStep = value } else { store.config.ringWheel.step = value }
        endPreview(); reloadFromStore()
    }
    @objc private func optionsChanged() {
        endPreview()
        store.config.mouseHabits.adaptation.mode = WheelMode(rawValue:mode.selectedItem?.representedObject as? String ?? "smooth") ?? .smooth
        refreshStep(); refreshGuide(); refreshFeedback()
    }
    @objc private func toggleMore() {
        let expanded = more.state == .on; advanced.isHidden = !expanded
        setFrameSize(NSSize(width:680,height:(expanded ? 968:616)+layoutShift))
        if let scroll = enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
    }
    @objc private func learningCountChanged(_ sender:NSControl) {
        let value = max(1,min(100,sender.integerValue))
        learningCount.integerValue = value; countStepper.integerValue = value
        store.config.learningCount = value; refreshGuide()
    }
    @objc private func advance() {
        if wizard.stage == .done { window?.performClose(nil); return }
        beginLearning()
    }
    private func beginLearning() {
        endPreview(); learningIdle?.cancel(); savedRound = false
        store.config.learningCount = max(1,min(100,learningCount.integerValue))
        wizard.begin(count:store.config.learningCount); canvas.zoom = 1; canvas.level = 0.5
        refreshGuide(); refreshLive(); window?.makeFirstResponder(canvas)
    }
    @objc private func restartLearning() { beginLearning() }
    func finishLearningBurst(at time:Double) {
        wizard.idle(time:time); saveAutomaticLearning(); refreshGuide(); refreshLive()
    }
    private func saveAutomaticLearning() {
        guard !savedRound,let profile = wizard.profile else { return }
        savedRound = true; store.backup()
        if zoomScope { store.config.mouseHabits.adaptation.zoomProfile = profile; store.config.mouseHabits.adaptation.appZoom.removeAll() }
        else { store.config.ringWheel.profile = profile }
        store.flush(); canvas.zoom = 1; canvas.level = 0.5; refreshFeedback()
    }
    @objc private func resetLearningData() {
        learningIdle?.cancel(); savedRound = false
        endPreview(); wizard.reset(); store.backup()
        store.config.resetWheelLearning(zoomScope ? .zoom:.levels)
        store.flush()
        before.stringValue = "100"; after.stringValue = ""; actualCount.stringValue = "3"
        resetPreview(); reloadFromStore()
        status.stringValue = zoomScope ? "缩放学习已重置" : "音量与亮度学习已重置"
    }
    private func refreshGuide() {
        step.isEnabled = !wizard.active; learningCount.isEnabled = !wizard.active; countStepper.isEnabled = !wizard.active
        restart.isHidden = wizard.stage == .ready; primary.isEnabled = !wizard.active
        let total = wizard.active || wizard.stage == .done ? wizard.target:store.config.learningCount
        progress.total = total; progress.count = wizard.stage == .done ? total:wizard.progress
        let rows = (total+9)/10
        let height = CGFloat(rows*10+max(0,rows-1)*4)
        let shift = max(0,height-22), difference = shift-layoutShift
        if difference != 0 {
            for view in subviews where view.frame.minY>=242 { view.frame.origin.y += difference }
            layoutShift = shift
            setFrameSize(NSSize(width:680,height:(more.state == .on ? 968:616)+layoutShift))
        }
        progress.frame.size.height = height
        steps.stringValue = wizard.stage == .down || wizard.stage == .done ? "✓ 向上 \(total) 格  →  向下 \(wizard.stage == .done ? total:wizard.progress)/\(total) 格" : "向上 \(wizard.progress)/\(total) 格  →  向下 \(total) 格"
        hint.stringValue = ""
        switch wizard.stage {
        case .ready: instruction.stringValue = "准备学习"; primary.title = "开始学习"; canvas.prompt = "在这里试用缩放与调节"
        case .up: instruction.stringValue = "↑ 向上滚动"; primary.title = "学习中…"; canvas.prompt = "↑"; hint.stringValue = wizard.message
        case .down: instruction.stringValue = "↓ 反向滚动"; primary.title = "学习中…"; canvas.prompt = "↓"; hint.stringValue = wizard.message
        case .done: instruction.stringValue = "学习完成"; primary.title = "完成"; canvas.prompt = nil
        }
        let profile = zoomScope ? store.config.mouseHabits.adaptation.zoomProfile:store.config.ringWheel.profile
        if let profile,profile.calibrated {
            let date = profile.learnedAt.map { date -> String in let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return " · "+f.string(from:date) } ?? ""
            let perStep = zoomScope ? store.config.mouseHabits.adaptation.zoomStep:store.config.ringWheel.step
            status.stringValue = "已学习 · \(profile.samples) 格 · 每格 \(Int((perStep*100).rounded()))%"+date
            if zoomScope { status.stringValue += "\n应用比例校准：\(store.config.mouseHabits.adaptation.appZoom.count) 个" }
        } else { status.stringValue = "尚未学习" }
        canvas.needsDisplay = true; progress.needsDisplay = true
    }
    @objc private func resetPreview() { endPreview(); canvas.zoom = 1; canvas.offset = 0; canvas.level = 0.5; canvas.desktop = 3; canvas.needsDisplay = true; refreshLive() }
    private func refreshLive() { live.stringValue = wizard.active ? "\(wizard.stage == .up ? "向上":"向下") \(wizard.progress) / \(wizard.target) 格":canvas.descriptionText }
    @objc private func effectChanged() { endPreview(); canvas.kind = HeldWheelAction(rawValue:effect.selectedItem?.representedObject as? String ?? "volume") ?? .volume; canvas.prompt = nil; resetPreview() }
    @objc private func configuredKeysChanged() { resetPreview(); canvas.prompt = nil; effect.isEnabled = configuredKeys.state != .on }
    @objc private func targetChanged() { refreshFeedback() }
    private func refreshFeedback() {
        if let result = store.config.mouseHabits.adaptation.appZoom[targetID] {
            feedback.stringValue = result.verified && abs(result.step-store.config.mouseHabits.adaptation.zoomStep)<0.00001 ? "该软件的已记录变化与目标比例相符。":"保留了该软件的修正值，可按需要再核对一轮。"
        } else { feedback.stringValue = "可跳过。每格 10% 为相对变化：100% → 110% → 121%。" }
    }
    @objc private func fitPercentage() {
        guard let result = AppZoomCalibration.fit(before:before.doubleValue,after:after.doubleValue,physicalSteps:actualCount.integerValue,step:store.config.mouseHabits.adaptation.zoomStep,currentGain:store.config.mouseHabits.adaptation.appZoom[targetID]?.gain ?? 1) else { feedback.stringValue = "没有有效的实际比例变化，请核对后再填。"; return }
        store.config.mouseHabits.adaptation.appZoom[targetID] = result; refreshFeedback()
    }
    @objc private func openChromeTrial() {
        guard let page = Bundle.main.url(forResource:"NativeZoom",withExtension:"html"),let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") else{return}
        let options = NSWorkspace.OpenConfiguration(); options.activates = true; NSWorkspace.shared.open([page],withApplicationAt:chrome,configuration:options)
    }
    private func endPreview() { router.reset(); levelIntegrator.reset(); holdingPreview = false }
    func stop() { learningIdle?.cancel(); endPreview(); wizard.reset() }
    private func previewButton(_ type:CGEventType) -> CGEvent {
        let event = CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:.zero,mouseButton:.center)!
        event.setIntegerValueField(.mouseEventButtonNumber,value:31); return event
    }
    func receiveButton(_ event:CGEvent) {
        guard configuredKeys.state == .on,!wizard.active else{return}
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if event.type == .otherMouseDown,let kind = store.config.mouseHabits.wheel[String(number)],kind != .none { canvas.kind = kind }
        _ = router.handle(event.type,event,config:store.config); refreshLive()
    }
    func receive(_ event:NSEvent) { if let cg = event.cgEvent { receive(cg,time:event.timestamp) } }
    func canvasContains(_ point:NSPoint) -> Bool {
        guard let window else { return false }
        return canvas.bounds.contains(canvas.convert(window.convertPoint(fromScreen:point),from:nil))
    }
    func receiveHardwareScroll(_ cg: CGEvent) -> Bool {
        guard let window else { return false }
        let point = canvas.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard canvas.bounds.contains(point) else { return false }
        receive(cg, time: ProcessInfo.processInfo.systemUptime); return true
    }
    func receive(_ event:CGEvent,time:Double) {
        if event.getIntegerValueField(.eventSourceUserData) == MouseEvents.externalSmoothingMarker {
            status.stringValue = "输入已经被其他工具平滑，请先暂停该工具再学习。"; return
        }
        let side = abs(MouseEvents.physicalDelta(event,horizontal:true))>abs(MouseEvents.physicalDelta(event))
        if wizard.active {
            if !side {
                wizard.record(WheelSample(event),time:time); saveAutomaticLearning()
                learningIdle?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.finishLearningBurst(at:time+0.10) }
                learningIdle = item; DispatchQueue.main.asyncAfter(deadline:.now()+0.10,execute:item)
            }
            refreshGuide(); refreshLive(); return
        }
        guard WheelSample(event).nonzero || WheelSample(event,horizontal:true).nonzero else{return}
        canvas.prompt = nil
        if configuredKeys.state == .on {
            if let active = router.presses.values.filter({$0.wheel != .none}).max(by:{$0.order<$1.order}) { canvas.kind = active.wheel }
            else if side,store.config.mouseHabits.thumbSpaces { canvas.kind = .spaces }
            _ = router.handle(.scrollWheel,event,config:store.config,time:time); refreshLive(); return
        }
        guard !side else{return}
        if !zoomScope {
            let settings = store.config.ringWheel
            let motion = levelIntegrator.consume(WheelSample(event), profile: settings.profile, time: time)
            canvas.level = clamp(canvas.level + Double(motion.steps) * settings.step)
            canvas.needsDisplay = true; refreshLive(); return
        }
        var config = store.config; config.mouseHabits.enabled = true; config.mouseHabits.wheel["31"] = canvas.kind; config.mouseBindings["31"] = "none"; config.mouseHabits.move["31"] = HeldMoveAction.none
        if !holdingPreview { _ = router.handle(.otherMouseDown,previewButton(.otherMouseDown),config:config); holdingPreview = true }
        _ = router.handle(.scrollWheel,event,config:config,time:time); refreshLive()
    }
    deinit { learningIdle?.cancel(); router.reset() }
}

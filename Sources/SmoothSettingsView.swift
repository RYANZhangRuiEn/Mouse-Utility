import AppKit
import UniformTypeIdentifiers

private final class ScrollPanel: NSView { override var isFlipped: Bool { true } }
final class SmoothSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: SettingsStore
    private weak var controller:AppController?
    private var editingMode:MasterWheelMode = .ratchet
    private let modeSelector = NSSegmentedControl(labels:["棘齿挡","无极挡"],trackingMode:.selectOne,target:nil,action:nil)
    private let activeProfile = NSPopUpButton()
    private let modeStatus = NSTextField(labelWithString:"")
    private var profile:SmoothScrollSettings {
        get { store.config.scrolling(for:editingMode) }
        set { store.config.setScrolling(newValue,for:editingMode) }
    }
    private let enabled = NSButton(checkboxWithTitle:"启用平滑滚动",target:nil,action:nil)
    private let onlyListed = NSButton(checkboxWithTitle:"仅对列表中的应用生效",target:nil,action:nil)
    private let table = NSTableView()
    private let form = ScrollPanel()
    private let titleField = NSTextField(labelWithString:"")
    private let useGlobal = NSButton(checkboxWithTitle:"沿用全局手感",target:nil,action:nil)
    private let appEnabled = NSButton(checkboxWithTitle:"在此应用中启用",target:nil,action:nil)
    private var checks: [NSButton] = [], sliders: [NSSlider] = [], values: [NSTextField] = []
    private var keyChoices: [NSPopUpButton] = [], recorders: [RecorderButton] = []
    private var selectedID: String?
    private var loading = false
    override var isFlipped: Bool { true }
    init(store: SettingsStore, controller: AppController) {
        self.store = store; self.controller = controller
        super.init(frame:NSRect(x:24,y:88,width:930,height:545))
        modeSelector.frame = NSRect(x:0,y:0,width:220,height:28); modeSelector.selectedSegment = 0
        modeSelector.target = self; modeSelector.action = #selector(modeChanged); modeSelector.setAccessibilityLabel("编辑滚轮挡位设置")
        modeSelector.toolTip = "两套设置独立保存；使用时读取鼠标实际挡位自动切换。"; addSubview(modeSelector)
        activeProfile.frame = NSRect(x:573,y:0,width:350,height:28)
        activeProfile.addItems(withTitles:WheelProfileSelection.allCases.map { $0.title })
        activeProfile.setAccessibilityLabel("实际使用的滚动参数")
        activeProfile.target = self; activeProfile.action = #selector(activeProfileChanged); addSubview(activeProfile)
        enabled.title = "全局平滑滚动"
        enabled.frame = NSRect(x:267,y:0,width:280,height:28); enabled.target = self; enabled.action = #selector(masterChanged); addSubview(enabled)
        modeStatus.frame = NSRect(x:0,y:36,width:910,height:28); modeStatus.font = .systemFont(ofSize:12); modeStatus.textColor = .secondaryLabelColor; addSubview(modeStatus)
        let scroll = NSScrollView(frame:NSRect(x:0,y:82,width:220,height:365)); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("application")); column.width = 214; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 40; table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        scroll.documentView = table; addSubview(scroll)
        button("＋ 添加应用",0,456,126,#selector(addApplication)); button("－",135,456,42,#selector(removeApplication))
        onlyListed.frame = NSRect(x:0,y:504,width:230,height:24); onlyListed.target = self; onlyListed.action = #selector(listModeChanged); onlyListed.font = .systemFont(ofSize:12); addSubview(onlyListed)
        let divider = NSBox(frame:NSRect(x:238,y:82,width:1,height:445)); divider.boxType = .separator; addSubview(divider)
        titleField.frame = NSRect(x:267,y:80,width:400,height:28); titleField.font = .systemFont(ofSize:20,weight:.semibold); addSubview(titleField)
        button("恢复默认",805,78,118,#selector(resetTuning))
        appEnabled.frame = NSRect(x:267,y:116,width:205,height:25); appEnabled.target = self; appEnabled.action = #selector(appChanged); addSubview(appEnabled)
        useGlobal.frame = NSRect(x:493,y:116,width:200,height:25); useGlobal.target = self; useGlobal.action = #selector(inheritanceChanged); addSubview(useGlobal)
        form.frame = NSRect(x:267,y:150,width:656,height:380); addSubview(form)
        for (i,text) in ["垂直平滑","水平平滑","反转垂直","反转水平"].enumerated() {
            let b = NSButton(checkboxWithTitle:text,target:self,action:#selector(axisChanged(_:))); b.tag = i; b.frame = NSRect(x:CGFloat(i%2)*275,y:CGFloat(i/2)*31,width:250,height:26); form.addSubview(b); checks.append(b)
        }
        let names = ["每格距离","过渡时长","加速倍率"], units = ["px","ms","×"]
        for i in 0..<3 {
            let y = CGFloat(84+i*59)
            label(names[i],0,y+3,105,22,13,.labelColor,parent:form)
            let ranges: [(Double,Double)] = [(1,160),(40,500),(1,6)]
            let slider = NSSlider(value:0,minValue:ranges[i].0,maxValue:ranges[i].1,target:self,action:#selector(parameterChanged(_:))); slider.tag = i; slider.frame = NSRect(x:111,y:y,width:370,height:25); slider.isContinuous = true; slider.setAccessibilityLabel(names[i]); form.addSubview(slider); sliders.append(slider)
            let field = NSTextField(frame:NSRect(x:500,y:y,width:82,height:25)); field.tag = i; field.delegate = self; field.target = self; field.action = #selector(parameterChanged(_:)); field.alignment = .right; field.setAccessibilityLabel(names[i]+"数值"); form.addSubview(field); values.append(field)
            label(units[i],590,y+4,45,20,12,.secondaryLabelColor,parent:form)
        }
        for (i,name) in ["按住加速","转为横向","暂停平滑"].enumerated() {
            let y = CGFloat(270+i*35)
            label(name,0,y+3,100,23,13,.labelColor,parent:form)
            let popup = NSPopUpButton(frame:NSRect(x:111,y:y,width:242,height:28)); popup.tag = i; popup.target = self; popup.action = #selector(keyChanged(_:)); popup.setAccessibilityLabel(name+"控制键"); form.addSubview(popup); keyChoices.append(popup)
            let recorder = RecorderButton(); recorder.frame = NSRect(x:364,y:y,width:278,height:28); recorder.onRecord = { [weak self] key in self?.setTrigger(i,ScrollTrigger(device:.keyboard,code:Int(key.keyCode),label:key.keyLabel,modifiers:key.modifiers)) }; form.addSubview(recorder); recorders.append(recorder)
        }
        reload()
    }
    required init?(coder:NSCoder) { fatalError() }
    @discardableResult private func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ size:CGFloat,_ color:NSColor,parent:NSView? = nil)->NSTextField {
        let f = NSTextField(wrappingLabelWithString:text); f.frame = NSRect(x:x,y:y,width:w,height:h); f.font = .systemFont(ofSize:size); f.textColor = color; (parent ?? self).addSubview(f); return f
    }
    private func button(_ text:String,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ action:Selector) {
        let b = NSButton(title:text,target:self,action:action); b.bezelStyle = .rounded; b.frame = NSRect(x:x,y:y,width:width,height:30); addSubview(b)
    }
    private var index:Int? { profile.applications.firstIndex { $0.bundleID == selectedID } }
    private var tuning:ScrollTuning { index.map { profile.applications[$0].useGlobal ? profile.global:profile.applications[$0].options } ?? profile.global }
    private func edit(_ change:(inout ScrollTuning)->Void) {
        guard !loading else { return }; var value = tuning; change(&value); value = value.sanitized()
        if let i = index { profile.applications[i].useGlobal = false; profile.applications[i].options = value }
        else { profile.global = value }; reloadControls()
    }
    func reload() { loading = true; table.reloadData(); let row = index.map { $0+1 } ?? 0; table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); loading = false; reloadControls() }
    private func reloadControls() {
        loading = true; defer { loading = false }
        let settings = profile, value = tuning
        enabled.state = settings.enabled ? .on:.off; onlyListed.state = settings.onlyListed ? .on:.off
        titleField.stringValue = (index.map { settings.applications[$0].name } ?? "全局手感") + " · " + editingMode.title
        appEnabled.isHidden = index == nil; useGlobal.isHidden = index == nil
        appEnabled.state = index.map { settings.applications[$0].enabled ? .on:.off } ?? .on
        useGlobal.state = index.map { settings.applications[$0].useGlobal ? .on:.off } ?? .off
        let axis = [value.smoothVertical,value.smoothHorizontal,value.reverseVertical,value.reverseHorizontal]
        for i in 0..<4 { checks[i].state = axis[i] ? .on:.off }
        for (i,v) in [value.pixelsPerStep,value.transitionMilliseconds,value.boostMultiplier].enumerated() { sliders[i].doubleValue = v; values[i].stringValue = String(format:i==2 ? "%.2f":"%.0f",v) }
        let triggers = [value.boostKey,value.horizontalKey,value.bypassKey]
        for i in 0..<3 {
            let popup = keyChoices[i]; popup.removeAllItems()
            for (j,choice) in ScrollTrigger.choices.enumerated() { popup.addItem(withTitle:choice.label); popup.lastItem!.tag = j }
            popup.addItem(withTitle:"录制键盘组合…"); popup.lastItem!.tag = -1
            if let j = ScrollTrigger.choices.firstIndex(of:triggers[i]) { popup.selectItem(withTag:j); recorders[i].isHidden = true }
            else { popup.selectItem(withTag:-1); recorders[i].isHidden = false; recorders[i].binding = KeyBinding(name:"",keyCode:UInt16(clamping:triggers[i].code),modifiers:triggers[i].modifiers,keyLabel:triggers[i].label); recorders[i].updateTitle() }
        }
        let editable = (index.map { settings.applications[$0].enabled } ?? true)
        form.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = editable }
        refreshWheelMode()
    }
    @objc private func activeProfileChanged() {
        guard !loading else { return }
        store.config.wheelProfileSelection = WheelProfileSelection.allCases[max(0,activeProfile.indexOfSelectedItem)]
        refreshWheelMode()
    }
    func refreshWheelMode() {
        activeProfile.selectItem(at:WheelProfileSelection.allCases.firstIndex(of:store.config.wheelProfileSelection) ?? 0)
        let current = store.config.wheelProfileSelection.status(observed:controller?.wheelMode)
        let another = !NSRunningApplication.runningApplications(withBundleIdentifier:"com.caldis.Mos").isEmpty
        modeStatus.stringValue = current + (another ? " · 已暂停内置滚动，避免重复处理":"")
    }
    @objc private func modeChanged() {
        cancelRecording(); editingMode = modeSelector.selectedSegment == 0 ? .ratchet:.freeSpin
        selectedID = nil; reload()
    }
    func applicationScrollContains(_ point:NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor,let window,let scroll = table.enclosingScrollView else { return false }
        return scroll.bounds.contains(scroll.convert(window.convertPoint(fromScreen:point),from:nil))
    }
    func cancelRecording() { recorders.forEach { $0.cancelRecording() } }
    func numberOfRows(in tableView:NSTableView)->Int { profile.applications.count+1 }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let f = NSTextField(labelWithString:row == 0 ? "全局":profile.applications[row-1].name); f.font = .systemFont(ofSize:14,weight:row==0 ? .semibold:.regular); f.lineBreakMode = .byTruncatingTail; return f
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !loading else { return }; cancelRecording(); selectedID = table.selectedRow>0 ? profile.applications[table.selectedRow-1].bundleID:nil; reloadControls()
    }
    @objc private func masterChanged() { cancelRecording(); profile.enabled = enabled.state == .on; reloadControls() }
    @objc private func listModeChanged() { profile.onlyListed = onlyListed.state == .on }
    @objc private func appChanged() { if let i = index { profile.applications[i].enabled = appEnabled.state == .on }; cancelRecording(); reloadControls() }
    @objc private func inheritanceChanged() { if let i = index { profile.applications[i].useGlobal = useGlobal.state == .on }; cancelRecording(); reloadControls() }
    @objc private func axisChanged(_ sender:NSButton) { edit { value in switch sender.tag { case 0:value.smoothVertical = sender.state == .on; case 1:value.smoothHorizontal = sender.state == .on; case 2:value.reverseVertical = sender.state == .on; default:value.reverseHorizontal = sender.state == .on } } }
    @objc private func parameterChanged(_ sender:NSControl) { edit { value in switch sender.tag { case 0:value.pixelsPerStep = sender.doubleValue; case 1:value.transitionMilliseconds = sender.doubleValue; default:value.boostMultiplier = sender.doubleValue } } }
    func controlTextDidEndEditing(_ notification:Notification) { if let field = notification.object as? NSTextField { parameterChanged(field) } }
    @objc private func resetTuning() { cancelRecording(); edit { $0 = ScrollTuning() } }
    @objc private func keyChanged(_ sender:NSPopUpButton) {
        cancelRecording(); let choice = sender.selectedItem!.tag
        if choice >= 0 { setTrigger(sender.tag,ScrollTrigger.choices[choice]) }
        else { recorders[sender.tag].isHidden = false; recorders[sender.tag].begin() }
    }
    private func setTrigger(_ index:Int,_ trigger:ScrollTrigger) { edit { value in switch index { case 0:value.boostKey = trigger; case 1:value.horizontalKey = trigger; default:value.bypassKey = trigger } } }
    @objc private func addApplication() {
        cancelRecording(); let picker = NSOpenPanel(); picker.title = "选择应用"; picker.allowedContentTypes = [.applicationBundle]; picker.directoryURL = URL(fileURLWithPath:"/Applications"); picker.canChooseDirectories = false; picker.canChooseFiles = true
        guard picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url:url), let id = bundle.bundleIdentifier else { return }
        if !profile.applications.contains(where:{$0.bundleID == id}) { profile.applications.append(ScrollApplication(bundleID:id,name:(bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent)) }
        selectedID = id; reload()
    }
    @objc private func removeApplication() { guard let i = index else { return }; cancelRecording(); profile.applications.remove(at:i); selectedID = nil; reload() }
}

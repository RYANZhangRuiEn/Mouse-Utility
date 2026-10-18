import AppKit
import UniformTypeIdentifiers

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
/// One native settings window. Left: menu tree. Right: one item editor, independent bindings.
final class SettingsView: NSView, NSTextFieldDelegate {
    let store: SettingsStore
    weak var controller: AppController?
    private let menuPage = FlippedView(), systemPage = FlippedView(), mousePage = FlippedView()
    private let tabs = NSSegmentedControl(labels: ["圆环", "鼠标", "平滑滚动", "外观"], trackingMode: .selectOne, target: nil, action: nil)
    private let ringEditor = RingEditorView(frame: NSRect(x: 0, y: 0, width: 470, height: 430))
    private var editChildren: NSButton!
    private var selection = ItemLocation(root: 0, child: nil)
    private var reloading = false
    private let nameField = NSTextField(), type = NSPopUpButton(), recorder = RecorderButton(), symbols = NSPopUpButton(), examples = NSPopUpButton()
    private let iconPreview = NSImageView(), templateIcon = NSButton(checkboxWithTitle: "图标随高亮自动反色", target: nil, action: nil)
    private var shortcutControls: [NSView] = []
    private var addButton: NSButton!, deleteButton: NSButton!
    private let permissionStatus = NSTextField(labelWithString: ""), permission = NSButton(title: "授权辅助功能", target: nil, action: nil)
    private let screens = NSPopUpButton(), theme = NSPopUpButton(), accent = NSColorWell()
    private let extendedBlack = NSButton(checkboxWithTitle: "扩展低亮度至全黑", target: nil, action: nil)
    private var smoothPage: SmoothSettingsView!
    private let scaleSlider = NSSlider(value: 100, minValue: 80, maxValue: 125, target: nil, action: nil)
    private let delaySlider = NSSlider(value: 140, minValue: 60, maxValue: 500, target: nil, action: nil)
    private let stepSlider = NSSlider(value: 10, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let scaleText = NSTextField(labelWithString: ""), delayText = NSTextField(labelWithString: ""), stepText = NSTextField(labelWithString: "")
    private let reverse = NSButton(checkboxWithTitle: "反转滚轮方向", target: nil, action: nil)
    private var selectedMouseButton = 2
    private let mouseEnabled = NSButton(checkboxWithTitle:"启用按住手势",target:nil,action:nil)
    private let mouseButton = NSPopUpButton(), mouseClick = NSPopUpButton(), mouseWheel = NSPopUpButton(), mouseMove = NSPopUpButton()
    private let wheelReverse = NSButton(checkboxWithTitle:"反向",target:nil,action:nil)
    private let moveReverse = NSButton(checkboxWithTitle:"反向",target:nil,action:nil)
    private let mouseMoveHelp = NSTextField(wrappingLabelWithString:"")
    private let mouseLiveStatus = NSTextField(labelWithString:"等待监听状态")
    private let mouseRecorder = RecorderButton(), detectStatus = NSTextField(labelWithString:"")
    private let thumbSpaces = NSButton(checkboxWithTitle:"横向滚轮切换桌面  ⌃← / ⌃→",target:nil,action:nil)
    private let spacesReverse = NSButton(checkboxWithTitle:"反转桌面方向",target:nil,action:nil)
    private let mouseDefaults:[(String,KeyBinding)] = [
        ("查询选中文字",.command("D",code:2,extra:.control)),
        ("显示 / 隐藏桌面",KeyBinding(name:"",keyCode:103,modifiers:0,keyLabel:"F11")),
        ("调度中心",KeyBinding(name:"",keyCode:126,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"↑")),
        ("当前应用窗口",KeyBinding(name:"",keyCode:125,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"↓")),
        ("左侧桌面",KeyBinding(name:"",keyCode:123,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"←")),
        ("右侧桌面",KeyBinding(name:"",keyCode:124,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"→"))]
    private let iconChoices: [(String,String)] = [("自动",""),("键盘","keyboard"),("Command","command"),("星标","star"),("爱心","heart"),("闪电","bolt"),("复制图标","doc.on.doc"),("剪贴板","clipboard"),("剪刀","scissors"),("文件夹","folder"),("网格","square.grid.2x2"),("浏览器","globe"),("搜索","magnifyingglass"),("截图","camera.viewfinder"),("相机","camera"),("锁","lock"),("音乐","music.note"),("播放","play"),("暂停","pause"),("音量","speaker.wave.2"),("亮度","sun.max"),("代码","chevron.left.forwardslash.chevron.right"),("终端","terminal"),("笔","pencil"),("画笔","paintbrush"),("调色板","paintpalette"),("窗口","macwindow"),("全屏","arrow.up.left.and.arrow.down.right"),("返回","arrow.uturn.backward"),("工具","wrench.and.screwdriver"),("时间","clock"),("文件","doc"),("书签","bookmark"),("收件箱","tray"),("咖啡","cup.and.saucer"),("人物","person"),("齿轮","gearshape")] + DialIcons.additions
    private let presets: [(String, KeyBinding, String)] = [
        ("复制",.command("C",code:8),"doc.on.doc"),("粘贴",.command("V",code:9),DialIcons.paste),("剪切",.command("X",code:7),"scissors"),
        ("全选",.command("A",code:0),"selection.pin.in.out"),("撤销",.command("Z",code:6),"arrow.uturn.backward"),
        ("截图选区",.command("4",code:21,extra:.shift),"camera.viewfinder"),("锁屏",.command("Q",code:12,extra:.control),"lock"),
        ("查询选中文字",.command("D",code:2,extra:.control),"text.magnifyingglass"),
        ("显示 / 隐藏桌面",KeyBinding(name:"",keyCode:103,modifiers:0,keyLabel:"F11"),"macwindow"),
        ("调度中心",KeyBinding(name:"",keyCode:126,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"↑"),"square.grid.2x2"),
        ("当前应用窗口",KeyBinding(name:"",keyCode:125,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"↓"),"macwindow.on.rectangle"),
        ("左侧桌面",KeyBinding(name:"",keyCode:123,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"←"),"arrow.left"),
        ("右侧桌面",KeyBinding(name:"",keyCode:124,modifiers:UInt64(NSEvent.ModifierFlags.control.rawValue),keyLabel:"→"),"arrow.right")]
    override var isFlipped: Bool { true }
    init(store: SettingsStore, controller: AppController) {
        self.store = store; self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 660))
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        text(appName, x: 24, y: 22, w: 190, h: 32, size: 22, bold: true, parent: self)
        tabs.frame = NSRect(x: 218, y: 25, width: 480, height: 30); tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(tabChanged); addSubview(tabs)
        button("导入…", x: 766, y: 25, w: 86, action: #selector(importConfig), parent: self)
        button("导出…", x: 862, y: 25, w: 86, action: #selector(exportConfig), parent: self)
        for page in [menuPage, mousePage, systemPage] { page.frame = NSRect(x: 24, y: 88, width: 930, height: 545); page.autoresizingMask = [.width]; addSubview(page) }
        makeMenuEditor(); makeSystemPage(); makeMousePage(); smoothPage = SmoothSettingsView(store:store,controller:controller); addSubview(smoothPage); smoothPage.isHidden = true; systemPage.isHidden = true; mousePage.isHidden = true
        reloadFromStore()
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult private func text(_ value: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 22, size: CGFloat = 13, bold: Bool = false, secondary: Bool = false, parent: NSView) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value); field.frame = NSRect(x:x,y:y,width:w,height:h)
        field.font = .systemFont(ofSize:size,weight:bold ? .semibold : .regular); field.textColor = secondary ? .secondaryLabelColor : .labelColor
        parent.addSubview(field); return field
    }
    @discardableResult private func button(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, action: Selector, parent: NSView) -> NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; b.frame = NSRect(x:x,y:y,width:w,height:30); parent.addSubview(b); return b
    }
    private func makeMenuEditor() {
        menuPage.addSubview(ringEditor)
        ringEditor.onSelect = { [weak self] location in self?.cancelRecording(); self?.selection = location; self?.reloadFromStore() }
        ringEditor.onAdd = { [weak self] in self?.addChild(); self?.reloadFromStore() }
        editChildren = button("编辑子菜单",x:0,y:446,w:120,action:#selector(openChildren),parent:menuPage)
        addButton = button("＋",x:128,y:446,w:50,action:#selector(addChild),parent:menuPage)
        deleteButton = button("−",x:184,y:446,w:50,action:#selector(deleteChild),parent:menuPage)
        button("←",x:280,y:446,w:60,action:#selector(moveNodeUp),parent:menuPage)
        button("→",x:346,y:446,w:60,action:#selector(moveNodeDown),parent:menuPage)
        button("音量与亮度手感…",x:0,y:502,w:200,action:#selector(showRingSetup),parent:menuPage)
        text("名称",x:510,y:8,w:70,parent:menuPage)
        nameField.frame = NSRect(x:580,y:0,width:325,height:30); nameField.delegate = self; nameField.setAccessibilityLabel("所选菜单项名称"); menuPage.addSubview(nameField)
        text("动作",x:510,y:56,w:70,parent:menuPage)
        type.frame = NSRect(x:580,y:48,width:325,height:30); type.target = self; type.action = #selector(typeChanged); type.setAccessibilityLabel("所选菜单项功能类型"); menuPage.addSubview(type)
        let shortcutTitle = text("快捷键",x:510,y:104,w:70,parent:menuPage)
        recorder.frame = NSRect(x:580,y:96,width:255,height:32); recorder.onRecord = { [weak self] binding in self?.edit { $0.shortcut = binding } }; menuPage.addSubview(recorder)
        let clear = button("清除",x:842,y:96,w:64,action:#selector(clearShortcut),parent:menuPage)
        examples.frame = NSRect(x:580,y:140,width:325,height:30); examples.addItem(withTitle:"常用快捷键…")
        for preset in presets { examples.addItem(withTitle:preset.0 + "   " + preset.1.display) }
        examples.target = self; examples.action = #selector(exampleSelected); menuPage.addSubview(examples)
        shortcutControls = [shortcutTitle,recorder,clear,examples]
        text("图标",x:510,y:207,w:70,parent:menuPage)
        iconPreview.frame = NSRect(x:580,y:195,width:40,height:40); iconPreview.imageScaling = .scaleProportionallyUpOrDown; menuPage.addSubview(iconPreview)
        symbols.frame = NSRect(x:632,y:200,width:273,height:30)
        for pair in iconChoices { symbols.addItem(withTitle:pair.0); symbols.lastItem?.representedObject = pair.1; if !pair.1.isEmpty { symbols.lastItem?.image = DialIcons.image(named:pair.1) } }
        symbols.target = self; symbols.action = #selector(symbolChanged); symbols.setAccessibilityLabel("图标库"); menuPage.addSubview(symbols)
        button("选择图片…",x:580,y:251,w:155,action:#selector(importIcon),parent:menuPage)
        button("重置图标",x:746,y:251,w:159,action:#selector(resetIcon),parent:menuPage)
        templateIcon.frame = NSRect(x:580,y:297,width:325,height:26); templateIcon.target = self; templateIcon.action = #selector(templateChanged); menuPage.addSubview(templateIcon)
    }
    @objc private func openChildren() {
        ringEditor.showChildren()
        if !store.config.items[selection.root].children.isEmpty { selection.child = 0; reloadFromStore() }
    }
    @objc private func showRingSetup() { controller?.showWheelSetup(zoom: false) }
    private func makeSystemPage() {
        text("外观",x:0,y:0,w:400,bold:true,parent:systemPage)
        text("主题",x:0,y:38,w:90,parent:systemPage)
        theme.frame = NSRect(x:120,y:32,width:255,height:29); theme.addItems(withTitles:["明亮","深色"]); theme.target = self; theme.action = #selector(themeChanged); systemPage.addSubview(theme)
        text("高亮颜色",x:445,y:38,w:100,parent:systemPage); accent.frame = NSRect(x:560,y:31,width:120,height:30); accent.target = self; accent.action = #selector(accentChanged); systemPage.addSubview(accent)
        sliderRow("圆环大小",y:81,slider:scaleSlider,value:scaleText,action:#selector(scaleChanged))
        sliderRow("二级展开延迟",y:126,slider:delaySlider,value:delayText,action:#selector(delayChanged))
        text("圆环调节",x:0,y:208,w:400,bold:true,parent:systemPage)
        text("亮度屏幕",x:0,y:245,w:110,parent:systemPage); screens.frame = NSRect(x:120,y:239,width:575,height:29); screens.target = self; screens.action = #selector(screenChanged); screens.setAccessibilityLabel("亮度控制的屏幕"); systemPage.addSubview(screens)
        sliderRow("每格变化",y:291,slider:stepSlider,value:stepText,action:#selector(stepChanged)); stepSlider.numberOfTickMarks = 20; stepSlider.allowsTickMarkValuesOnly = true
        reverse.frame = NSRect(x:120,y:338,width:430,height:26); reverse.target = self; reverse.action = #selector(reverseChanged); systemPage.addSubview(reverse)
        extendedBlack.frame = NSRect(x:120,y:380,width:310,height:26); extendedBlack.target = self; extendedBlack.action = #selector(extendedBlackChanged); systemPage.addSubview(extendedBlack)
        button("恢复屏幕可见",x:560,y:376,w:170,action:#selector(restoreVisibility),parent:systemPage)
        text("权限",x:0,y:451,w:90,bold:true,parent:systemPage); permissionStatus.frame = NSRect(x:120,y:448,width:550,height:25); systemPage.addSubview(permissionStatus)
        permission.frame = NSRect(x:680,y:441,width:230,height:30); permission.bezelStyle = .rounded; permission.target = self; permission.action = #selector(authorize); systemPage.addSubview(permission)
    }

    private func sliderRow(_ label: String,y:CGFloat,slider:NSSlider,value:NSTextField,action:Selector) {
        text(label,x:0,y:y+6,w:115,parent:systemPage); slider.frame = NSRect(x:120,y:y,width:575,height:29); slider.target = self; slider.action = action; slider.setAccessibilityLabel(label); systemPage.addSubview(slider)
        value.frame = NSRect(x:715,y:y+5,width:150,height:22); systemPage.addSubview(value)
    }
    private var current: MenuItem { store.config.item(at:selection) ?? store.config.items[0] }
    private func edit(_ body: (inout MenuItem) -> Void) { store.config.update(at:selection,body) }
    func cancelRecording() { recorder.cancelRecording(); mouseRecorder.cancelRecording(); smoothPage?.cancelRecording() }
    func selectItem(id: UUID) {
        recorder.cancelRecording()
        for (root,item) in store.config.items.enumerated() {
            if item.id == id { selection = ItemLocation(root:root,child:nil); reloadFromStore(); return }
            if let child = item.children.firstIndex(where:{$0.id == id}) { selection = ItemLocation(root:root,child:child); reloadFromStore(); return }
        }
    }
    func reloadFromStore() {
        reloading = true
        if store.config.item(at:selection) == nil { selection.child = nil }
        ringEditor.config = store.config; ringEditor.selection = selection
        reloadInspector(); reloadSystem(); reloadMousePage(); smoothPage?.reload(); reloading = false
    }
    private func reloadInspector() {
        let item = current
        if nameField.currentEditor() == nil { nameField.stringValue = item.name }
        type.removeAllItems()
        for kind in DialAction.editable where selection.child == nil || kind != .submenu { type.addItem(withTitle:kind.title); type.lastItem?.representedObject = kind.rawValue; if kind == item.action { type.select(type.lastItem) } }
        recorder.binding = item.shortcut; recorder.updateTitle()
        for view in shortcutControls { view.isHidden = item.action != .shortcut }
        iconPreview.image = item.iconPNG.flatMap { NSImage(data:$0) } ?? DialIcons.image(named:item.effectiveSymbol)
        select(symbols,value:item.symbol ?? ""); templateIcon.state = item.templateIcon ? .on : .off
        addButton.isEnabled = store.config.items[selection.root].action == .submenu && store.config.items[selection.root].children.count < 8
        deleteButton.isEnabled = selection.child != nil
        editChildren.isEnabled = store.config.items[selection.root].action == .submenu
    }

    private func select(_ popup:NSPopUpButton,value:String) { if let item = popup.itemArray.first(where:{$0.representedObject as? String == value}) { popup.select(item) } }
    private func reloadSystem() {
        let c = store.config
        theme.selectItem(at:c.appearance.dark ? 1:0); accent.color = c.appearance.accent
        scaleSlider.doubleValue = c.appearance.scale*100; scaleText.stringValue = "\(Int((c.appearance.scale*100).rounded()))%"
        delaySlider.doubleValue = c.appearance.hoverDelay*1000; delayText.stringValue = "\(Int((c.appearance.hoverDelay*1000).rounded())) ms"
        stepSlider.doubleValue = c.ringWheel.step*100; stepText.stringValue = "\(Int((c.ringWheel.step*100).rounded()))%"
        reverse.state = c.reverseScroll ? .on:.off
        extendedBlack.state = c.brightnessControl.extendedRange ? .on:.off
        screens.removeAllItems(); screens.addItem(withTitle:"鼠标所在屏幕"); screens.lastItem?.representedObject = "pointer"
        for screen in HardwareDisplay.online() { screens.addItem(withTitle:screen.name); screens.lastItem?.representedObject = screen.uuid }
        if !screens.itemArray.contains(where:{$0.representedObject as? String == c.displayTarget}) { screens.addItem(withTitle:"所选屏幕未连接"); screens.lastItem?.representedObject = c.displayTarget }; select(screens,value:c.displayTarget)
        refreshPermission()
    }
    func refreshPermission() {
        let allowed = controller?.accessibilityGranted == true
        permissionStatus.stringValue = allowed ? "辅助功能已授权" : "媒体键、快捷键和鼠标映射需要授权"
        permission.isHidden = allowed
    }
    func controlTextDidChange(_ obj:Notification) { if obj.object as? NSTextField === nameField { edit { $0.name = nameField.stringValue } } }
    @objc private func tabChanged() { if tabs.selectedSegment != 1 { controller?.cancelMouseDetection() }; cancelRecording(); menuPage.isHidden = tabs.selectedSegment != 0; mousePage.isHidden = tabs.selectedSegment != 1; smoothPage.isHidden = tabs.selectedSegment != 2; systemPage.isHidden = tabs.selectedSegment != 3 }
    @objc private func typeChanged() {
        guard let raw = type.selectedItem?.representedObject as? String,let action = DialAction(rawValue:raw) else{return}
        edit { item in let old = item.action; item.action = action; if item.name == old.title || item.name.isEmpty { item.name = action.title }; if action == .submenu && item.children.isEmpty { item.children = [MenuItem.custom(1),MenuItem.custom(2),MenuItem.custom(3)] } }
    }
    @objc private func clearShortcut() { edit { $0.shortcut = nil } }
    @objc private func exampleSelected() { guard examples.indexOfSelectedItem > 0 else{return}; let p = presets[examples.indexOfSelectedItem-1]; edit { $0.name = p.0; $0.action = .shortcut; $0.shortcut = p.1; $0.symbol = p.2; $0.iconPNG = nil }; examples.selectItem(at:0) }
    @objc private func symbolChanged() { let raw = symbols.selectedItem?.representedObject as? String; edit { $0.symbol = raw; $0.iconPNG = nil } }
    @objc private func resetIcon() { edit { $0.symbol = nil; $0.iconPNG = nil; $0.templateIcon = true } }
    @objc private func templateChanged() { edit { $0.templateIcon = templateIcon.state == .on } }
    @objc private func importIcon() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.title = "选择图标（透明 PNG 更清晰）"
        guard picker.runModal() == .OK,let url = picker.url else{return}
        do {
            guard let image = NSImage(contentsOf:url),image.size.width > 0,image.size.height > 0 else { throw ControlFailure(message:"无法读取这张图片") }
            let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:96,pixelsHigh:96,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
            let factor = min(96/image.size.width,96/image.size.height); let size = NSSize(width:image.size.width*factor,height:image.size.height*factor)
            image.draw(in:NSRect(x:(96-size.width)/2,y:(96-size.height)/2,width:size.width,height:size.height)); NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using:.png,properties:[:]) else { throw ControlFailure(message:"无法生成图标") }
            edit { $0.iconPNG = data }
        } catch { showError(error) }
    }
    @objc private func addChild() { let root = selection.root; guard store.config.items[root].action == .submenu,store.config.items[root].children.count<8 else{return}; store.config.items[root].children.append(.custom(store.config.items[root].children.count+1)); selection.child = store.config.items[root].children.count-1 }
    @objc private func deleteChild() { guard let child = selection.child else{return}; let id = store.config.items[selection.root].children[child].id.uuidString; store.config.items[selection.root].children.remove(at:child); for key in Array(store.config.mouseBindings.keys) where store.config.mouseBindings[key] == "item:"+id { store.config.mouseBindings[key] = "none" }; selection.child = store.config.items[selection.root].children.isEmpty ? nil : min(child, store.config.items[selection.root].children.count - 1); reloadFromStore(); ringEditor.showChildren() }
    private func move(_ direction:Int) { if let child = selection.child { let next = child+direction; guard store.config.items[selection.root].children.indices.contains(next) else{return}; store.config.items[selection.root].children.swapAt(child,next); selection.child = next } else { let next = selection.root+direction; guard (0..<8).contains(next) else{return}; store.config.items.swapAt(selection.root,next); selection.root = next } }
    @objc private func moveNodeUp() { move(-1) }; @objc private func moveNodeDown() { move(1) }
    @objc private func themeChanged() { store.config.appearance.theme = theme.indexOfSelectedItem == 1 ? "dark":"light" }
    @objc private func accentChanged() { store.config.appearance.accentHex = accent.color.hex }
    @objc private func scaleChanged() { store.config.appearance.scale = scaleSlider.doubleValue.rounded()/100 }
    @objc private func delayChanged() { store.config.appearance.hoverDelay = delaySlider.doubleValue.rounded()/1000 }
    @objc private func screenChanged() { if let id = screens.selectedItem?.representedObject as? String { store.config.displayTarget = id } }
    @objc private func extendedBlackChanged() { controller?.restoreDisplayVisibility(); store.config.brightnessControl.extendedRange = extendedBlack.state == .on }
    @objc private func restoreVisibility() { controller?.restoreDisplayVisibility() }
    @objc private func reverseChanged() { store.config.reverseScroll = reverse.state == .on }
    @objc private func stepChanged() { store.config.ringWheel.step = stepSlider.doubleValue.rounded()/100 }
    @objc private func authorize() { controller?.requestPermissions() }
    @objc private func exportConfig() { let picker = NSSavePanel(); picker.allowedContentTypes = [.json]; picker.nameFieldStringValue = "鼠环-配置.json"; if picker.runModal() == .OK,let url = picker.url { do { try store.exportData().write(to:url,options:.atomic) } catch { showError(error) } } }
    @objc private func importConfig() { let picker = NSOpenPanel(); picker.allowedContentTypes = [.json]; picker.allowsMultipleSelection = false; if picker.runModal() == .OK,let url = picker.url { do { try store.importData(Data(contentsOf:url)); selection = ItemLocation(root:0,child:nil) } catch { showError(error) } } }

    func showMousePage(button:Int? = nil) { if let button { selectedMouseButton = button; reloadMousePage() }; tabs.selectedSegment = 1; tabChanged() }
    private func makeMousePage() {
        mouseEnabled.frame = NSRect(x:0,y:0,width:390,height:26); mouseEnabled.target = self; mouseEnabled.action = #selector(mouseEnabledChanged); mousePage.addSubview(mouseEnabled)
        mouseLiveStatus.frame = NSRect(x:400,y:3,width:515,height:24); mouseLiveStatus.font = .systemFont(ofSize:12); mouseLiveStatus.textColor = .secondaryLabelColor; mousePage.addSubview(mouseLiveStatus)
        mouseButton.frame = NSRect(x:0,y:44,width:260,height:30); mouseButton.target = self; mouseButton.action = #selector(mouseButtonChanged); mouseButton.setAccessibilityLabel("要配置的鼠标按键"); mousePage.addSubview(mouseButton)
        button("识别按键…",x:280,y:44,w:125,action:#selector(detectButton),parent:mousePage)
        detectStatus.stringValue = "物理位置不确定时，点“识别按键”"
        detectStatus.frame = NSRect(x:420,y:49,width:500,height:25); detectStatus.font = .systemFont(ofSize:11); detectStatus.textColor = .secondaryLabelColor; mousePage.addSubview(detectStatus)
        text("单击",x:0,y:104,w:100,parent:mousePage)
        mouseClick.frame = NSRect(x:120,y:97,width:645,height:30); mouseClick.target = self; mouseClick.action = #selector(mouseClickChanged); mouseClick.setAccessibilityLabel("鼠标单击动作"); mousePage.addSubview(mouseClick)
        text("快捷键",x:0,y:150,w:100,parent:mousePage)
        mouseRecorder.frame = NSRect(x:120,y:141,width:510,height:32)
        mouseRecorder.onRecord = { [weak self] binding in
            guard let self else{return}; self.store.config.mouseHabits.shortcuts[String(self.selectedMouseButton)] = binding; self.store.config.mouseBindings[String(self.selectedMouseButton)] = "custom"
        }; mousePage.addSubview(mouseRecorder)
        button("清除",x:650,y:142,w:115,action:#selector(clearMouseShortcut),parent:mousePage)
        button("测试单击",x:780,y:142,w:125,action:#selector(testMouseClick),parent:mousePage)
        text("按住＋滚轮",x:0,y:196,w:115,parent:mousePage)
        mouseWheel.frame = NSRect(x:120,y:189,width:510,height:30)
        for kind in HeldWheelAction.allCases where kind != .volume && kind != .brightness { mouseWheel.addItem(withTitle:kind.title); mouseWheel.lastItem?.representedObject = kind.rawValue }
        mouseWheel.target = self; mouseWheel.action = #selector(mouseWheelChanged); mouseWheel.setAccessibilityLabel("按住鼠标键后的滚轮功能"); mousePage.addSubview(mouseWheel)
        wheelReverse.frame = NSRect(x:660,y:191,width:125,height:26); wheelReverse.target = self; wheelReverse.action = #selector(mouseWheelReverseChanged)
        wheelReverse.setAccessibilityLabel("当前鼠标键的滚轮反向"); wheelReverse.toolTip = "只影响当前按键的按住＋滚轮；与下方全局缩放、桌面方向叠加。"; mousePage.addSubview(wheelReverse)
        text("按住＋移动",x:0,y:242,w:115,parent:mousePage)
        mouseMove.frame = NSRect(x:120,y:235,width:510,height:30)
        for kind in HeldMoveAction.allCases { mouseMove.addItem(withTitle:kind.title); mouseMove.lastItem?.representedObject = kind.rawValue }
        mouseMove.target = self; mouseMove.action = #selector(mouseMoveChanged); mouseMove.setAccessibilityLabel("按住鼠标键后的移动功能"); mousePage.addSubview(mouseMove)
        moveReverse.frame = NSRect(x:660,y:237,width:125,height:26); moveReverse.target = self; moveReverse.action = #selector(mouseMoveReverseChanged)
        moveReverse.setAccessibilityLabel("当前鼠标键的移动反向"); moveReverse.toolTip = "只影响当前鼠标键的按住＋移动；同时反转左右和上下方向。"; mousePage.addSubview(moveReverse)
        mouseMoveHelp.frame = NSRect(x:120,y:279,width:780,height:35); mouseMoveHelp.font = .systemFont(ofSize:12); mouseMoveHelp.textColor = .secondaryLabelColor; mousePage.addSubview(mouseMoveHelp)
        thumbSpaces.frame = NSRect(x:0,y:337,width:450,height:26); thumbSpaces.target = self; thumbSpaces.action = #selector(thumbSpacesChanged); mousePage.addSubview(thumbSpaces)
        spacesReverse.frame = NSRect(x:660,y:337,width:230,height:26); spacesReverse.target = self; spacesReverse.action = #selector(spacesReverseChanged); mousePage.addSubview(spacesReverse)
        button("缩放手感…",x:0,y:398,w:160,action:#selector(showWheelSetup),parent:mousePage)

    }
    private func reloadMousePage() {
        let config = store.config, habits = config.mouseHabits, key = String(selectedMouseButton)
        let buttons = Set([2,3,4,5,6,selectedMouseButton] + config.mouseBindings.keys.compactMap(Int.init) + habits.wheel.keys.compactMap(Int.init) + habits.move.keys.compactMap(Int.init)).sorted()
        mouseButton.removeAllItems()
        for number in buttons {
            mouseButton.addItem(withTitle:MouseButtonIdentity.name(number)); mouseButton.lastItem?.tag = number
        }
        mouseButton.selectItem(withTag:selectedMouseButton)
        detectStatus.stringValue = "当前配置："+MouseButtonIdentity.name(selectedMouseButton)
        mouseEnabled.state = habits.enabled ? .on:.off
        mouseClick.removeAllItems()
        for pair in [("保持原点击","none"),("打开 / 收起圆环","showRing"),("自定义键盘快捷键","custom"),("模拟中键点击","middleClick"),("静音 / 取消静音","mute"),("播放 / 暂停","playPause"),("上一首","previous"),("下一首","next")] {
            mouseClick.addItem(withTitle:pair.0); mouseClick.lastItem?.representedObject = pair.1
        }
        for (index,preset) in mouseDefaults.enumerated() { mouseClick.addItem(withTitle:preset.0+"   "+preset.1.display); mouseClick.lastItem?.representedObject = "preset:\(index)" }
        for (title,item) in config.flattened where item.action != .none {
            mouseClick.addItem(withTitle:"圆环 · "+title); mouseClick.lastItem?.representedObject = "item:"+item.id.uuidString
        }
        select(mouseClick,value:config.mouseBindings[key] ?? "none")
        mouseRecorder.binding = habits.shortcuts[key]; mouseRecorder.updateTitle()
        select(mouseWheel,value:(habits.wheel[key] ?? .none).rawValue)
        wheelReverse.state = (habits.reverseWheel[key] ?? false) ? .on:.off; wheelReverse.isEnabled = (habits.wheel[key] ?? .none) != .none
        reloadMoveOptions()
        thumbSpaces.state = habits.thumbSpaces ? .on:.off; spacesReverse.state = habits.reverseSpaces ? .on:.off
    }
    private func reloadMoveOptions() {
        let habits = store.config.mouseHabits, key = String(selectedMouseButton)
        let kind = habits.move[key] ?? .none, reversed = habits.reverseMove[key] ?? false
        select(mouseMove,value:kind.rawValue); moveReverse.state = reversed ? .on:.off; moveReverse.isEnabled = kind != .none
        switch kind {
        case .windows:
            mouseMoveHelp.stringValue = reversed
                ? "已反向：左 → ⌃→，右 → ⌃←；上 → ⌃↓，下 → ⌃↑。每次按住触发一次，松开后可再次操作。"
                : "左／右切换桌面（⌃←／⌃→）；上开调度中心（⌃↑）；下看应用窗口（⌃↓）。每次按住触发一次。"
        case .pan:
            mouseMoveHelp.stringValue = "按住当前按键移动鼠标可二维滚动；勾选“反向”后，横向和纵向一起反转。"
        case .none:
            mouseMoveHelp.stringValue = ""
        }
    }
    @objc private func mouseMoveReverseChanged() {
        store.config.mouseHabits.reverseMove[String(selectedMouseButton)] = moveReverse.state == .on
        reloadMoveOptions()
    }
    @objc private func mouseButtonChanged() { cancelRecording(); selectedMouseButton = mouseButton.selectedItem?.tag ?? 2; reloadMousePage() }
    @objc private func mouseEnabledChanged() { store.config.mouseHabits.enabled = mouseEnabled.state == .on; store.config.mouseHabits.manuallyPaused = mouseEnabled.state != .on }
    @objc private func mouseClickChanged() {
        guard let raw = mouseClick.selectedItem?.representedObject as? String else{return}
        let key = String(selectedMouseButton)
        if raw.hasPrefix("preset:"),let index = Int(raw.dropFirst(7)),mouseDefaults.indices.contains(index) {
            var binding = mouseDefaults[index].1; binding.name = mouseDefaults[index].0
            store.config.mouseHabits.shortcuts[key] = binding; store.config.mouseBindings[key] = "custom"
        } else { store.config.mouseBindings[key] = raw }
    }
    @objc private func clearMouseShortcut() { store.config.mouseHabits.shortcuts.removeValue(forKey:String(selectedMouseButton)) }
    @objc private func mouseWheelReverseChanged() { store.config.mouseHabits.reverseWheel[String(selectedMouseButton)] = wheelReverse.state == .on }
    @objc private func mouseWheelChanged() { if let raw = mouseWheel.selectedItem?.representedObject as? String,let kind = HeldWheelAction(rawValue:raw) { store.config.mouseHabits.wheel[String(selectedMouseButton)] = kind; store.config.mouseHabits.activateConfiguredRules(); wheelReverse.isEnabled = kind != .none } }
    @objc private func mouseMoveChanged() { if let raw = mouseMove.selectedItem?.representedObject as? String,let kind = HeldMoveAction(rawValue:raw) { store.config.mouseHabits.move[String(selectedMouseButton)] = kind; store.config.mouseHabits.activateConfiguredRules(); reloadMoveOptions() } }
    @objc private func thumbSpacesChanged() { store.config.mouseHabits.thumbSpaces = thumbSpaces.state == .on; store.config.mouseHabits.activateConfiguredRules() }
    @objc private func spacesReverseChanged() { store.config.mouseHabits.reverseSpaces = spacesReverse.state == .on }
    func setMouseStatus(_ value:String) { mouseLiveStatus.stringValue = value }
    @objc private func testMouseClick() { controller?.testMouseClick(selectedMouseButton) }
    @objc private func showWheelSetup() { controller?.showWheelSetup(zoom: true) }
    @objc private func detectButton() {
        cancelRecording(); detectStatus.stringValue = "8 秒内按下要配置的中键 / 侧键…"
        let started = controller?.detectMouseButton(receive:{ [weak self] number in
            guard let self else{return}; self.selectedMouseButton = number; self.reloadMousePage()
        }, timeout:{ [weak self] in self?.detectStatus.stringValue = "未收到按键，请检查该按键是否被其他鼠标工具占用" }) ?? false
        if !started { detectStatus.stringValue = "请先在“外观”授权辅助功能" }
    }

    private func showError(_ error:Error) { let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = error.localizedDescription; alert.runModal() }
}

import AppKit
import Foundation

let output = CommandLine.arguments[1]
let app = NSApplication.shared
let store = SettingsStore(persistent: false)
let controller = AppController(store: store)
controller.controls = AsyncControls(audio: controller.audio, brightness: controller.brightness, preview: true)
func renderView(_ view: NSView, size: NSSize, name: String) throws {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/" + name))
}
try store.exportData().write(to: URL(fileURLWithPath: output + "/Orbit-Dial-示例配置.json"))
let ring = RingView(frame: NSRect(origin: .zero, size: RingGeometry.size))
controller.ring = ring; ring.controller = controller; ring.loadConfiguration()
ring.setProgress(.volume, value: 0.48); ring.setProgress(.brightness, value: 0.72)
func renderRing(_ name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1040, pixelsHigh: 1040, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.cgContext.scaleBy(x: 2, y: 2); context.cgContext.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
    context.cgContext.fill(NSRect(origin: .zero, size: RingGeometry.size)); ring.layer!.render(in: context.cgContext)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/" + name))
}
ring.prepare(); try renderRing("圆环-待机.png")
ring.movePointer(to: RingGeometry.point(0)); ring.setStatus("音量 · 48%")
try renderRing("圆盘预览.png")
ring.openFolder(2); ring.movePointer(to: RingGeometry.childPoint(parent: 2, index: 1, count: 3))
try renderRing("二级菜单预览.png")
let settings = SettingsView(store: store, controller: controller)
settings.selectItem(id: store.config.items[6].children[0].id)
try renderView(settings, size: NSSize(width: 980, height: 660), name: "设置预览.png")

settings.selectItem(id:store.config.items[0].id)
try renderView(settings, size:NSSize(width:980,height:660),name:"圆环设置.png")
let beforeMousePreview = store.config
store.config.mouseHabits = .screenshot
store.config.mouseBindings["2"] = "custom"
store.config.mouseBindings["6"] = "showRing"
settings.reloadFromStore(); settings.showMousePage(button:3)
try renderView(settings, size:NSSize(width:980,height:660),name:"鼠标与滚轮预览.png")
try store.exportData().write(to:URL(fileURLWithPath:output+"/Orbit-Dial-鼠标习惯示例.json"))

func descendantsForPreview(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantsForPreview) }
let tabsForPreview = descendantsForPreview(settings).compactMap { $0 as? NSSegmentedControl }.first!
tabsForPreview.selectedSegment = 3; _ = app.sendAction(tabsForPreview.action!,to:tabsForPreview.target,from:tabsForPreview)
try renderView(settings,size:NSSize(width:980,height:660),name:"亮度与外观预览.png")
tabsForPreview.selectedSegment = 2; _ = app.sendAction(tabsForPreview.action!,to:tabsForPreview.target,from:tabsForPreview)
try renderView(settings,size:NSSize(width:980,height:660),name:"平滑滚动-全局设置.png")
store.config.smoothScroll.applications = [ScrollApplication(bundleID:"com.example.Reader",name:"阅读器",useGlobal:false,options:ScrollTuning())]
settings.reloadFromStore()
let appTable = descendantsForPreview(settings).compactMap { $0 as? NSTableView }.first!
appTable.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
try renderView(settings,size:NSSize(width:980,height:660),name:"平滑滚动-应用设置.png")
// Exercise public smoothing controls through native actions.
var smoothUIChecks = 0
let distanceControl = descendantsForPreview(settings).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "每格距离" }!
distanceControl.doubleValue = 73; _ = app.sendAction(distanceControl.action!,to:distanceControl.target,from:distanceControl)
if store.config.smoothScroll.applications[0].options.pixelsPerStep != 73 || store.config.smoothScroll.global.pixelsPerStep != 36 { fatalError("app tuning leaked into global profile") }; smoothUIChecks += 1
let inherited = descendantsForPreview(settings).compactMap { $0 as? NSButton }.first { $0.title == "沿用全局手感" }!
inherited.state = .on; _ = app.sendAction(inherited.action!,to:inherited.target,from:inherited)
if store.config.smoothScroll.tuning(for:"com.example.Reader")?.pixelsPerStep != 36 { fatalError("global inheritance failed") }; smoothUIChecks += 1
inherited.state = .off; _ = app.sendAction(inherited.action!,to:inherited.target,from:inherited)
if store.config.smoothScroll.tuning(for:"com.example.Reader")?.pixelsPerStep != 73 { fatalError("inheritance erased independent settings") }; smoothUIChecks += 1
let globalSwitch = descendantsForPreview(settings).compactMap { $0 as? NSButton }.first { $0.title == "全局平滑滚动" }!
globalSwitch.state = .off; _ = app.sendAction(globalSwitch.action!,to:globalSwitch.target,from:globalSwitch)
if store.config.smoothScroll.enabled || !distanceControl.isEnabled { fatalError("global smoothing switch incorrectly disabled independent application tuning") }; smoothUIChecks += 1
globalSwitch.state = .on; _ = app.sendAction(globalSwitch.action!,to:globalSwitch.target,from:globalSwitch)
let converter = descendantsForPreview(settings).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "转为横向控制键" }!
converter.selectItem(withTag:2); _ = app.sendAction(converter.action!,to:converter.target,from:converter)
if store.config.smoothScroll.applications[0].options.horizontalKey != ScrollTrigger.choices[2] { fatalError("control key selection did not persist") }; smoothUIChecks += 1
let previousZoom = store.config.mouseHabits.adaptation, previousRing = store.config.ringWheel
let curveDuration = descendantsForPreview(settings).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "过渡时长" }!
curveDuration.doubleValue = 270; _ = app.sendAction(curveDuration.action!,to:curveDuration.target,from:curveDuration)
if store.config.mouseHabits.adaptation != previousZoom || store.config.ringWheel != previousRing { fatalError("smooth tuning altered calibration") }; smoothUIChecks += 1
try renderView(settings,size:NSSize(width:980,height:660),name:"平滑滚动-应用独立手感.png")
print("PASS: \(smoothUIChecks) independent smooth-scrolling UI controls")
settings.showMousePage(button:3)

// Exercise settings controls as a user would, using an in-memory configuration.
var settingsChecks = 0
func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func selectMouse(_ label:String,_ value:String) {
    let popup = descendants(settings).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label }!
    let item = popup.itemArray.first { $0.representedObject as? String == value }!
    popup.select(item); _ = app.sendAction(popup.action!,to:popup.target,from:popup)
}
settings.showMousePage(button:8)
let selector = descendants(settings).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "要配置的鼠标按键" }!
if selector.selectedItem?.tag != 8 || selector.title != MouseButtonIdentity.name(8) { fatalError("mouse selector identity mismatch") }; settingsChecks += 1
selector.selectItem(withTag:3); _ = app.sendAction(selector.action!,to:selector.target,from:selector)
if selector.selectedItem?.tag != 3 || selector.title != MouseButtonIdentity.name(3) { fatalError("selection changed after rebuilding menu") }; settingsChecks += 1
settings.showMousePage(button:8)
selectMouse("鼠标单击动作","showRing")
selectMouse("按住鼠标键后的滚轮功能","rotate")
selectMouse("按住鼠标键后的移动功能","pan")
if store.config.mouseBindings["8"] != "showRing" || store.config.mouseHabits.wheel["8"] != .rotate || store.config.mouseHabits.move["8"] != .pan { fatalError("mouse editor did not save independent auxiliary binding") }; settingsChecks += 1
selectMouse("按住鼠标键后的移动功能","windows")
let reverseMove = descendants(settings).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "当前鼠标键的移动反向" }!
if !reverseMove.isEnabled || reverseMove.state != .off { fatalError("move reversal did not initialize normally") }; settingsChecks += 1
reverseMove.state = .on; _ = app.sendAction(reverseMove.action!,to:reverseMove.target,from:reverseMove)
if store.config.mouseHabits.reverseMove["8"] != true || store.config.mouseHabits.move["8"] != .windows { fatalError("move reversal did not save to selected button") }; settingsChecks += 1
settings.showMousePage(button:3)
if reverseMove.state != .off || reverseMove.isEnabled { fatalError("move reversal leaked to another button") }; settingsChecks += 1
settings.showMousePage(button:8)
if reverseMove.state != .on || !reverseMove.isEnabled { fatalError("move reversal lost on button change") }; settingsChecks += 1
selectMouse("按住鼠标键后的移动功能","none")
if reverseMove.isEnabled { fatalError("ordinary movement exposed an active reversal") }; settingsChecks += 1
selectMouse("按住鼠标键后的移动功能","windows")
if reverseMove.state != .on || !reverseMove.isEnabled { fatalError("move reversal lost on action change") }; settingsChecks += 1
try renderView(settings,size:NSSize(width:980,height:660),name:"桌面切换手势预览.png")
settings.showMousePage(button:8)
let wheelReverse = descendants(settings).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "当前鼠标键的滚轮反向" }!
wheelReverse.state = .on; _ = app.sendAction(wheelReverse.action!,to:wheelReverse.target,from:wheelReverse)
if store.config.mouseHabits.reverseWheel["8"] != true { fatalError("wheel direction was not saved to selected button") }; settingsChecks += 1
settings.showMousePage(button:3)
if wheelReverse.state != .off { fatalError("wheel direction leaked to another button") }; settingsChecks += 1
settings.showMousePage(button:8)
if wheelReverse.state != .on { fatalError("wheel direction lost on selection") }; settingsChecks += 1
selectMouse("按住鼠标键后的滚轮功能","none")
if wheelReverse.isEnabled { fatalError("wheel direction remained enabled for normal wheel") }; settingsChecks += 1
selectMouse("按住鼠标键后的滚轮功能","horizontal")
if !wheelReverse.isEnabled || wheelReverse.state != .on { fatalError("wheel direction lost on action change") }; settingsChecks += 1
try renderView(settings,size:NSSize(width:980,height:660),name:"滚轮反向预览.png")
selectMouse("按住鼠标键后的滚轮功能","rotate")
settings.showMousePage(button:2)
selectMouse("鼠标单击动作","preset:0")
if store.config.mouseBindings["2"] != "custom" || store.config.mouseHabits.shortcuts["2"]?.display != "⌃⌘D" || store.config.mouseHabits.wheel["8"] != .rotate { fatalError("shortcut preset overwrote another button") }; settingsChecks += 1
let forbidden = ["填入截图习惯","试用圆环","撤销导入 / 示例","加载示例布局","键盘＋滚轮缩放"]
if descendants(settings).contains(where: { v in forbidden.contains((v as? NSButton)?.title ?? (v as? NSTextField)?.stringValue ?? "") }) { fatalError("retired UI still exists") }; settingsChecks += 1
if descendants(settings).contains(where: { $0 is NSOutlineView }) { fatalError("list editor was not replaced") }; settingsChecks += 1
let editor = descendants(settings).compactMap { $0 as? RingEditorView }.first!
let editorNode = descendants(editor).compactMap { $0 as? NSButton }.first { $0.tag == 1 && $0.title == store.config.items[1].title }!
_ = app.sendAction(editorNode.action!,to:editorNode.target,from:editorNode)
if !descendants(settings).compactMap({ $0 as? NSTextField }).contains(where: { $0.accessibilityLabel() == "所选菜单项名称" && $0.stringValue == store.config.items[1].title }) { fatalError("ring selection did not update inspector") }; settingsChecks += 1

settings.selectItem(id:store.config.items[2].id)
let editChildren = descendants(settings).compactMap { $0 as? NSButton }.first { $0.title == "编辑子菜单" }!
_ = app.sendAction(editChildren.action!,to:editChildren.target,from:editChildren)
if editor.parent != 2 || editor.selection.child != 0 { fatalError("submenu entry did not select its first child") }; settingsChecks += 1
let addNode = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "添加" && !$0.isHidden }!
_ = app.sendAction(addNode.action!,to:addNode.target,from:addNode)
if store.config.items[2].children.count != 4 || editor.selection.child != 3 { fatalError("ring add did not select new child") }; settingsChecks += 1
let addedID = store.config.items[2].children[3].id
let moveNode = descendants(settings).compactMap { $0 as? NSButton }.first { $0.title == "←" }!
_ = app.sendAction(moveNode.action!,to:moveNode.target,from:moveNode); settings.reloadFromStore()
if store.config.items[2].children[2].id != addedID || editor.selection.child != 2 { fatalError("ring reorder changed selected identity") }; settingsChecks += 1
let deleteNode = descendants(settings).compactMap { $0 as? NSButton }.first { $0.title == "−" }!
_ = app.sendAction(deleteNode.action!,to:deleteNode.target,from:deleteNode)
if editor.parent != 2 || store.config.items[2].children.count != 3 || store.config.items[2].children.contains(where:{$0.id == addedID}) { fatalError("delete did not stay in the submenu ring") }; settingsChecks += 1
let backNode = descendants(editor).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "返回主圆环" }!
_ = app.sendAction(backNode.action!,to:backNode.target,from:backNode)
if editor.parent != nil || editor.selection.child != nil || editor.selection.root != 2 { fatalError("editor center did not return to root") }; settingsChecks += 1

var adaptationChecks = 0
let workingZoom = WheelProfile(units:["raw":2],samples:20,variation:0,source:"raw")
let wordFit = AppZoomCalibration(gain:1,before:100,after:110,physicalSteps:1,step:0.1,verified:true)
store.config.mouseHabits.adaptation.zoomProfile = workingZoom
store.config.mouseHabits.adaptation.appZoom["com.microsoft.Word"] = wordFit
let adaptation = WheelSetupView(store:store,zoom:false)
let primary = descendants(adaptation).compactMap { $0 as? NSButton }.first { $0.title == "开始学习" }!
_ = app.sendAction(primary.action!,to:primary.target,from:primary)
for (round,sign) in [1.0,-1.0].enumerated() {
    if primary.isEnabled { fatalError("empty learning round accepted") }; adaptationChecks += 1
    for i in 0..<10 {
      for fragment in 0..<2 {
        let pulse = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:2,wheel1:sign>0 ? 2:-2,wheel2:0,wheel3:0)!
        pulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:sign*3)
        adaptation.receive(pulse,time:Double(round*4)+Double(i)*0.2+Double(fragment)*0.01)
      }
      adaptation.finishLearningBurst(at:Double(round*4)+Double(i)*0.2+0.11)
    }
    let side = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:2,wheel1:0,wheel2:100,wheel3:0)!
    adaptation.receive(side,time:1)
}
if primary.title != "完成" || store.config.ringWheel.profile.units["raw"] != 6 || store.config.ringWheel.profile.samples != 20 { fatalError("ring learning failed") }; adaptationChecks += 1
if store.config.mouseHabits.adaptation.zoomProfile != workingZoom || store.config.mouseHabits.adaptation.appZoom["com.microsoft.Word"] != wordFit { fatalError("ring learning changed zoom") }; adaptationChecks += 1
let learnedPulse = CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:2,wheel1:4,wheel2:0,wheel3:0)!
learnedPulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:6)
adaptation.receive(learnedPulse,time:20)
if !descendants(adaptation).compactMap({$0 as? NSTextField}).contains(where:{$0.stringValue.contains("音量 60%")}) { fatalError("ring learned notch does not equal ten points") }; adaptationChecks += 1
try renderView(adaptation,size:NSSize(width:680,height:616),name:"音量与亮度-学习完成.png")
let ringBeforeZoom = store.config.ringWheel
let zoomSetup = WheelSetupView(store:store,zoom:true)
let zoomPrimary = descendants(zoomSetup).compactMap { $0 as? NSButton }.first { $0.title == "开始学习" }!
_ = app.sendAction(zoomPrimary.action!,to:zoomPrimary.target,from:zoomPrimary)
for (round,sign) in [1.0,-1.0].enumerated() {
    for i in 0..<10 {
        for fragment in 0..<2 { let pulse = learnedPulse.copy()!; pulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:sign); zoomSetup.receive(pulse,time:Double(round*4)+Double(i)*0.2+Double(fragment)*0.01) }
        zoomSetup.finishLearningBurst(at:Double(round*4)+Double(i)*0.2+0.11)
    }
}
if store.config.ringWheel != ringBeforeZoom || store.config.mouseHabits.adaptation.zoomProfile?.units["raw"] != 2 { fatalError("zoom learning changed ring or failed to save") }; adaptationChecks += 1
try renderView(WheelSetupView(store:store,zoom:true),size:NSSize(width:680,height:616),name:"缩放手感预览.png")
controller.panel = DialPanel(contentRect:NSRect(origin:.zero,size:RingGeometry.size),styleMask:.borderless,backing:.buffered,defer:false)
controller.panel.isReleasedWhenClosed = false; controller.panel.alphaValue = 0; controller.panel.orderFront(nil)
for action:DialAction in [.volume,.brightness] {
    ring.prepare(armedAction:action)
    let before = controller.controls.cache[action]!.value!
    let pulse = learnedPulse.copy()!; pulse.location = CGPoint(x:-10000,y:-10000)
    ring.scrollWheel(with:NSEvent(cgEvent:pulse)!)
    if abs(controller.controls.cache[action]!.value!-before-0.1)>0.000001 { fatalError("actual ring does not use independent level profile") }; adaptationChecks += 1
}
let savedProfile = store.config.ringWheel.profile; store.config.ringWheel.profile = WheelProfile()
for action:DialAction in [.volume,.brightness] {
    ring.prepare(armedAction:action)
    let before = controller.controls.cache[action]!.value!
    for _ in 0..<8 { let pulse = learnedPulse.copy()!; pulse.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:8); pulse.location = CGPoint(x:-10000,y:-10000); ring.scrollWheel(with:NSEvent(cgEvent:pulse)!) }
    if abs(controller.controls.cache[action]!.value!-before-0.1)>0.000001 { fatalError("unlearned ring burst jumped") }; adaptationChecks += 1
}
store.config.ringWheel.profile = savedProfile
ring.prepare(armedAction:.volume)
let beforeSynthetic = controller.controls.cache[.volume]!.value!

controller.panel.orderOut(nil)
let beforeOutside = controller.controls.cache[.volume]!.value!
controller.adjustContinuous(.volume,delta:0.5)
if controller.controls.cache[.volume]!.value != beforeOutside { fatalError("levels changed outside visible ring") }; adaptationChecks += 1

// Confirm that AppKit's actual scroll view moves horizontally, with no vertical leakage.
let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:400,height:220))
scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
scroll.documentView = NSView(frame:NSRect(x:0,y:0,width:2000,height:1800))
let scrollWindow = NSWindow(contentRect:scroll.frame,styleMask:.borderless,backing:.buffered,defer:false)
scrollWindow.isReleasedWhenClosed = false; scrollWindow.contentView = scroll; scrollWindow.alphaValue = 0; scrollWindow.orderFront(nil); scroll.layoutSubtreeIfNeeded()
scroll.contentView.scroll(to:NSPoint(x:400,y:400)); scroll.reflectScrolledClipView(scroll.contentView)
let startPosition = scroll.contentView.bounds.origin
let horizontalPulse = MouseEvents.horizontal(from:learnedPulse)!
scroll.scrollWheel(with:NSEvent(cgEvent:horizontalPulse)!)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.35))
let endPosition = scroll.contentView.bounds.origin
if startPosition.x == endPosition.x || startPosition.y != endPosition.y { fatalError("actual NSScrollView did not perform pure horizontal scrolling: \(startPosition) -> \(endPosition)") }; adaptationChecks += 1
let beforeSparse = scroll.contentView.bounds.origin
let rawOnly = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:0,wheel2:0,wheel3:0)!
rawOnly.setDoubleValueField(.scrollWheelEventRawDeltaAxis1,value:8)
scroll.scrollWheel(with:NSEvent(cgEvent:MouseEvents.horizontal(from:rawOnly)!)!)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
let afterSparse = scroll.contentView.bounds.origin
if beforeSparse.x == afterSparse.x || beforeSparse.y != afterSparse.y { fatalError("sparse Logitech-like report did not move a real NSScrollView horizontally") }; adaptationChecks += 1
scroll.scrollWheel(with:NSEvent(cgEvent:MouseEvents.horizontal(from:rawOnly,reverse:true)!)!)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
let reversedPosition = scroll.contentView.bounds.origin
if (reversedPosition.x-afterSparse.x)*(afterSparse.x-beforeSparse.x)>=0 || reversedPosition.y != afterSparse.y { fatalError("reversed sparse horizontal scrolling failed to change direction in NSScrollView") }; adaptationChecks += 1
scrollWindow.orderOut(nil)
print("PASS: \(adaptationChecks) guided adaptation and NSScrollView checks (two rounds, auto-save, zoom preservation, empty-profile ring protection, sparse horizontal native displacement and reversal).")
store.config = beforeMousePreview
print("PASS: \(settingsChecks) native settings editor checks (arbitrary button, independent action/hold, preset isolation).")

store.config.appearance.theme = "dark"; store.config.appearance.accentHex = "#78C8AD"
ring.loadConfiguration(); ring.prepare(); ring.openFolder(6)
ring.movePointer(to: RingGeometry.childPoint(parent: 6, index: 0, count: 3))
try renderRing("外观自定义预览.png")

// Show the three native vector additions at both normal and selected contrast.
let iconRep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1080,pixelsHigh:360,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
iconRep.size = NSSize(width:720,height:240)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:iconRep)
NSColor(calibratedWhite:0.95,alpha:1).setFill(); NSRect(x:0,y:0,width:720,height:240).fill()
for (index,pair) in DialIcons.additions.enumerated() {
    let x = CGFloat(index)*240+120
    for (offset,selected) in [(-44.0,false),(44.0,true)] {
        let circle = NSRect(x:x+offset-32,y:103,width:64,height:64)
        (selected ? NSColor.black : NSColor.white).setFill(); NSBezierPath(ovalIn:circle).fill()
        let image = DialIcons.image(named:pair.1)!
        let tinted = NSImage(size:image.size,flipped:false) { rect in
            image.draw(in:rect)
            (selected ? NSColor.white : NSColor.black).setFill(); rect.fill(using:.sourceIn)
            return true
        }
        tinted.draw(in:NSRect(x:x+offset-19,y:116,width:38,height:38))
    }
    let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.black]
    let label = pair.0.replacingOccurrences(of:"剪贴板 · ",with:"")
    let size = label.size(withAttributes:attributes)
    label.draw(at:NSPoint(x:x-size.width/2,y:55),withAttributes:attributes)
}
NSGraphicsContext.restoreGraphicsState()
try iconRep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output+"/剪贴板图标预览.png"))

// Full warm-cache pointer path: real controller, cached layers, simulated backend, no system writes.
ring.prepare()
var samples: [Double] = []; samples.reserveCapacity(8000)
for i in 0..<8000 {
    let start = DispatchTime.now().uptimeNanoseconds
    ring.movePointer(to: RingGeometry.point(i % 8))
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
let sorted = samples.sorted()
let report = String(format: "Warm-cache hover handler: 8000 transitions, mean %.4f ms, p95 %.4f ms, max %.4f ms. CPU handler cost, not end-to-end display latency.\n", samples.reduce(0,+)/Double(samples.count), sorted[Int(Double(sorted.count)*0.95)], sorted.last!)
print(report); try report.write(toFile: output + "/性能检查.txt", atomically: true, encoding: .utf8)
// Exercise real view state across a wide secondary fan without pumping delayed hover switches.
var navigationChecks = 0
for parent in 0..<8 {
    store.config.items[parent] = MenuItem(.submenu, name: "test", children: (0..<8).map { MenuItem.custom($0+1) })
    ring.loadConfiguration(); ring.prepare(); ring.openFolder(parent)
    let from = RingGeometry.point(parent)
    for child in 0..<8 {
        ring.openFolder(parent)
        let to = RingGeometry.childPoint(parent: parent, index: child, count: 8)
        for step in 0...20 {
            let t = CGFloat(step)/20
            ring.movePointer(to: NSPoint(x: from.x + (to.x-from.x)*t, y: from.y+(to.y-from.y)*t))
            if ring.openParent != parent { fatalError("submenu closed during travel") }; navigationChecks += 1
        }
        if ring.hoveredChild != child { fatalError("wrong submenu target") }; navigationChecks += 1
    }
    ring.movePointer(to: NSPoint(x: -1000, y: -1000))
    if ring.openParent != parent { fatalError("submenu lost after pointer exit") }; navigationChecks += 1
    ring.escape(); if ring.openParent != nil { fatalError("Esc did not return to root") }; navigationChecks += 1
}
store.config.items = (0..<8).map { MenuItem.custom($0+1) }
ring.loadConfiguration(); ring.prepare(armedAction: .brightness)
ring.movePointer(to: RingGeometry.center)
if ring.activeItem?.action != .brightness { fatalError("direct adjustment lost in a fully custom layout") }; navigationChecks += 1
ring.movePointer(to: RingGeometry.point(0))
if ring.activeItem?.action != .shortcut { fatalError("pointing did not override direct adjustment") }; navigationChecks += 1
print("PASS: \(navigationChecks) view navigation checks. Rendered root ring, submenu, editor and custom appearance using an in-memory store.")

// Window lifetime checks use a separate controller with no event tap and an in-memory store.
let lifecycle = AppController(store:SettingsStore(persistent:false))
lifecycle.showSettings()
if app.activationPolicy() != .regular || !app.windows.contains(where:{$0.title == appName+" 设置" && $0.isVisible}) { fatalError("settings did not open with Dock presence") }
lifecycle.closeToBackground()
if app.activationPolicy() != .accessory || app.windows.contains(where:{$0.title == appName+" 设置" && $0.isVisible}) { fatalError("background close left Dock/window visible") }
if lifecycle.applicationShouldTerminateAfterLastWindowClosed(app) { fatalError("closing final window terminated background service") }
if lifecycle.applicationShouldTerminate(app) != .terminateCancel { fatalError("ordinary application quit did not remain in background") }
_ = lifecycle.applicationShouldHandleReopen(app,hasVisibleWindows:false)
if app.activationPolicy() != .accessory || app.windows.contains(where:{$0.title == appName+" 设置" && $0.isVisible}) { fatalError("silent reopen unexpectedly opened settings") }
lifecycle.closeToBackground()
print("PASS: 5 settings/Dock/background/reopen lifetime checks; no event tap installed, no settings persisted.")

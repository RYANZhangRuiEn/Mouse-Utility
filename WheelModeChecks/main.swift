import AppKit
_ = NSApplication.shared
var checks = 0
func check(_ value:@autoclosure ()->Bool,_ message:String) { guard value() else { fatalError(message) }; checks += 1 }
for choice in WheelProfileSelection.allCases {
    for observed:MasterWheelMode? in [nil,.ratchet,.freeSpin] {
        let expected:MasterWheelMode = choice == .automatic ? (observed ?? .ratchet):choice == .ratchet ? .ratchet:.freeSpin
        check(choice.resolve(observed) == expected,"manual selection must override actual/unknown state")
        let input = MouseInputController(); input.config.wheelProfileSelection = choice; input.setWheelMode(observed)
        check(input.activeWheelMode == expected,"host applies the selected profile independently")
    }
    var config = Configuration(); config.wheelProfileSelection = choice
    let decoded = try JSONDecoder().decode(Configuration.self,from:JSONEncoder().encode(config))
    check(decoded.wheelProfileSelection == choice,"selection survives save and restart")
}
for kind in WheelStateReader.Kind.allCases {
    let reader = WheelStateReader(kind:kind,index:5)
    check(reader.decode([]) == nil && reader.decode([255]) == nil,"malformed state never masquerades as ratchet")
    check(reader.decode([kind == .hires ? 0:1]) == .freeSpin && reader.decode([kind == .hires ? 1:2]) == .ratchet,"each feature uses its own mode byte encoding")
}
check(WheelStateReader.Kind.enhanced.featureID == 0x2111 && WheelStateReader.Kind.enhanced.operation == 1,"enhanced SmartShift uses the status function, not capabilities")
check(WheelStateReader.Kind.legacy.featureID == 0x2110 && WheelStateReader.Kind.legacy.operation == 0,"legacy SmartShift uses function zero")
var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Configuration())) as! [String:Any]
object.removeValue(forKey:"wheelProfileSelection")
let migrated = try JSONDecoder().decode(Configuration.self,from:JSONSerialization.data(withJSONObject:object))
check(migrated.wheelProfileSelection == .automatic,"old settings retain automatic mode by default")
let store = SettingsStore(persistent:false), controller = AppController(store:SettingsStore(persistent:false))
#if PRIVATE_MOS
let settings:NSView = MosSettingsView(store:store,controller:controller)
#else
let settings:NSView = SmoothSettingsView(store:store,controller:controller)
#endif
func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
let picker = descendants(settings).compactMap{$0 as? NSPopUpButton}.first{$0.accessibilityLabel() == "实际使用的滚动参数"}!
picker.selectItem(at:2); _ = NSApp.sendAction(picker.action!,to:picker.target,from:picker)
check(store.config.wheelProfileSelection == .freeSpin,"runtime selector actually chooses free-spin settings")
picker.selectItem(at:1); _ = NSApp.sendAction(picker.action!,to:picker.target,from:picker)
check(store.config.wheelProfileSelection == .ratchet,"runtime selector can choose ratchet again")
picker.selectItem(at:0); _ = NSApp.sendAction(picker.action!,to:picker.target,from:picker)
check(store.config.wheelProfileSelection == .automatic,"runtime selector can restore automatic hardware switching")
print("PASS: \(checks) dual-profile persistence, manual/automatic selection, host routing, UI actions and SmartShift decoding checks; no HID I/O or global listeners.")

if let flag = CommandLine.arguments.firstIndex(of:"--render-mode-settings"),CommandLine.arguments.indices.contains(flag+1) {
    let root = SettingsView(store:store,controller:controller)
    let tabs = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
    tabs.selectedSegment = 2; _ = NSApp.sendAction(tabs.action!,to:tabs.target,from:tabs)
    let window = NSWindow(contentRect:root.bounds,styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = root
    root.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    let rep = root.bitmapImageRepForCachingDisplay(in:root.bounds)!; root.cacheDisplay(in:root.bounds,to:rep)
    try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[flag+1]))
}

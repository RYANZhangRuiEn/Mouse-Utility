import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let store = SettingsStore(persistent:false)
store.config.items = (0..<8).map { MenuItem(.shortcut,name:"测试 \($0+1)",shortcut:.command("C",code:8),symbol:"star") }
let controller = AppController(store:store)
controller.controls = AsyncControls(audio:controller.audio,brightness:controller.brightness,preview:true)
controller.panel = DialPanel(contentRect:NSRect(origin:.zero,size:RingGeometry.size),styleMask:.borderless,backing:.buffered,defer:false)
controller.panel.isOpaque = false; controller.panel.backgroundColor = NSColor.white.withAlphaComponent(0.001); controller.panel.isReleasedWhenClosed = false; controller.panel.hasShadow = false; controller.panel.level = .floating; controller.panel.title = "圆环命中验证"; controller.panel.acceptsMouseMovedEvents = true
controller.ring = RingView(frame:NSRect(origin:.zero,size:RingGeometry.size)); controller.ring.controller = controller; controller.ring.loadConfiguration(); controller.panel.contentView = controller.ring
final class Underlay:NSView {
    var count = 0
    let label = NSTextField(labelWithString:"底层点击：0")
    let open = NSButton(title:"显示圆环",target:nil,action:nil)
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true; layer?.backgroundColor = NSColor(calibratedWhite:0.9,alpha:1).cgColor
        label.frame = NSRect(x:20,y:frame.height-55,width:400,height:28); label.font = .systemFont(ofSize:20); addSubview(label)
        open.frame = NSRect(x:frame.midX-70,y:frame.midY-16,width:140,height:32); open.bezelStyle = .rounded; open.target = self; open.action = #selector(showRing); addSubview(open)
        let settings = NSButton(title:"查看新版设置",target:self,action:#selector(showSettings)); settings.frame = NSRect(x:20,y:20,width:180,height:32); addSubview(settings)
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func showRing() { controller.showRing() }
    @objc private func showSettings() { controller.showSettings() }
    override func mouseDown(with event:NSEvent) { count += 1; label.stringValue = "底层点击：\(count)" }
}
let window = NSWindow(contentRect:NSRect(x:200,y:130,width:1100,height:760),styleMask:[.titled,.closable],backing:.buffered,defer:false)
window.title = "鼠环交互验证（临时）"; window.isReleasedWhenClosed = false; window.contentView = Underlay(frame:NSRect(x:0,y:0,width:1100,height:760)); window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
app.run()

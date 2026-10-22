import AppKit

final class UpdatePromptView: NSView {
    var onDownload: (() -> Void)?
    var onLater: (() -> Void)?
    var onAutomatic: ((Bool) -> Void)?
    private var automaticButton: NSButton!
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    func setAutomatic(_ enabled:Bool) { automaticButton.state = enabled ? .on:.off }
    init(release: PublishedRelease, current: String, automatic: Bool, icon: NSImage? = nil) {
        super.init(frame:NSRect(x:0,y:0,width:440,height:220))
        let image = NSImageView(frame:NSRect(x:24,y:25,width:52,height:52))
        image.image = icon ?? Bundle.main.url(forResource:"Orbit",withExtension:"icns").flatMap { NSImage(contentsOf:$0) } ?? NSApp.applicationIconImage
        image.imageScaling = .scaleProportionallyUpOrDown; addSubview(image)
        func label(_ value:String, x:CGFloat = 94,y:CGFloat,width:CGFloat = 322,height:CGFloat = 22,size:CGFloat = 13,bold:Bool = false) {
            let text = NSTextField(wrappingLabelWithString:value)
            text.frame = NSRect(x:x,y:y,width:width,height:height)
            text.font = .systemFont(ofSize:size,weight:bold ? .semibold:.regular)
            text.textColor = bold ? .labelColor:.secondaryLabelColor; addSubview(text)
        }
        label("鼠环有新版本",y:25,size:17,bold:true)
        label(release.tag + "  ·  当前 " + current,y:54,size:12)
        label("前往 GitHub 下载新版本，解压后替换安装。",x:24,y:96,width:392,height:36)
        let checkbox = NSButton(checkboxWithTitle:"自动检查更新",target:self,action:#selector(toggleAutomatic(_:)))
        checkbox.frame = NSRect(x:24,y:142,width:190,height:22); checkbox.state = automatic ? .on:.off; addSubview(checkbox)
        automaticButton = checkbox
        for (title,x,width,selector) in [("稍后",CGFloat(180),CGFloat(76),#selector(later)),("前往 GitHub 下载",CGFloat(264),CGFloat(152),#selector(download))] {
            let button = NSButton(title:title,target:self,action:selector)
            button.bezelStyle = .rounded; button.frame = NSRect(x:x,y:180,width:width,height:28); addSubview(button)
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func toggleAutomatic(_ sender:NSButton) { onAutomatic?(sender.state == .on) }
    @objc private func later() { onLater?() }
    @objc private func download() { onDownload?() }
}

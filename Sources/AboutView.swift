import AppKit

struct AppRelease {
    var version: String
    var build: String
    var date: String?
    var copyright: String
    init(info:[String:Any] = Bundle.main.infoDictionary ?? [:]) {
        version = info["MouseRingReleaseLabel"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "开发版"
        build = info["CFBundleVersion"] as? String ?? "—"
        if let value = info["MouseRingReleaseDate"] as? String {
            let parser = DateFormatter(); parser.locale = Locale(identifier:"en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT:0); parser.dateFormat = "yyyy-MM-dd"
            if let parsed = parser.date(from:value) {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier:"zh_CN"); formatter.timeZone = parser.timeZone; formatter.dateFormat = "yyyy 年 M 月 d 日"
                date = formatter.string(from:parsed)
            }
        }
        copyright = info["NSHumanReadableCopyright"] as? String ?? "© 2026 MouseRing contributors"
    }
    var display: String { "版本 \(version)（构建 \(build)）" }
}

final class AboutView: NSView {
    override var isFlipped:Bool { true }
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    init(release:AppRelease = AppRelease(),icon:NSImage? = nil) {
        super.init(frame:NSRect(x:0,y:0,width:380,height:286))
        let image = NSImageView(frame:NSRect(x:158,y:38,width:64,height:64))
        image.image = icon ?? Bundle.main.url(forResource:"Orbit",withExtension:"icns").flatMap { NSImage(contentsOf:$0) } ?? NSApp.applicationIconImage
        image.imageScaling = .scaleProportionallyUpOrDown; addSubview(image)
        func label(_ title:String,y:CGFloat,height:CGFloat,size:CGFloat,weight:NSFont.Weight = .regular,secondary:Bool = false) {
            let field = NSTextField(wrappingLabelWithString:title)
            field.frame = NSRect(x:24,y:y,width:332,height:height)
            field.alignment = .center; field.font = .systemFont(ofSize:size,weight:weight)
            field.textColor = secondary ? .secondaryLabelColor:.labelColor; addSubview(field)
        }
        label(appName,y:123,height:28,size:18,weight:.semibold)
        label("MouseRing for Mac",y:164,height:20,size:13,secondary:true)
        label(release.display,y:183,height:20,size:12,secondary:true)
        if let date = release.date { label("发布于 " + date,y:216,height:20,size:12,secondary:true) }
        label(release.copyright,y:249,height:20,size:12,secondary:true)
    }
    required init?(coder:NSCoder) { fatalError() }
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:380,height:286),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "关于 " + appName; window.isReleasedWhenClosed = false
        window.contentView = AboutView(); window.center()
        return window
    }
}

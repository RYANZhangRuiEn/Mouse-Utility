import AppKit

let app = NSApplication.shared
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ message: String) { guard try! value() else { fatalError(message) }; checks += 1 }
func pump() { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.025)) }
func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func records(_ tags:[String], draft:Bool = false) -> Data {
    try! JSONSerialization.data(withJSONObject:tags.map { ["tag_name":$0,"html_url":"https://github.com/RYANZhangRuiEn/Mouse-Utility/releases/tag/"+$0,"draft":draft] as [String:Any] })
}
let versions = ["1.0.0-alpha","1.0.0-alpha.1","1.0.0-alpha.beta","1.0.0-beta","1.0.0-beta.2","1.0.0-beta.11","1.0.0-rc.1","1.0.0","1.0.1","2.0.0"]
for a in versions.indices { for b in versions.indices {
    check((ReleaseVersion(versions[a])! < ReleaseVersion(versions[b])!) == (a < b),"SemVer precedence \(a)/\(b)")
} }
check(ReleaseVersion("v1.0.0-preview.9")! < ReleaseVersion("v1.0.0-preview.10")!,"numeric preview ordering")
check(ReleaseVersion("1.0.0+x") == ReleaseVersion("v1.0.0+y"),"build metadata does not change precedence")
for bad in ["", "latest", "1.0", "v01.0.0", "1.0.0-preview.01", "-1.0.0", "1.0.0/evil", "1.0.0-", "9999999999999999999999.0.0"] {
    check(ReleaseVersion(bad) == nil,"invalid tag rejected")
}
let current = "v1.0.0-preview.4"
check(try ReleaseCatalog.newest(in:records(["v1.0.0-preview.1",current]),after:current) == nil,"old public release cannot alert")
check(try ReleaseCatalog.newest(in:records(["v1.0.0-preview.10","v1.0.0-preview.5"]),after:current)?.tag == "v1.0.0-preview.10","select by version, not response order")
check(try ReleaseCatalog.newest(in:records(["v1.0.0"]),after:current)?.tag == "v1.0.0","stable replaces preview")
check(try ReleaseCatalog.newest(in:records(["v2.0.0"],draft:true),after:current) == nil,"draft never alerts")
for url in ["http://github.com/RYANZhangRuiEn/Mouse-Utility/releases/tag/v2.0.0", "https://github.com.evil.test/RYANZhangRuiEn/Mouse-Utility/releases/tag/v2.0.0", "https://github.com/other/repo/releases/tag/v2.0.0", "https://user@github.com/RYANZhangRuiEn/Mouse-Utility/releases/tag/v2.0.0", "https://github.com:443/RYANZhangRuiEn/Mouse-Utility/releases/tag/v2.0.0", "https://github.com/RYANZhangRuiEn/Mouse-Utility/releases/tag/v2.0.0?next=evil", "https://github.com/RYANZhangRuiEn/Mouse-Utility/releases/tag/v3.0.0"] {
    let body = try JSONSerialization.data(withJSONObject:[["tag_name":"v2.0.0","html_url":url,"draft":false]])
    check(try ReleaseCatalog.newest(in:body,after:current) == nil,"download page restricted to this release")
}
do { _ = try ReleaseCatalog.newest(in:Data(repeating:32,count:ReleaseCatalog.maximumBytes+1),after:current); fatalError("oversize accepted") } catch { checks += 1 }
do { _ = try ReleaseCatalog.newest(in:Data("not JSON".utf8),after:current); fatalError("malformed accepted") } catch { checks += 1 }
let request = GitHubReleaseRequest.request(tag:current)
check(request.url == ReleaseCatalog.api && request.httpMethod == "GET" && request.httpBody == nil,"only release metadata request")
check(request.value(forHTTPHeaderField:"Authorization") == nil && request.value(forHTTPHeaderField:"Cookie") == nil,"no login or cookies")
check(request.timeoutInterval == 15 && request.value(forHTTPHeaderField:"X-GitHub-Api-Version") == "2026-03-10","bounded versioned request")

final class Pending: ReleaseRequest {
    var cancelled = false
    let completion:(Result<Data,Error>) -> Void
    init(_ completion:@escaping (Result<Data,Error>) -> Void) { self.completion = completion }
    func cancel() { cancelled = true }
}
let preferences = UpdatePreferences(defaults:nil); preferences.automatic = false
let suiteName = "local.mousering.update-checks." + UUID().uuidString
let isolatedDefaults = UserDefaults(suiteName:suiteName)!
let saved = UpdatePreferences(defaults:isolatedDefaults)
saved.automatic = false; saved.lastNotifiedTag = "v1.0.0-preview.5"; saved.lastAttempt = Date(timeIntervalSince1970:12345)
let restored = UpdatePreferences(defaults:isolatedDefaults)
check(!restored.automatic && restored.lastNotifiedTag == saved.lastNotifiedTag && restored.lastAttempt == saved.lastAttempt,"opt-out and reminder history survive preference reload")
isolatedDefaults.removePersistentDomain(forName:suiteName)
var requests:[Pending] = [], outcomes:[(String,Bool)] = []
var now = Date(timeIntervalSince1970:1_000_000)
let checker = ReleaseUpdateChecker(current:current,preferences:preferences,now:{now},fetch:{ let request = Pending($0); requests.append(request); return request })
checker.onResult = { outcome,manual in
    switch outcome { case .available(let release): outcomes.append((release.tag,manual)); case .current: outcomes.append(("current",manual)); case .failed: outcomes.append(("error",manual)) }
}
checker.start(); checker.checkIfDue(); pump()
check(requests.isEmpty,"disabled startup and timer do not access network")
checker.check(manual:true); checker.check(manual:true)
check(requests.count == 1 && checker.checking,"manual while disabled works and coalesces")
requests[0].completion(.success(records(["v1.0.0-preview.5"]))); pump()
check(outcomes.last?.0 == "v1.0.0-preview.5" && outcomes.last?.1 == true && !checker.checking,"manual newer release prompts")
checker.setAutomatic(true); checker.checkIfDue()
check(requests.count == 1,"restart and enable respect daily interval")
now.addTimeInterval(ReleaseUpdateChecker.interval); checker.checkIfDue(); checker.checkIfDue()
check(requests.count == 2,"one daily automatic request")
requests[1].completion(.success(records(["v1.0.0-preview.5"]))); pump()
check(outcomes.count == 1,"automatic reminder deduplicates already shown tag")
now.addTimeInterval(ReleaseUpdateChecker.interval); checker.checkIfDue()
requests[2].completion(.success(records(["v1.0.0-preview.6"]))); pump()
check(outcomes.last?.0 == "v1.0.0-preview.6" && outcomes.last?.1 == false,"newer tag prompts automatically")
now.addTimeInterval(ReleaseUpdateChecker.interval); checker.checkIfDue()
checker.setAutomatic(false)
check(requests[3].cancelled && !checker.checking,"disabling cancels automatic request")
requests[3].completion(.success(records(["v2.0.0"]))); pump()
check(outcomes.count == 2,"late cancellation completion cannot prompt")
checker.check(manual:true); checker.setAutomatic(false)
check(!requests[4].cancelled,"turning auto off preserves explicit manual check")
requests[4].completion(.success(records([current]))); pump()
check(outcomes.last?.0 == "current","manual no-update result")
checker.check(manual:true); requests[5].completion(.failure(ReleaseCheckError.rateLimited)); pump()
check(outcomes.last?.0 == "error","manual network failure is visible")
now.addTimeInterval(ReleaseUpdateChecker.interval); checker.setAutomatic(true)
requests[6].completion(.failure(ReleaseCheckError.serviceUnavailable)); pump()
check(outcomes.count == 4 && !checker.checking,"automatic network failure stays quiet")
now.addTimeInterval(ReleaseUpdateChecker.interval); checker.checkIfDue(); checker.check(manual:true)
requests[7].completion(.success(records([current]))); pump()
check(outcomes.last?.0 == "current" && outcomes.last?.1 == true,"manual intent joins existing automatic check")
now.addTimeInterval(ReleaseUpdateChecker.interval); checker.checkIfDue(); checker.stop()
requests[8].completion(.success(records(["v3.0.0"]))); pump()
check(requests[8].cancelled && outcomes.count == 5,"quit stops network and ignores late result")

let controllerPrefs = UpdatePreferences(defaults:nil)
let controller = AppController(store:SettingsStore(persistent:false),updatePreferences:controllerPrefs)
for _ in 0..<2 {
    let menu = NSMenu(); controller.appendUpdateMenuItems(to:menu)
    check(menu.items.map(\.title) == ["检查更新…","自动检查更新"],"both menus expose update controls")
    _ = controller.validateMenuItem(menu.items[1]); check(menu.items[1].state == (controllerPrefs.automatic ? .on:.off),"menu checkmark tracks preference")
    _ = app.sendAction(menu.items[1].action!,to:menu.items[1].target,from:menu.items[1])
    _ = controller.validateMenuItem(menu.items[1]); check(menu.items[1].state == (controllerPrefs.automatic ? .on:.off),"menu switch is connected")
}
let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
let icon = NSImage(contentsOf:root.appendingPathComponent("Orbit.icns"))
let info = NSDictionary(contentsOf:root.appendingPathComponent("Info.plist")) as! [String:Any]
let release = AppRelease(info:info)
check(release.display == "版本 1.0 Preview 4（构建 19）" && release.date == "2026 年 10 月 22 日","shipping about metadata")
let about = AboutView(release:release,icon:icon)
let prompt = UpdatePromptView(release:PublishedRelease(tag:"v1.0.0-preview.5",page:URL(string:"https://github.com/RYANZhangRuiEn/Mouse-Utility/releases/tag/v1.0.0-preview.5")!),current:current,automatic:true,icon:icon)
var opened = 0, dismissed = 0, auto = true
prompt.onDownload = {opened += 1}; prompt.onLater = {dismissed += 1}; prompt.onAutomatic = {auto = $0}
for button in descendants(prompt).compactMap({$0 as? NSButton}) {
    if button.title == "自动检查更新" { button.state = .off }
    _ = app.sendAction(button.action!,to:button.target,from:button)
}
check(opened == 1 && dismissed == 1 && !auto,"reminder download, later and disable controls")
prompt.setAutomatic(true)
for button in descendants(prompt).compactMap({$0 as? NSButton}) {
    check(button.cell!.cellSize.width <= button.frame.width,"button title fits: \(button.title)")
}
for view in [about as NSView,prompt as NSView] {
    check(view.subviews.allSatisfy { view.bounds.contains($0.frame) },"all visible content fits")
    for field in view.subviews.compactMap({$0 as? NSTextField}) {
        check(field.cell!.cellSize(forBounds:field.bounds).height <= field.frame.height+1,"text does not clip: \(field.stringValue)")
    }
}
if let output = CommandLine.arguments.dropFirst().first(where:{!$0.hasPrefix("--")}) {
    for (view,name) in [(about as NSView,"关于-Preview4.png"),(prompt as NSView,"更新提醒-Preview4.png")] {
        let host = NSWindow(contentRect:view.bounds,styleMask:.borderless,backing:.buffered,defer:false); host.isReleasedWhenClosed = false; host.contentView = view
        view.layoutSubtreeIfNeeded(); pump()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!; view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output+"/"+name))
    }
}
if CommandLine.arguments.contains("--live") {
    var result:Result<Data,Error>?
    let live = GitHubReleaseRequest(tag:current) { result = $0 }
    let deadline = Date(timeIntervalSinceNow:25)
    while result == nil && Date() < deadline { pump() }
    live.cancel()
    let data = try result!.get()
    let found = try ReleaseCatalog.newest(in:data,after:current)
    check(found == nil,"live public release older than current development build")
    print("PASS: anonymous GitHub API request and parsing using production transport")
}
print("PASS: \(checks) release, cancellation, opt-out persistence, menu, reminder, About layout checks; isolated preferences, no global input listeners.")

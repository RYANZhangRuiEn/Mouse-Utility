import AppKit
import Darwin

/// Dock's Show Desktop command, independent of symbolic hotkeys and keyboard events.
/// CoreDockSendNotification ABI verified against HIServices and yabai's Dock bridge.
final class DesktopController {
    typealias Notify = @convention(c) (CFString, UnsafeRawPointer?) -> Void
    static let notification = "com.apple.showdesktop.awake"
    private var framework: UnsafeMutableRawPointer?
    private var notify: Notify?
    private let send: ((String) throws -> Void)?
    init(send: ((String) throws -> Void)? = nil) {
        self.send = send
        guard send == nil else { return }
        framework = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",RTLD_LAZY | RTLD_LOCAL)
        if let framework, let symbol = dlsym(framework,"CoreDockSendNotification") {
            notify = unsafeBitCast(symbol,to:Notify.self)
        }
    }
    var available: Bool { send != nil || notify != nil }
    func toggle() throws {
        if let send { try send(Self.notification); return }
        guard let notify else { throw ControlFailure(message:"当前系统无法调用显示桌面功能") }
        notify(Self.notification as CFString,nil)
    }
    deinit { if let framework { dlclose(framework) } }
}

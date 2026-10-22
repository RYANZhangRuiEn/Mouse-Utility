import Foundation

/// Editing a profile and choosing the active profile are separate, explicit decisions.
enum WheelProfileSelection:String,Codable,CaseIterable {
    case automatic, ratchet, freeSpin
    var title:String {
        switch self { case .automatic:return "使用：自动随鼠标切挡"; case .ratchet:return "使用：固定棘齿挡参数"; case .freeSpin:return "使用：固定无极挡参数" }
    }
    func resolve(_ observed:MasterWheelMode?) -> MasterWheelMode {
        switch self { case .automatic:return observed ?? .ratchet; case .ratchet:return .ratchet; case .freeSpin:return .freeSpin }
    }
    func status(observed:MasterWheelMode?) -> String {
        if self != .automatic { return "当前使用："+resolve(observed).title+" · 手动固定" }
        return observed.map { "当前使用："+$0.title+" · 自动切换" } ?? "未读取到挡位 · 暂用棘齿；可手动选择"
    }
}

/// Protocol facts only: Enhanced 0x2111 fn1, HiRes 0x2121 fn3, legacy 0x2110 fn0.
/// Queries never write wheel mode or use scrolling speed as a substitute for hardware state.
struct WheelStateReader:Equatable {
    enum Kind:CaseIterable { case enhanced, hires, legacy
        var featureID:UInt16 { switch self { case .enhanced:return 0x2111;case .hires:return 0x2121;case .legacy:return 0x2110 } }
        var operation:UInt8 { switch self { case .enhanced:return 1;case .hires:return 3;case .legacy:return 0 } }
    }
    var kind:Kind
    var index:UInt8
    func decode(_ payload:[UInt8]) -> MasterWheelMode? {
        guard let value = payload.first else { return nil }
        if kind == .hires { return value == 0 ? .freeSpin:value == 1 ? .ratchet:nil }
        return value == 1 ? .freeSpin:value == 2 ? .ratchet:nil
    }
}

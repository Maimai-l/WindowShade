// App 窗口（App Exposé）的入口：程序坞的私有通知。
//
// 在 Dock 图标上往上滑（App/DockSwipe.swift）铺开那个 App 的所有窗口。
// 优先用程序坞自己的通知（CoreDockSendNotification，和触控板手势走的是同一个入口，不依赖用户改没改快捷键）；
// 符号拿不到时退回公开的办法：按系统设置里它的快捷键（默认 ⌃↓）。
//
// 编译单元：prototype/Private/DockBridge.swift

import Cocoa
import Darwin

enum DockOverview {
    private typealias SendNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let send: SendNotification? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: SendNotification.self)
    }()

    /// App 窗口：最前面那个 App 的所有窗口铺开（含最小化的）。
    static func applicationWindows() {
        if let send {
            send("com.apple.expose.front.awake" as CFString, nil)
            wlog("dock: application windows")
            return
        }
        // 系统快捷键 33（“应用程序窗口”），默认 ⌃↓；被关掉就算了。
        var keyCode: CGKeyCode = 125
        var flags = CGEventFlags(rawValue: 8_650_752)
        if let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
           let entry = hotkeys["33"] as? [String: Any] {
            if let enabled = entry["enabled"] as? NSNumber, !enabled.boolValue {
                wlog("dock: application windows shortcut is off")
                return
            }
            if let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber],
               parameters.count == 3 {
                keyCode = CGKeyCode(parameters[1].intValue)
                flags = CGEventFlags(rawValue: parameters[2].uint64Value)
            }
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        wlog("dock: application windows via shortcut keyCode=\(keyCode)")
    }
}

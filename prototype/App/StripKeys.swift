// 卷帘条上的 ⌘N / ⌘H / ⌘M / ⌘Q / ⌘W 转给它背后的 App（见 StripKeyForwarding）。
// WindowMizer 在占位条上也这样做；我们原来不转，⌘Q 会退出 WindowShade 自己。

import Cocoa
import Carbon.HIToolbox

extension AppDelegate {
    @MainActor func installStripKeyForwarding() {
        StripKeyForwarding.handler = { [weak self] window, key in
            guard let self,
                  let entry = self.shaded.first(where: { $0.value.overlay === window }) else { return false }
            return self.forwardStripKey(key, id: entry.key, pid: entry.value.pid)
        }
    }

    /// - ⌘N：交给原 App，新建窗口。
    /// - ⌘H：隐藏原 App。
    /// - ⌘W / ⌘M：关掉或最小化这扇窗，和卷帘条上的红灯、黄灯一样。
    /// - ⌘Q：先把窗口放下来再退出原 App——退出时要问“是否保存”，对话框得出现在看得见的窗口上。
    func forwardStripKey(_ key: String, id: CGWindowID, pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        wlog("strip-key: ⌘\(key) id=\(id) → \(app.localizedName ?? "?")")
        switch key {
        case "n":
            app.activate()
            let pressed = pressCommandMenuItem("N", pid: pid)
            wlog("strip-key: new window via menu pressed=\(pressed) id=\(id)")
        case "h":
            app.hide()
        case "w":
            handleTrafficLight(.close, id)
        case "m":
            handleTrafficLight(.minimize, id)
        case "q":
            unshade(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { _ = app.terminate() }
        default:
            return false
        }
        return true
    }
}

/// 按下某个 App 菜单栏里快捷键是 Command 加这个字母的那一项（辅助功能的“按下”，不合成按键）。
/// 只看菜单栏下的第一层菜单，“新建”这类命令都在那里。
func pressCommandMenuItem(_ character: String, pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var barRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
          let barValue = barRef, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return false }
    let bar = unsafeDowncast(barValue, to: AXUIElement.self)
    for barItem in axChildren(bar) {
        for menu in axChildren(barItem) {
            for item in axChildren(menu) {
                var charRef: CFTypeRef?
                var modifiersRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &charRef) == .success,
                      (charRef as? String)?.uppercased() == character.uppercased(),
                      AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiersRef) == .success,
                      (modifiersRef as? NSNumber)?.intValue == 0,   // 0：只有 Command
                      axBoolAttribute(item, kAXEnabledAttribute as String) else { continue }
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
    }
    return false
}

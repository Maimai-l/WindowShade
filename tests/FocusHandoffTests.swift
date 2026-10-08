// 需求：F4（docs/testing.md 第 3.1 节）。
// 第 2 层组件测试：收起时把焦点交给当前桌面上的哪个窗口（Platform/FocusHandoff.swift）。

import CoreGraphics
import Foundation

@main
struct FocusHandoffTests {
    static let selfPID: pid_t = 1
    static let appPID: pid_t = 10
    static let otherPID: pid_t = 20
    static let frame = CGRect(x: 100, y: 100, width: 600, height: 400)

    static func onScreen(_ id: CGWindowID, _ pid: pid_t, layer: Int = 0, alpha: Double = 1,
                         bounds: CGRect = frame) -> OnScreenWindow {
        OnScreenWindow(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
    }

    static func main() {
        var t = TestSuite("focus-handoff")
        let original = FakeWindow(id: 1, pid: appPID, frame: frame)
        func request(frontmost: pid_t?, overlays: Set<CGWindowID> = []) -> FocusHandoffRequest {
            FocusHandoffRequest(window: WindowHandle(element: original), id: 1, pid: appPID,
                                frontmostPID: frontmost, selfPID: selfPID, overlayIDs: overlays)
        }

        t.section("F4", "原窗口所属的应用程序不在前台：不交接")
        do {
            let control = FakeFocusControl()
            let result = FocusHandoff(control: control).handOff(request(frontmost: otherPID))
            t.expect(result == .notFrontmost && result.appHideSafe, "结果为 notFrontmost，隐藏应用程序安全")
            t.expect(control.focused.isEmpty && control.activated.isEmpty, "没有转移焦点")
        }

        t.section("F4", "同一应用程序在当前桌面上还有窗口：交给它")
        do {
            let control = FakeFocusControl()
            let sibling = FakeWindow(id: 2, pid: appPID, frame: frame)
            let minimized = FakeWindow(id: 3, pid: appPID, frame: frame)
            minimized.minimized = true
            let otherSpace = FakeWindow(id: 4, pid: appPID, frame: frame)
            control.appWindows[appPID] = [original, minimized, otherSpace, sibling]
            control.onScreen = [onScreen(1, appPID), onScreen(3, appPID), onScreen(2, appPID)]
            let result = FocusHandoff(control: control).handOff(request(frontmost: appPID))
            t.expect(result == .sameApp(heir: 2), "交给窗口 2（跳过原窗口、已最小化的窗口和不在当前桌面的窗口）")
            t.expect(control.focused == [2] && control.activated.isEmpty, "只设置焦点窗口，不切换应用程序")
        }

        t.section("F4", "同一应用程序没有其他窗口：交给当前桌面最上层的普通应用程序窗口")
        do {
            let control = FakeFocusControl()
            control.appWindows[appPID] = [original]
            let heir = FakeWindow(id: 30, pid: otherPID, frame: frame.offsetBy(dx: 10, dy: 10))
            let far = FakeWindow(id: 31, pid: otherPID, frame: CGRect(x: 800, y: 600, width: 200, height: 200))
            control.appWindows[otherPID] = [far, heir]
            control.regularApps = [otherPID, 40]
            control.onScreen = [
                onScreen(99, selfPID),                     // WindowShade 自己的窗口
                onScreen(50, 40, layer: 25),               // 菜单栏层级
                onScreen(51, 40, alpha: 0),                // 全透明
                onScreen(52, 40, bounds: CGRect(x: 0, y: 0, width: 1, height: 1)),
                onScreen(77, 40),                          // 卷帘条
                onScreen(1, appPID),
                onScreen(30, otherPID, bounds: frame.offsetBy(dx: 10, dy: 10)),
            ]
            let result = FocusHandoff(control: control).handOff(request(frontmost: selfPID, overlays: [77]))
            t.expect(result == .otherApp(pid: otherPID), "交给应用程序 \(otherPID)")
            t.expect(control.activated == [otherPID], "激活该应用程序")
            t.expect(control.focused == [30], "焦点给位置与屏幕上那扇窗一致的窗口 30")
        }

        t.section("F4", "当前桌面没有可以接收焦点的窗口：不交接，隐藏应用程序不安全")
        do {
            let control = FakeFocusControl()
            control.appWindows[appPID] = [original]
            control.onScreen = [onScreen(1, appPID), onScreen(99, selfPID)]
            let result = FocusHandoff(control: control).handOff(request(frontmost: appPID))
            t.expect(result == .nowhere && !result.appHideSafe, "结果为 nowhere")
            t.expect(control.focused.isEmpty && control.activated.isEmpty, "没有转移焦点，也没有激活访达")
        }

        t.finish()
    }
}

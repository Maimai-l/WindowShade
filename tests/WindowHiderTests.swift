// 需求：F1、F3、R2（docs/testing.md 第 3.1 节）。
// 第 2 层组件测试：WindowHider 在模拟窗口上按隐藏策略依次尝试各种方式（Platform/WindowHider.swift）。

import CoreGraphics
import Foundation

@main
struct WindowHiderTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let layout = ScreenLayout(screens: [screen])
    static let start = CGPoint(x: 200, y: 150)
    static let size = CGSize(width: 700, height: 460)

    /// 系统允许窗口停到的范围：左上角不能离开屏幕，但可以停到右下角只剩 1 像素（与 macOS 实测一致）。
    static let cornerOnly = CGRect(x: 0, y: 0, width: screen.width - 1, height: screen.height - 1)
    /// 完全不限制（窗口可以移到屏幕外很远的地方）。
    static let anywhere = CGRect(x: -40000, y: -40000, width: 80000, height: 80000)

    static func request(_ policy: ShadePolicy, appHideSafe: Bool = true, otherFolded: Int = 0,
                        noFocusHeir: Bool = false) -> HideRequest {
        HideRequest(window: WindowHandle(element: NSObject()), id: 42, pid: 7, position: start, size: size,
                    policy: policy, appHideSafe: appHideSafe, layout: layout, otherFoldedWindows: otherFolded,
                    noFocusHeir: noFocusHeir)
    }

    static func main() {
        var t = TestSuite("window-hider")

        t.section("F1", "唯一窗口、允许隐藏整个应用程序时，隐藏应用程序")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            let hider = WindowHider(control: control)
            t.expect(hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true))) == .hidden, "结果为 hidden")
            t.expect(control.calls == ["hideApp"], "只调用了隐藏应用程序")
        }

        t.section("F3", "不能隐藏应用程序时停到屏幕角落，不最小化")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            control.visibleWindows = 2
            let remembered = Remembered()
            let hider = WindowHider(control: control, rememberIneffective: { remembered.add($0) })
            let hide = hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true)))
            t.expect(hide == .offscreen, "结果为 offscreen（屏幕角落）")
            t.expect(control.callsMatching("hideApp") == 0, "应用程序还有其他可见窗口：不隐藏整个应用程序")
            t.expect(!control.minimized, "没有最小化")
            t.expect(!layout.isVisible(pos: control.windowPosition, size: size), "窗口不再算可见")
            t.expect(control.windowPosition == CGPoint(x: screen.maxX - 1, y: screen.maxY - 1), "停在右下角，只留 1 像素")
            t.expect(hider.knownSkyLightMoveIneffective && hider.knownSkyLightAlphaIneffective,
                     "SkyLight 调用返回成功但窗口不变：记为无效")
            t.expect(remembered.kinds == ["offscreen", "alpha"], "两项无效记录各写一次")

            control.windowPosition = start
            let skyLightCallsBefore = control.callsMatching("skyLight")
            _ = hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true)))
            t.expect(control.callsMatching("skyLight") == skyLightCallsBefore, "已知无效后不再调用 SkyLight")
        }

        t.section("F3", "同一应用程序还有被收起的窗口：不隐藏整个应用程序（场景 A37、Q01）")
        do {
            // 隐藏了整个应用程序，之后展开它的另一扇窗口时应用程序重新显示，这一扇被当成用户唤回，跟着展开
            // （Q01 种子 1771577254 第 28 步：展开一扇，三扇都展开了）。
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            let hider = WindowHider(control: control, skyLightMoveIneffective: true, skyLightAlphaIneffective: true)
            let hide = hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true), otherFolded: 2))
            t.expect(hide == .offscreen, "结果为 offscreen（屏幕角落），不是 \(hide)")
            t.expect(control.callsMatching("hideApp") == 0, "没有隐藏应用程序")

            let safari = FakeWindowControl(position: start, size: size, allowedOrigins: anywhere)
            let hider2 = WindowHider(control: safari)
            t.expect(hider2.hide(request(.offscreenThenFallback(allowAppHide: true), otherFolded: 1)) == .offscreen,
                     "先移屏幕外的策略：唯一可见窗口也不隐藏应用程序，移到屏幕外")
            t.expect(safari.callsMatching("hideApp") == 0, "没有隐藏应用程序")
        }

        t.section("F3", "转移焦点不安全时不隐藏应用程序")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            let hider = WindowHider(control: control, skyLightMoveIneffective: true, skyLightAlphaIneffective: true)
            t.expect(hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true), appHideSafe: false)) == .offscreen,
                     "结果为 offscreen（屏幕角落）")
            t.expect(control.callsMatching("hideApp") == 0, "没有隐藏应用程序")
        }

        t.section("F3", "访达（不允许隐藏应用程序）的唯一窗口也停到屏幕角落")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            let hider = WindowHider(control: control, skyLightMoveIneffective: true, skyLightAlphaIneffective: true)
            t.expect(hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: false))) == .offscreen, "结果为 offscreen")
            t.expect(control.callsMatching("hideApp") == 0, "没有隐藏应用程序")
        }

        t.section("F3", "SkyLight 生效时用它移到屏幕外")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            control.visibleWindows = 2
            control.skyLightTakesEffect = true
            let hider = WindowHider(control: control)
            t.expect(hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true))) == .privateOffscreen,
                     "结果为 privateOffscreen")
            t.expect(!hider.knownSkyLightMoveIneffective, "生效时不记为无效")
        }

        t.section("F3", "所有方式都不生效时最后才最小化")
        do {
            let pinned = CGRect(origin: start, size: .zero)
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: pinned)
            control.visibleWindows = 2
            let hider = WindowHider(control: control, skyLightMoveIneffective: true, skyLightAlphaIneffective: true)
            t.expect(hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true))) == .minimized, "结果为 minimized")
            t.expect(control.calls.last == "minimize", "最小化是最后一步")
            t.expect(control.windowPosition == start, "停放失败后窗口回到原位置再最小化")
        }

        t.section("F3", "先移到屏幕外的策略（Safari）")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: anywhere)
            control.visibleWindows = 2
            let hider = WindowHider(control: control)
            t.expect(hider.hide(request(.offscreenThenFallback(allowAppHide: true))) == .offscreen, "能移到屏幕外：offscreen")
            t.expect(control.windowPosition == offscreenParkingPoint, "停在主停放点")

            let single = FakeWindowControl(position: start, size: size, allowedOrigins: anywhere)
            let hider2 = WindowHider(control: single)
            t.expect(hider2.hide(request(.offscreenThenFallback(allowAppHide: true))) == .hidden,
                     "唯一窗口时优先隐藏应用程序")
        }

        t.section("F3", "快速查看窗口：关闭")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            let hider = WindowHider(control: control)
            t.expect(hider.hide(request(.closeQuickLookPreview)) == .quickLookClosed, "按关闭按钮")
            control.closeButtonWorks = false
            let hider2 = WindowHider(control: control, skyLightMoveIneffective: true, skyLightAlphaIneffective: true)
            t.expect(hider2.hide(request(.closeQuickLookPreview)) == .offscreen, "关不掉时停到屏幕角落，不隐藏应用程序")
            t.expect(control.callsMatching("hideApp") == 0, "没有隐藏应用程序")
        }

        t.section("F3", "SkyLight 透明生效时记下原透明度，展开时取回")
        do {
            let pinned = CGRect(origin: start, size: .zero)
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: pinned)
            control.visibleWindows = 2
            control.skyLightTakesEffect = true
            let hider = WindowHider(control: control, skyLightMoveIneffective: true)
            t.expect(hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true))) == .privateAlpha, "结果为 privateAlpha")
            t.expect(hider.originalAlpha(id: 42) == 1, "记下原透明度 1")
            t.expect(hider.takeOriginalAlpha(id: 42) == 1 && hider.originalAlpha(id: 42) == nil, "取回后删除")
        }

        t.section("R2", "当前桌面上没有窗口能接手焦点：应用程序只有这一扇窗口时最小化，还有别的窗口时不最小化（场景 B06-alone）")
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: anywhere)
            let hider = WindowHider(control: control)
            let hide = hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true), appHideSafe: false,
                                          noFocusHeir: true))
            t.expect(hide == .minimized, "结果为 minimized，不移到屏幕外、不停到角落（实际 \(hide)）")
            t.expect(control.calls == ["minimize"], "只调用了最小化（实际 \(control.calls)）")
        }
        do {
            let control = FakeWindowControl(position: start, size: size, allowedOrigins: cornerOnly)
            control.totalWindows = 2
            let hider = WindowHider(control: control)
            let hide = hider.hide(request(.hiddenIfSingleWindowElseMinimized(allowAppHide: true), appHideSafe: false,
                                          noFocusHeir: true))
            t.expect(hide != .minimized, "应用程序在别处还有窗口：不最小化，免得系统让那扇窗口接手、切换桌面（实际 \(hide)）")
        }

        t.finish()
    }
}

/// rememberIneffective 收到的种类。
final class Remembered: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ kind: String) { lock.withLock { storage.append(kind) } }
    var kinds: [String] { lock.withLock { storage } }
}

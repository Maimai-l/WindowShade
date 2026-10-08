// FocusControl 的模拟实现：按配置给出各应用程序的窗口和屏幕上的窗口顺序，记下焦点交给了谁。
// 只编进测试二进制。

import CoreGraphics
import Foundation

final class FakeWindow: NSObject {
    let id: CGWindowID?
    let pid: pid_t
    var minimized = false
    var frame: CGRect
    init(id: CGWindowID?, pid: pid_t, frame: CGRect) { self.id = id; self.pid = pid; self.frame = frame }
}

final class FakeFocusControl: FocusControl, @unchecked Sendable {
    var appWindows: [pid_t: [FakeWindow]] = [:]
    var onScreen: [OnScreenWindow] = []
    var regularApps: Set<pid_t> = []
    private(set) var activated: [pid_t] = []
    private(set) var focused: [CGWindowID?] = []

    private func fake(_ window: WindowHandle) -> FakeWindow { window.element as! FakeWindow }

    func windows(pid: pid_t) -> [WindowHandle] { (appWindows[pid] ?? []).map { WindowHandle(element: $0) } }
    func isSameWindow(_ a: WindowHandle, _ b: WindowHandle) -> Bool { fake(a) === fake(b) }
    func isMinimized(_ window: WindowHandle) -> Bool { fake(window).minimized }
    func windowNumber(_ window: WindowHandle) -> CGWindowID? { fake(window).id }
    func frame(_ window: WindowHandle) -> CGRect? { fake(window).frame }
    func onScreenWindows() -> [OnScreenWindow] { onScreen }
    func isRegularApp(pid: pid_t) -> Bool { regularApps.contains(pid) }
    func appName(pid: pid_t) -> String { "app\(pid)" }
    func activate(pid: pid_t) { activated.append(pid) }
    func focus(_ window: WindowHandle, pid: pid_t) { focused.append(fake(window).id) }
    func log(_ message: String) {}
}

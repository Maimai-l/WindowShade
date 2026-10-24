// FocusControl 的模拟实现：按配置给出各应用程序的窗口和屏幕上的窗口顺序，记下焦点交给了谁，并模拟前台应用程序的切换。
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
    /// 按调用顺序记下的每次 activate 和 focus，用来核对两者的先后。
    private(set) var events: [String] = []
    /// 前台应用程序的进程号。
    var frontmost: pid_t?
    /// activate 之后再调用几次 pause() 才换到前台，模拟系统过一会儿才切换前台应用程序；0 表示立即换，nil 表示一直不换。
    var activationDelay: Int? = 0
    private var pendingActivation: (pid: pid_t, remaining: Int)?
    private(set) var pauses = 0

    private func fake(_ window: WindowHandle) -> FakeWindow { window.element as! FakeWindow }

    func windows(pid: pid_t) -> [WindowHandle] { (appWindows[pid] ?? []).map { WindowHandle(element: $0) } }
    func isSameWindow(_ a: WindowHandle, _ b: WindowHandle) -> Bool { fake(a) === fake(b) }
    func isMinimized(_ window: WindowHandle) -> Bool { fake(window).minimized }
    func windowNumber(_ window: WindowHandle) -> CGWindowID? { fake(window).id }
    func frame(_ window: WindowHandle) -> CGRect? { fake(window).frame }
    func onScreenWindows() -> [OnScreenWindow] { onScreen }
    func isRegularApp(pid: pid_t) -> Bool { regularApps.contains(pid) }
    func appName(pid: pid_t) -> String { "app\(pid)" }
    func activate(pid: pid_t) {
        activated.append(pid)
        events.append("activate \(pid)")
        guard let delay = activationDelay else { return }
        if delay == 0 { frontmost = pid } else { pendingActivation = (pid, delay) }
    }
    func frontmostPID() -> pid_t? { frontmost }
    func pause(_ seconds: Double) {
        pauses += 1
        guard let pending = pendingActivation else { return }
        if pending.remaining <= 1 { frontmost = pending.pid; pendingActivation = nil }
        else { pendingActivation = (pending.pid, pending.remaining - 1) }
    }
    func focus(_ window: WindowHandle, pid: pid_t) {
        focused.append(fake(window).id)
        events.append("focus \(fake(window).id.map { String($0) } ?? "-")")
    }
    func log(_ message: String) {}
}

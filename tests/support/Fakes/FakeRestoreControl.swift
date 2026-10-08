// RestoreControl 的模拟实现：一个窗口，按配置决定各项写入是否生效，记下每一次调用。
// delay 不为 0 时每次调用先等这么久，模拟主线程卡住、辅助功能调用等到超时的应用程序。只编进测试二进制。

import CoreGraphics
import Foundation

final class FakeRestoreControl: RestoreControl, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var writesFail = false
    private var frontmost = false
    private let delay: TimeInterval

    init(delay: TimeInterval = 0, writesFail: Bool = false, frontmost: Bool = false) {
        self.delay = delay
        self.writesFail = writesFail
        self.frontmost = frontmost
    }

    var calls: [String] { lock.withLock { entries } }
    func setWritesFail(_ fail: Bool) { lock.withLock { writesFail = fail } }

    private func record(_ call: String) {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { entries.append(call) }
    }
    private var failing: Bool { lock.withLock { writesFail } }

    func resolve(_ window: WindowHandle, id: CGWindowID, pid: pid_t) -> WindowHandle { record("resolve"); return window }
    func unhideApp(pid: pid_t) { record("unhide") }
    func setMinimized(_ window: WindowHandle, _ minimized: Bool) { record("minimized=\(minimized)") }
    func isMinimized(_ window: WindowHandle) -> Bool { record("isMinimized"); return false }
    func setSize(_ window: WindowHandle, _ size: CGSize) -> Bool {
        record("size(\(Int(size.width))x\(Int(size.height)))"); return !failing
    }
    func setPosition(_ window: WindowHandle, _ point: CGPoint) -> Bool {
        record("position(\(Int(point.x)),\(Int(point.y)))"); return !failing
    }
    func frame(_ window: WindowHandle) -> CGRect? { record("frame"); return nil }
    func skyLightMove(id: CGWindowID, to point: CGPoint) -> Bool { record("skyLightMove"); return true }
    func skyLightSetAlpha(id: CGWindowID, _ alpha: Float) -> Bool { record("skyLightAlpha(\(alpha))"); return true }
    func isFrontmost(pid: pid_t) -> Bool { lock.withLock { frontmost } }
    func activate(pid: pid_t) { record("activate") }
    func raise(_ window: WindowHandle) { record("raise") }
    func focus(_ window: WindowHandle, pid: pid_t) { record("focus") }
    func log(_ message: String) {}
}

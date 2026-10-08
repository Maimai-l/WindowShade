// 展开（docs/design.md 第 5.5 节第 2 步）：把原窗口放回收起前的位置和大小，再交还焦点。
// 对其他应用程序的辅助功能调用都放在该应用程序自己的串行队列上（R5、第 5.8 节）：应用程序卡住时，
// 只有它自己的队列在等辅助功能超时，主线程和别的应用程序的展开不受影响。
// 底层操作经由 RestoreControl：App 里是辅助功能、SkyLight 调用（RestoreControlSystem），
// 测试里是模拟实现。只依赖 Foundation，测试直接编译。

import CoreGraphics
import Foundation

/// 放回原窗口用到的底层操作。全部是同步调用，WindowRestorer 负责放在应用程序的队列上。
protocol RestoreControl: Sendable {
    /// 原窗口还在就返回它；失效时在应用程序的窗口里按编号找回；找不到仍返回原窗口（写入会失败，不会动到别的窗口）。
    func resolve(_ window: WindowHandle, id: CGWindowID, pid: pid_t) -> WindowHandle
    func unhideApp(pid: pid_t)
    func setMinimized(_ window: WindowHandle, _ minimized: Bool)
    func isMinimized(_ window: WindowHandle) -> Bool
    func setSize(_ window: WindowHandle, _ size: CGSize) -> Bool
    func setPosition(_ window: WindowHandle, _ point: CGPoint) -> Bool
    func frame(_ window: WindowHandle) -> CGRect?
    func skyLightMove(id: CGWindowID, to point: CGPoint) -> Bool
    func skyLightSetAlpha(id: CGWindowID, _ alpha: Float) -> Bool
    func isFrontmost(pid: pid_t) -> Bool
    func activate(pid: pid_t)
    func raise(_ window: WindowHandle)
    func focus(_ window: WindowHandle, pid: pid_t)
    func log(_ message: String)
}

/// 一次放回所需的全部输入。position 已经由调用方夹到屏幕可见范围内。
struct RestoreRequest: Sendable {
    let window: WindowHandle
    let id: CGWindowID
    let pid: pid_t
    let hide: HideMethod
    let position: CGPoint
    let size: CGSize
    /// 用 SkyLight 设成透明前的透明度（hide 为 privateAlpha 时用）。
    let alpha: Float?
}

/// 每个应用程序一条串行队列：对同一个应用程序的辅助功能调用依次执行，对不同应用程序的互不等待。
final class AppQueues: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]

    func queue(for pid: pid_t) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[pid] { return queue }
            let queue = DispatchQueue(label: "WindowShade.app-\(pid)", qos: .userInteractive)
            queues[pid] = queue
            return queue
        }
    }
}

final class WindowRestorer: Sendable {
    let control: RestoreControl
    let queues: AppQueues

    init(control: RestoreControl, queues: AppQueues = AppQueues()) {
        self.control = control
        self.queues = queues
    }

    /// 在应用程序自己的队列上执行 work，结果交给 callbackQueue 上的 done。调用方不等待。
    func run<Value: Sendable>(pid: pid_t, after delay: TimeInterval = 0, callbackQueue: DispatchQueue = .main,
                              _ work: @escaping @Sendable () -> Value,
                              then done: @escaping @Sendable (Value) -> Void) {
        queues.queue(for: pid).asyncAfter(deadline: .now() + delay) {
            let value = work()
            callbackQueue.async { done(value) }
        }
    }

    /// 只在应用程序自己的队列上执行，不回调。
    func run(pid: pid_t, after delay: TimeInterval = 0, _ work: @escaping @Sendable () -> Void) {
        queues.queue(for: pid).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 按收起时的方式让原窗口重新可见，再放回原位置和大小。同步执行，调用方放在应用程序的队列上。
    func restore(_ request: RestoreRequest) -> WindowHandle {
        switch request.hide {
        case .privateOffscreen:
            let moved = control.skyLightMove(id: request.id, to: request.position)
            control.log("restore: private SLS move back id=\(request.id) ok=\(moved)")
        case .privateAlpha:
            let alpha = request.alpha ?? 1
            let ok = control.skyLightSetAlpha(id: request.id, alpha)
            control.log("restore: private SLS alpha back id=\(request.id) alpha=\(String(format: "%.2f", alpha)) ok=\(ok)")
        case .hidden:
            control.unhideApp(pid: request.pid)
        case .minimized:
            // 隐藏、最小化之后原辅助功能元素可能失效（Safari 常见），先重新找回再解除最小化。
            control.setMinimized(control.resolve(request.window, id: request.id, pid: request.pid), false)
        case .none, .offscreen, .ownWindowOrderedOut, .quickLookClosed:
            break
        }
        return place(request, label: "immediate", verify: true)
    }

    /// 写回大小和位置。element 是上一次找回的窗口，写入失败时再找一次重写。
    /// verify 为 false 时不回读（回读只用于日志）；写入失败时总是回读。
    @discardableResult
    func place(_ request: RestoreRequest, label: String, verify: Bool, element: WindowHandle? = nil) -> WindowHandle {
        var window = element ?? control.resolve(request.window, id: request.id, pid: request.pid)
        var sized = control.setSize(window, request.size)
        var placed = control.setPosition(window, request.position)
        if element != nil, !(sized && placed) {
            window = control.resolve(request.window, id: request.id, pid: request.pid)
            sized = control.setSize(window, request.size)
            placed = control.setPosition(window, request.position)
        }
        let failed = !(sized && placed)
        var actual = ""
        if verify || failed {
            actual = control.frame(window).map {
                " actual=(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))"
            } ?? " actual=<unavailable>"
        }
        // .github/demo/check_frames.py 按 “geometry: restore immediate target=(…) … actual=(…)” 读这一行。
        control.log("geometry: restore \(label) target=(\(Int(request.position.x)),\(Int(request.position.y)) "
                    + "\(Int(request.size.width))x\(Int(request.size.height))) ok=(size:\(sized),pos:\(placed))\(actual) id=\(request.id)")
        return window
    }

    /// 把应用程序和这扇窗口带到最前。应用程序已在最前时不再激活：连续激活会反复重启菜单栏的交叉淡入，
    /// 可能把两套菜单叠印留在屏幕上；这时只取消隐藏（隐藏后恢复的路径需要），再升起、聚焦窗口。
    func bringToFront(_ window: WindowHandle, pid: pid_t) {
        if control.isFrontmost(pid: pid) {
            control.unhideApp(pid: pid)
        } else {
            control.activate(pid: pid)
        }
        control.raise(window)
        control.focus(window, pid: pid)
    }
}

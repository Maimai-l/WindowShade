// 全局鼠标钩子遇到双击、三击时，问主线程要不要拦下这次按下。
//
// 钩子是主动钩子：它返回之前，全系统的鼠标和键盘输入都排在它后面。所以钩子线程等主线程有固定的时限，
// 过了时限一律放行，不管主线程是还没开始，还是开始了没做完（主线程可能在等一个无响应的应用程序，
// 那个应用程序又可能在等被钩子挡住的下一个鼠标事件；不设时限，全系统的输入就会停住）。
// 放行之后主线程的结论作废：主线程问 begin() 得到 false 就不再处理；已经开始的，finish 的结果不再被读取。
// 只依赖 Foundation，可单测（tests/TapDecisionTests.swift）。

import Foundation

final class TapDecision: @unchecked Sendable {
    /// 钩子线程最多等这么久。系统在钩子约 2 秒不返回时才停用它，这里要远小于那个值。
    static let deadline: TimeInterval = 0.4

    private enum State { case pending, started, finished(swallow: Bool), abandoned }

    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var state = State.pending

    /// 主线程开始处理前调用。返回 false：钩子已经放行，不要再处理。
    func begin() -> Bool {
        lock.withLock {
            guard case .pending = state else { return false }
            state = .started
            return true
        }
    }

    /// 主线程处理完调用。钩子已经放行的，结果丢掉。
    func finish(swallow: Bool) {
        let delivered = lock.withLock { () -> Bool in
            guard case .started = state else { return false }
            state = .finished(swallow: swallow)
            return true
        }
        if delivered { done.signal() }
    }

    /// 钩子线程调用：在时限内拿到主线程的结论就照办，否则放行（返回 false）并作废这次询问。
    func waitForSwallow(timeout: TimeInterval = TapDecision.deadline) -> Bool {
        _ = done.wait(timeout: .now() + timeout)
        return lock.withLock {
            if case .finished(let swallow) = state { return swallow }
            state = .abandoned
            return false
        }
    }

    /// 测试用：这次询问是否已被钩子放弃。
    var isAbandoned: Bool {
        lock.withLock {
            if case .abandoned = state { return true }
            return false
        }
    }
}

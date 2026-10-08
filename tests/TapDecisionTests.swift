// 需求：R6（docs/testing.md 第 3.6 节）。缺陷回归：2026-10-08 全系统输入卡死。
// 第 1 层：全局鼠标钩子问主线程时的硬时限（Core/TapDecision.swift）。
// 用另一条线程扮演主线程，注入“没开始”“开始了但卡住”“刚好在时限附近答完”等情形，
// 每种情形都检查：钩子在时限内返回；放行后主线程的结论不再生效；不会既放行又吞掉。

import Foundation

@main
struct TapDecisionTests {
    static let slack: TimeInterval = 0.15

    /// 钩子一侧：等结论，返回（吞不吞，用了多久）。
    static func hook(_ decision: TapDecision) -> (Bool, TimeInterval) {
        let start = Date()
        let swallow = decision.waitForSwallow()
        return (swallow, Date().timeIntervalSince(start))
    }

    static func main() {
        var t = TestSuite("tap-decision")
        let deadline = TapDecision.deadline
        t.expect(deadline <= 0.5, "the hook waits at most 0.5 s, far below the system's own tap timeout")

        t.section("R6", "主线程及时答复：照办")
        do {
            let decision = TapDecision()
            Thread.detachNewThread {
                guard decision.begin() else { return }
                decision.finish(swallow: true)
            }
            let (swallow, elapsed) = hook(decision)
            t.expect(swallow, "a quick answer to swallow is honoured")
            t.expect(elapsed < deadline, "returns as soon as the answer arrives (\(elapsed))")
        }

        t.section("R6", "主线程一直没开始（例如正在跟踪菜单）：到时放行，之后也不再处理")
        do {
            let decision = TapDecision()
            let (swallow, elapsed) = hook(decision)
            t.expect(!swallow, "passes the click through")
            t.expect(elapsed >= deadline - 0.01 && elapsed < deadline + slack, "returns at the deadline (\(elapsed))")
            t.expect(!decision.begin(), "the main thread is told not to handle an abandoned click")
        }

        t.section("R6", "主线程开始了但卡住（等一个不回话的 App）：到时放行，不无限等")
        do {
            let decision = TapDecision()
            let release = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                guard decision.begin() else { return }
                _ = release.wait(timeout: .now() + 5)   // 模拟卡住的主线程
                decision.finish(swallow: true)
            }
            let (swallow, elapsed) = hook(decision)
            t.expect(!swallow, "a stuck main thread does not get to swallow the click")
            t.expect(elapsed < deadline + slack, "the hook returns at the deadline, not when the main thread recovers (\(elapsed))")
            t.expect(decision.isAbandoned, "the question is marked abandoned")
            release.signal()
            Thread.sleep(forTimeInterval: 0.05)
            t.expect(decision.isAbandoned, "a late answer does not revive an abandoned question")
        }

        t.section("R6", "主线程永远不回来：钩子照样在时限内返回")
        do {
            let decision = TapDecision()
            Thread.detachNewThread {
                guard decision.begin() else { return }
                Thread.sleep(forTimeInterval: 3600)   // 永不 finish
            }
            let (swallow, elapsed) = hook(decision)
            t.expect(!swallow && elapsed < deadline + slack, "returns within the deadline (\(elapsed))")
        }

        t.section("R6", "压力：答复时间落在时限前后，500 次里结论始终一致、从不超时")
        do {
            var honoured = 0, passed = 0, inconsistent = 0, late = 0
            let shortDeadline: TimeInterval = 0.02
            for i in 0..<500 {
                let decision = TapDecision()
                let answerAfter = Double((i * 7919) % 100) / 100 * (shortDeadline * 1.6)
                let wantSwallow = i % 3 != 0
                let mainFinished = DispatchSemaphore(value: 0)
                let mainHandled = LockedFlag()
                Thread.detachNewThread {
                    defer { mainFinished.signal() }
                    guard decision.begin() else { return }
                    mainHandled.set()
                    if answerAfter > 0 { Thread.sleep(forTimeInterval: answerAfter) }
                    decision.finish(swallow: wantSwallow)
                }
                let start = Date()
                let swallow = decision.waitForSwallow(timeout: shortDeadline)
                if Date().timeIntervalSince(start) > shortDeadline + slack { late += 1 }
                _ = mainFinished.wait(timeout: .now() + 1)
                // 吞掉只可能来自主线程真的处理了、并且答的就是吞掉。
                if swallow && !(mainHandled.value && wantSwallow) { inconsistent += 1 }
                // 放行时，要么主线程没处理，要么这次询问已被放弃。
                if !swallow && mainHandled.value && wantSwallow && !decision.isAbandoned { inconsistent += 1 }
                if swallow { honoured += 1 } else { passed += 1 }
            }
            t.expect(inconsistent == 0, "no click is both passed through and handled as swallowed (\(inconsistent))")
            t.expect(late == 0, "the hook never overran its deadline (\(late) late)")
            t.expect(honoured > 0 && passed > 0, "both outcomes occurred (\(honoured) honoured, \(passed) passed)")
        }

        t.finish()
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

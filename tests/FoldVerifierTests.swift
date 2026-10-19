// 收起验证（prototype/Core/FoldVerifier.swift）：纯逻辑，用假的计时器和观察结果。
// 依据：上游 surfine/WindowShade 2d66e57。机器很忙时，收起验证的第一步轮到时已经过期，以前直接丢掉：
// 窗口已经藏起来，卷帘条却没显示，也没回滚，用户看到窗口凭空消失。
import Foundation

@main
struct FoldVerifierTests {
    static func main() {
        var t = TestSuite("FoldVerifierTests")

        // 手动推进的计时器：schedule 只登记，run() 依次执行。
        final class Clock {
            var pending: [() -> Void] = []
            func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) { pending.append(action) }
            func run() { while !pending.isEmpty { pending.removeFirst()() } }
        }

        t.section("V1", "收起验证途中过期：交给 onExpired 收尾，不静默丢掉")
        do {
            let clock = Clock()
            var current = true
            var expired = 0
            var results: [FoldVerifier.Observation] = []
            let verifier = FoldVerifier(schedule: clock.schedule, isCurrent: { current },
                                        observation: { .hidden }, salvage: { false },
                                        salvagedObservation: { .hidden },
                                        onExpired: { expired += 1 },
                                        result: { results.append($0) })
            verifier.start()
            current = false   // 第一步轮到之前，这次收起的回调已经过期（主线程一直没空，超过了时限）
            clock.run()
            t.expect(expired == 1, "过期时调用一次 onExpired（实际 \(expired) 次）")
            t.expect(results.isEmpty, "过期后不再按普通结果收尾")
        }

        t.section("V2", "没给 onExpired 时，过期只是停下")
        do {
            let clock = Clock()
            var current = true
            var results: [FoldVerifier.Observation] = []
            let verifier = FoldVerifier(schedule: clock.schedule, isCurrent: { current },
                                        observation: { .hidden }, salvage: { false },
                                        salvagedObservation: { .hidden },
                                        result: { results.append($0) })
            verifier.start()
            current = false
            clock.run()
            t.expect(results.isEmpty, "过期：不收尾")
        }

        t.section("V3", "没过期时照常收尾，不调用 onExpired")
        do {
            let clock = Clock()
            var expired = 0
            var results: [FoldVerifier.Observation] = []
            let verifier = FoldVerifier(schedule: clock.schedule, isCurrent: { true },
                                        observation: { .hidden }, salvage: { false },
                                        salvagedObservation: { .hidden },
                                        onExpired: { expired += 1 },
                                        result: { results.append($0) })
            verifier.start()
            clock.run()
            t.expect(results == [.hidden] && expired == 0, "读到已藏好：按已藏好收尾")
        }

        t.section("V4", "过期之后按重新读到的真实状态收尾")
        t.expect(FoldVerifier.expiredVerdict(sameFold: false, observation: .hidden) == .ignore,
                 "已经是另一次收起（或已展开）：不处理")
        t.expect(FoldVerifier.expiredVerdict(sameFold: true, observation: .hidden) == .complete,
                 "读到已藏好：显示卷帘条，按核对通过收尾")
        t.expect(FoldVerifier.expiredVerdict(sameFold: true, observation: .visible) == .rollback,
                 "读到窗口还在：回滚")
        t.expect(FoldVerifier.expiredVerdict(sameFold: true, observation: .unknown) == .retainUnconfirmed,
                 "读不准：显示卷帘条，提示可能没有收起")

        t.section("V5", "是不是同一次收起：不看时间和呈现编号")
        let id = UUID(), shown = UUID()
        let old = FoldCallbackStamp(window: 7, pid: 9, transaction: id, hide: "hidden", presentation: shown, capturedAt: 1)
        let later = FoldCallbackStamp(window: 7, pid: 9, transaction: id, hide: "hidden", presentation: UUID(), capturedAt: 50)
        let other = FoldCallbackStamp(window: 7, pid: 9, transaction: UUID(), hide: "hidden", presentation: shown, capturedAt: 1)
        t.expect(old.sameFold(as: later), "同一次收起，过了很久、切过桌面：还是同一次")
        t.expect(!old.sameFold(as: other), "另一次收起：不是同一次")
        t.finish()
    }
}

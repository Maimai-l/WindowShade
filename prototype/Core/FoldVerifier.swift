import Foundation

/// 检查一次已完成的收起。读不准时，绝不据此再改动窗口。
final class FoldVerifier {
    enum Observation: Equatable, Sendable { case hidden, visible, unknown }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private let schedule: Schedule
    private let isCurrent: () -> Bool
    private let observation: () -> Observation
    private let salvage: () -> Bool
    private let salvagedObservation: () -> Observation
    private let quickObservation: (() -> Observation)?
    private let result: (Observation) -> Void
    private let onExpired: (() -> Void)?
    private var started = false
    private var finished = false
    private static let quickInterval: TimeInterval = 0.03

    /// 收起验证途中过期以后怎么收尾。过期是因为机器很忙、主线程一直没空，超过了时限。
    /// 切桌面、显示器变化换了呈现编号不算过期（见 FoldCallbackStamp.acceptsIgnoringPresentation）。
    /// 以前过期就丢掉：窗口已经藏起来，卷帘条却没显示，也没提示“窗口可能未收起”，也没回滚，用户看到窗口凭空消失
    /// （上游 surfine/WindowShade 2d66e57：虚拟机上安装阶段用了 9.5 秒）。
    enum ExpiredVerdict: Equatable, Sendable {
        /// 这扇窗口已经是另一次收起，或已经展开、清理：旧的收起验证不处理。
        case ignore
        /// 重新读到已藏好：显示卷帘条，按核对通过收尾。
        case complete
        /// 重新读到窗口还在：回滚。
        case rollback
        /// 读不准：照样显示卷帘条，提示“窗口可能未收起，双击展开”，保留恢复记录。
        case retainUnconfirmed
    }

    /// 过期以后不看时间，只看两件事：是不是同一次收起，重新读到的真实状态。
    static func expiredVerdict(sameFold: Bool, observation: Observation) -> ExpiredVerdict {
        guard sameFold else { return .ignore }
        switch observation {
        case .hidden: return .complete
        case .visible: return .rollback
        case .unknown: return .retainUnconfirmed
        }
    }

    init(schedule: @escaping Schedule, isCurrent: @escaping () -> Bool,
         observation: @escaping () -> Observation, salvage: @escaping () -> Bool,
         salvagedObservation: @escaping () -> Observation,
         quickObservation: (() -> Observation)? = nil,
         onExpired: (() -> Void)? = nil,
         result: @escaping (Observation) -> Void) {
        self.onExpired = onExpired
        self.schedule = schedule; self.isCurrent = isCurrent
        self.observation = observation; self.salvage = salvage
        self.salvagedObservation = salvagedObservation
        self.quickObservation = quickObservation; self.result = result
    }

    // 给只认 Bool 的旧调用方和测试用。正式代码用上面的三态初始化方法，
    // 也不传 quickObservation（按窗口不在屏幕上提前判定）。
    convenience init(schedule: @escaping Schedule, isCurrent: @escaping () -> Bool,
                     observe: @escaping () -> Bool, minimize: @escaping () -> Void,
                     observeMinimized: @escaping () -> Bool,
                     quickObserve: @escaping () -> Bool = { false },
                     completion: @escaping (Bool) -> Void) {
        self.init(schedule: schedule, isCurrent: isCurrent,
                  observation: { observe() ? .hidden : .visible },
                  salvage: { minimize(); return true },
                  salvagedObservation: { observeMinimized() ? .hidden : .visible },
                  quickObservation: { quickObserve() ? .hidden : .unknown },
                  result: { completion($0 == .hidden) })
    }

    func start() {
        guard !started else { return }; started = true
        pollQuickly(until: 0.15, elapsed: 0)
        schedule(0.15) { self.check(attempt: 1) }
    }

    private func pollQuickly(until deadline: TimeInterval, elapsed: TimeInterval) {
        guard quickObservation != nil else { return }
        let next = elapsed + Self.quickInterval
        guard next < deadline - 0.001 else { return }
        schedule(Self.quickInterval) {
            guard !self.finished, self.isCurrent() else { return }
            if self.quickObservation?() == .hidden { self.finish(.hidden); return }
            guard self.isCurrent() else { return }
            self.pollQuickly(until: deadline, elapsed: next)
        }
    }

    private func check(attempt: Int) {
        guard live() else { return }
        let seen = observation()
        guard live() else { return }
        if seen == .hidden { finish(.hidden) }
        else if attempt == 1 {
            pollQuickly(until: 0.45, elapsed: 0)
            schedule(0.45) { self.check(attempt: 2) }
        } else if seen == .unknown { finish(.unknown) }
        else {
            // salvage 在真正改动窗口前，要再核对一次窗口身份和权限。
            let attempted = salvage()
            guard live() else { return }
            guard attempted else { finish(.visible); return }
            schedule(0.35) {
                guard self.live() else { return }
                let seen = self.salvagedObservation()
                guard self.live() else { return }
                self.finish(seen)
            }
        }
    }

    private func finish(_ value: Observation) {
        guard !finished, isCurrent() else { return }
        finished = true
        result(value)
    }

    /// 收起验证的主链（check → 补救 → 补救后再读）每一步前后的检查。链在这里断了就不会再排下一步，
    /// 所以过期时交给 onExpired 收尾，不静默丢掉。快速轮询那条支线不走这里：它断了，主链还在。
    /// 没给 onExpired 时只返回 false。
    private func live() -> Bool {
        guard !finished else { return false }
        if isCurrent() { return true }
        if let onExpired {
            finished = true
            onExpired()
        }
        return false
    }
}

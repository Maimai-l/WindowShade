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
    private var started = false
    private var finished = false
    private static let quickInterval: TimeInterval = 0.03

    init(schedule: @escaping Schedule, isCurrent: @escaping () -> Bool,
         observation: @escaping () -> Observation, salvage: @escaping () -> Bool,
         salvagedObservation: @escaping () -> Observation,
         quickObservation: (() -> Observation)? = nil,
         result: @escaping (Observation) -> Void) {
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
        guard !finished, isCurrent() else { return }
        let seen = observation()
        guard !finished, isCurrent() else { return }
        if seen == .hidden { finish(.hidden) }
        else if attempt == 1 {
            pollQuickly(until: 0.45, elapsed: 0)
            schedule(0.45) { self.check(attempt: 2) }
        } else if seen == .unknown { finish(.unknown) }
        else {
            // salvage 在真正改动窗口前，要再核对一次窗口身份和权限。
            let attempted = salvage()
            guard !finished, isCurrent() else { return }
            guard attempted else { finish(.visible); return }
            schedule(0.35) {
                guard !self.finished, self.isCurrent() else { return }
                self.finish(self.salvagedObservation())
            }
        }
    }

    private func finish(_ value: Observation) {
        guard !finished, isCurrent() else { return }
        finished = true
        result(value)
    }
}

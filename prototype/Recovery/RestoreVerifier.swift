import Foundation

enum RestoreObservation { case pending, visible, closed }

/// 把“确认放回成功”和“放回窗口”分开。时钟、观察和确认都由外部传入，超时、取消、重试走的是和正式代码相同的逻辑。
/// 观察通过回调给出结果：它在主线程以外读另一个应用程序的窗口（R5），拿到结果后才安排下一次检查，
/// 应用程序无响应时读取也不会越积越多。
final class RestoreVerifier {
  typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
  typealias Observe = (@escaping (RestoreObservation) -> Void) -> Void
  private let now: () -> TimeInterval
  private let schedule: Schedule
  private let isCurrent: () -> Bool
  private let observe: Observe
  private let acknowledge: () -> Void
  private let completion: (Bool) -> Void
  private var started = 0.0
  private var closedCount = 0
  private var finished = false

  init(
    now: @escaping () -> TimeInterval, schedule: @escaping Schedule,
    isCurrent: @escaping () -> Bool, observe: @escaping Observe,
    acknowledge: @escaping () -> Void, completion: @escaping (Bool) -> Void
  ) {
    self.now = now
    self.schedule = schedule
    self.isCurrent = isCurrent
    self.observe = observe
    self.acknowledge = acknowledge
    self.completion = completion
  }
  func start() {
    started = now()
    schedule(0) { self.check() }
  }
  private func check() {
    guard !finished, isCurrent() else {
      finished = true
      return
    }
    observe { result in self.handle(result) }
  }
  private func handle(_ result: RestoreObservation) {
    guard !finished, isCurrent() else {
      finished = true
      return
    }
    closedCount = result == .closed ? closedCount + 1 : 0
    if result == .visible || closedCount >= 2 {
      finished = true
      acknowledge()
      completion(result == .visible)
    } else if now() - started >= 1.5 {
      finished = true
      completion(false)
    } else {
      schedule(0.05) { self.check() }
    }
  }
}

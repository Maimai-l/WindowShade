import Foundation

enum RestoreObservation { case pending, visible, closed }

/// Separates restore acknowledgement from the platform mutation. Clock, observation and journal
/// acknowledgement are injected so timeouts, cancellation and retry use the same production logic.
/// Observation answers through a callback: it reads the other app's window off the main thread (R5),
/// and the next check is scheduled only after the answer, so a frozen app never piles up reads.
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

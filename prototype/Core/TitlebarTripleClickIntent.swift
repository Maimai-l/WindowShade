/// 把先后到达的两件事（第三下点击、收起确认完成）合在一起，不持有界面回调。
/// 两件都到了时返回 true，只返回一次。
final class TitlebarTripleClickIntent {
    private enum State { case waiting, requested, folded, finished }
    private var state: State = .waiting

    func request() -> Bool {
        switch state {
        case .waiting: state = .requested; return false
        case .folded: state = .finished; return true
        case .requested, .finished: return false
        }
    }

    func completeFold(success: Bool) -> Bool {
        guard success else { cancel(); return false }
        switch state {
        case .waiting: state = .folded; return false
        case .requested: state = .finished; return true
        case .folded, .finished: return false
        }
    }

    func cancel() { state = .finished }
}

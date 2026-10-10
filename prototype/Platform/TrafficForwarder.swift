// 卷帘条上的红绿灯转给原窗口（docs/design.md S3）：只用辅助功能操作原窗口的按钮或属性，
// 不合成任何鼠标、键盘事件，不移动光标。
//
// 每个动作至多按一次。原窗口刚放回来时按钮可能还没就绪，就等一会儿再看；一旦按过（不论按的结果），
// 就不再按第二次：关闭一个有未保存内容的窗口时会弹出“是否保存”，窗口还在是正常的，不能因此再按一次。
// 底层经由 TrafficButtonControl：App 里是辅助功能调用，测试里是模拟实现。只依赖 Foundation。

import Foundation

enum ForwardedTrafficAction: String, Equatable, Sendable {
    case close, minimize, zoom, fullScreen
}

protocol TrafficButtonControl {
    /// 原窗口已经回到可操作的位置和大小。
    var windowReady: Bool { get }
    /// 原窗口上这个按钮存在、有大小、可用。
    func buttonReady(_ action: ForwardedTrafficAction) -> Bool
    /// 对这个按钮执行一次辅助功能的“按下”。返回辅助功能调用是否成功。
    func press(_ action: ForwardedTrafficAction) -> Bool
    /// 直接设属性：最小化写 AXMinimized，全屏写 AXFullScreen。不支持的动作返回 false。
    func setAttribute(for action: ForwardedTrafficAction) -> Bool
}

struct TrafficForwarder {
    enum Step: Equatable {
        /// 已经执行了，结束。how 写进日志。
        case done(how: String)
        /// 窗口或按钮还没就绪，过一会儿再来。
        case wait(TimeInterval)
        /// 等不到，放弃。
        case gaveUp
    }

    /// 第 n 次没就绪后，等多久再看第 n + 1 次。
    static let waitDelays: [TimeInterval] = [0.035, 0.08, 0.14, 0.24, 0.40, 0.65]

    let control: TrafficButtonControl

    func step(_ action: ForwardedTrafficAction, attempt: Int) -> Step {
        guard control.windowReady else { return wait(after: attempt) }
        switch action {
        case .minimize, .fullScreen:
            if control.setAttribute(for: action) { return .done(how: "attribute") }
        case .close, .zoom:
            break
        }
        guard control.buttonReady(action) else { return wait(after: attempt) }
        let pressed = control.press(action)
        // 按过就结束：辅助功能调用报错时，按下也可能已经生效（例如 App 弹出对话框后才回话）。
        return .done(how: pressed ? "press" : "press-reported-error")
    }

    private func wait(after attempt: Int) -> Step {
        attempt < Self.waitDelays.count ? .wait(Self.waitDelays[attempt]) : .gaveUp
    }
}

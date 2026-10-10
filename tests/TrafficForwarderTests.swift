// 需求：S3、R6（docs/testing.md 第 3.2、3.6 节）。缺陷回归：2026-10-08 全系统输入停止响应。
// 第 2 层：卷帘条上的红绿灯转给原窗口（Platform/TrafficForwarder.swift）。
// 在模拟窗口上把整个重试过程跑完，检查每个动作至多按一次、按过就不再按，
// 包括“关闭后弹出是否保存、窗口还在”这一情形。

import Foundation

/// 模拟的原窗口按钮：前 notReadyFor 次查看时还没就绪；记下每一次调用。
final class FakeTrafficButtons: TrafficButtonControl {
    var notReadyFor = 0
    var windowNotReadyFor = 0
    var pressSucceeds = true
    var attributeSucceeds = false
    private(set) var looks = 0
    private(set) var windowLooks = 0
    private(set) var presses: [ForwardedTrafficAction] = []
    private(set) var attributeWrites: [ForwardedTrafficAction] = []

    var windowReady: Bool {
        windowLooks += 1
        return windowLooks > windowNotReadyFor
    }

    func buttonReady(_ action: ForwardedTrafficAction) -> Bool {
        looks += 1
        return looks > notReadyFor
    }

    func press(_ action: ForwardedTrafficAction) -> Bool {
        presses.append(action)
        return pressSucceeds
    }

    func setAttribute(for action: ForwardedTrafficAction) -> Bool {
        attributeWrites.append(action)
        return attributeSucceeds
    }
}

@main
struct TrafficForwarderTests {
    /// 照 App 里的驱动方式跑到底：.wait 就进入下一次，直到 .done 或 .gaveUp。返回最后一步和总等待时间。
    static func run(_ action: ForwardedTrafficAction, on buttons: FakeTrafficButtons) -> (TrafficForwarder.Step, TimeInterval, Int) {
        let forwarder = TrafficForwarder(control: buttons)
        var waited: TimeInterval = 0
        var attempt = 0
        while true {
            let step = forwarder.step(action, attempt: attempt)
            guard case .wait(let delay) = step else { return (step, waited, attempt + 1) }
            waited += delay
            attempt += 1
            precondition(attempt < 100, "the forwarder must end")
        }
    }

    static func main() {
        var t = TestSuite("traffic-forwarder")

        t.section("R6", "关闭有未保存内容的窗口：按一次关闭，弹出是否保存后不再按（缺陷回归）")
        do {
            // 弹出“是否保存”时窗口还在：转发器不检查窗口是否消失，也就没有“没关掉、再按一次”这条路。
            let buttons = FakeTrafficButtons()
            let (step, _, attempts) = run(.close, on: buttons)
            t.expect(buttons.presses == [.close], "exactly one close press (\(buttons.presses))")
            t.expect(step == .done(how: "press") && attempts == 1, "done after the first press")
        }

        t.section("R6", "按下时辅助功能报错（App 弹出对话框后才回话）：也不再按第二次")
        do {
            let buttons = FakeTrafficButtons()
            buttons.pressSucceeds = false
            let (step, _, _) = run(.close, on: buttons)
            t.expect(buttons.presses == [.close], "still exactly one press (\(buttons.presses))")
            t.expect(step == .done(how: "press-reported-error"), "the error is logged, not retried")
        }

        t.section("S3", "窗口刚放回来、按钮还没就绪：等它就绪再按，只按一次")
        do {
            let buttons = FakeTrafficButtons()
            buttons.windowNotReadyFor = 1
            buttons.notReadyFor = 2
            let (step, waited, attempts) = run(.close, on: buttons)
            t.expect(buttons.presses == [.close], "one press after waiting (\(buttons.presses))")
            t.expect(step == .done(how: "press") && attempts == 4, "pressed on the fourth look (\(attempts))")
            t.expect(waited < 0.3, "waited only for readiness (\(waited) s)")
        }

        t.section("S3", "按钮一直不就绪：有限次后放弃，从不按")
        do {
            let buttons = FakeTrafficButtons()
            buttons.notReadyFor = .max
            let (step, waited, attempts) = run(.close, on: buttons)
            t.expect(step == .gaveUp && buttons.presses.isEmpty, "gives up without pressing")
            t.expect(attempts == TrafficForwarder.waitDelays.count + 1, "bounded number of looks (\(attempts))")
            t.expect(waited < 2, "gives up within 2 s (\(waited) s)")
        }

        t.section("S3", "最小化、全屏先写属性；写成了就不按按钮")
        for action in [ForwardedTrafficAction.minimize, .fullScreen] {
            let buttons = FakeTrafficButtons()
            buttons.attributeSucceeds = true
            let (step, _, _) = run(action, on: buttons)
            t.expect(step == .done(how: "attribute") && buttons.presses.isEmpty,
                     "\(action): attribute only, no button press")
        }

        t.section("S3", "属性写不进去时按一次按钮；缩放直接按一次按钮")
        for action in [ForwardedTrafficAction.minimize, .fullScreen, .zoom] {
            let buttons = FakeTrafficButtons()
            let (step, _, _) = run(action, on: buttons)
            t.expect(buttons.presses == [action] && step == .done(how: "press"), "\(action): one press")
            t.expect(buttons.attributeWrites.count <= 1, "\(action): at most one attribute write")
        }

        t.section("R6", "关闭和缩放从不写属性")
        for action in [ForwardedTrafficAction.close, .zoom] {
            let buttons = FakeTrafficButtons()
            _ = run(action, on: buttons)
            t.expect(buttons.attributeWrites.isEmpty, "\(action): no attribute writes")
        }

        t.finish()
    }
}

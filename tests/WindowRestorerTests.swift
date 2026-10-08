// 需求：F2、R5（docs/design.md 第 3.1、3.6 节）。
// 第 2 层组件测试：WindowRestorer 放回原窗口的顺序，以及对卡住的应用程序的调用不让调用方等待（Platform/WindowRestorer.swift）。

import CoreGraphics
import Foundation

@main
struct WindowRestorerTests {
    static let position = CGPoint(x: 200, y: 150)
    static let size = CGSize(width: 700, height: 460)

    static func request(_ hide: HideMethod, pid: pid_t = 7, alpha: Float? = nil) -> RestoreRequest {
        RestoreRequest(window: WindowHandle(element: NSObject()), id: 42, pid: pid, hide: hide,
                       position: position, size: size, alpha: alpha)
    }

    static func main() {
        var t = TestSuite("window-restorer")
        let geometry = ["resolve", "size(700x460)", "position(200,150)", "frame"]

        t.section("F2", "移到屏幕外的窗口：直接写回大小和位置，回读一次")
        do {
            let control = FakeRestoreControl()
            _ = WindowRestorer(control: control).restore(request(.offscreen))
            t.expect(control.calls == geometry, "调用顺序为 \(geometry)（实际 \(control.calls)）")
        }

        t.section("F2", "隐藏的应用程序：先取消隐藏，再写回")
        do {
            let control = FakeRestoreControl()
            _ = WindowRestorer(control: control).restore(request(.hidden))
            t.expect(control.calls == ["unhide"] + geometry, "先取消隐藏（实际 \(control.calls)）")
        }

        t.section("F2", "最小化的窗口：先找回窗口、解除最小化，再写回")
        do {
            let control = FakeRestoreControl()
            _ = WindowRestorer(control: control).restore(request(.minimized))
            t.expect(control.calls == ["resolve", "minimized=false"] + geometry, "先解除最小化（实际 \(control.calls)）")
        }

        t.section("F2", "用 SkyLight 移开或设成透明的窗口：按原来的方式移回、恢复透明度")
        do {
            let moved = FakeRestoreControl()
            _ = WindowRestorer(control: moved).restore(request(.privateOffscreen))
            t.expect(moved.calls.first == "skyLightMove", "先用 SkyLight 移回")
            let faded = FakeRestoreControl()
            _ = WindowRestorer(control: faded).restore(request(.privateAlpha, alpha: 0.9))
            t.expect(faded.calls.first == "skyLightAlpha(0.9)", "恢复成收起前的透明度（实际 \(faded.calls)）")
            let unknown = FakeRestoreControl()
            _ = WindowRestorer(control: unknown).restore(request(.privateAlpha))
            t.expect(unknown.calls.first == "skyLightAlpha(1.0)", "没有记录时恢复为不透明")
        }

        t.section("F2", "复用上一次找回的窗口：写入成功时不再找；写入失败时找一次重写")
        do {
            let control = FakeRestoreControl()
            let restorer = WindowRestorer(control: control)
            let window = WindowHandle(element: NSObject())
            restorer.place(request(.offscreen), label: "after-250ms", verify: false, element: window)
            t.expect(control.calls == ["size(700x460)", "position(200,150)"], "写入成功：不找回、不回读（实际 \(control.calls)）")
            let failing = FakeRestoreControl(writesFail: true)
            WindowRestorer(control: failing).place(request(.offscreen), label: "after-250ms", verify: false, element: window)
            t.expect(failing.calls == ["size(700x460)", "position(200,150)", "resolve", "size(700x460)", "position(200,150)", "frame"],
                     "写入失败：找回一次重写，并回读写进日志（实际 \(failing.calls)）")
        }

        t.section("F2", "带到最前：应用程序不在最前时激活；已在最前时只取消隐藏，不重复激活")
        do {
            let behind = FakeRestoreControl()
            WindowRestorer(control: behind).bringToFront(WindowHandle(element: NSObject()), pid: 7)
            t.expect(behind.calls == ["activate", "raise", "focus"], "激活、升起、聚焦（实际 \(behind.calls)）")
            let front = FakeRestoreControl(frontmost: true)
            WindowRestorer(control: front).bringToFront(WindowHandle(element: NSObject()), pid: 7)
            t.expect(front.calls == ["unhide", "raise", "focus"], "不再激活（实际 \(front.calls)）")
        }

        t.section("R5", "应用程序卡住：调用方立即返回；同一应用程序的操作依次执行；别的应用程序不等它")
        do {
            // 每次调用等 0.25 秒：一次放回 6 次调用，共约 1.5 秒。
            let frozen = FakeRestoreControl(delay: 0.25)
            let queues = AppQueues()
            let slow = WindowRestorer(control: frozen, queues: queues)
            let callback = DispatchQueue(label: "callback")
            let order = Order()
            let done = DispatchGroup()

            let start = Date()
            done.enter()
            slow.run(pid: 7, callbackQueue: callback, { _ = slow.restore(request(.hidden)) }, then: { _ in
                order.add("frozen-restore"); done.leave()
            })
            done.enter()
            slow.run(pid: 7, callbackQueue: callback, { order.add("frozen-second") }, then: { _ in done.leave() })
            let returned = Date().timeIntervalSince(start)
            t.expect(returned < 0.05, "交给卡住的应用程序后调用方立即返回（\(Int(returned * 1000)) 毫秒）")

            let responsive = FakeRestoreControl()
            let fast = WindowRestorer(control: responsive, queues: queues)
            done.enter()
            fast.run(pid: 8, callbackQueue: callback, { _ = fast.restore(request(.offscreen, pid: 8)) }, then: { _ in
                order.add("other-app"); done.leave()
            })
            t.expect(done.wait(timeout: .now() + 5) == .success, "全部在 5 秒内完成")
            let seen = order.values
            t.expect(seen.first == "other-app", "别的应用程序先完成，不等卡住的那个（实际 \(seen)）")
            t.expect(seen.firstIndex(of: "frozen-restore").map { $0 < (seen.firstIndex(of: "frozen-second") ?? -1) } == true,
                     "同一应用程序的两次操作按提交顺序执行（实际 \(seen)）")
        }

        t.finish()
    }
}

final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ value: String) { lock.withLock { list.append(value) } }
    var values: [String] { lock.withLock { list } }
}

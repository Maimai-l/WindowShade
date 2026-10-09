// 检查的检查（docs/test-catalog.md 第 12 节）：每一项不变式检查，都要证明它会对错误的行为报错。
// 这些场景故意制造违反，调用场景结束时用的同一段检查代码，确认它报出来；报出来才算通过。
// 制造违反的是驱动程序自己（它代替出错的 WindowShade），所以 WindowShade 的代码里不需要任何测试开关。

import AppKit
import ApplicationServices

/// 把带标记的探测点击扣下，过 delay 秒再原样发出去（K02）：相当于有一个钩子把点击挡了这么久。
/// 只扣第一次见到的标记，再发出去的那一次放行；和它配对的松开也一起推后，免得按键状态错乱。
final class ClickDelayer: @unchecked Sendable {
    let delay: Double
    private let lock = NSLock()
    private var held: Set<Int64> = []
    private var holdNextUp = false
    private var tap: CFMachPort?

    init(delay: Double) { self.delay = delay }

    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.leftMouseUp.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let delayer = Unmanaged<ClickDelayer>.fromOpaque(refcon).takeUnretainedValue()
            return delayer.hold(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.start()
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    private func hold(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let shouldHold: Bool = lock.withLock {
            if type == .leftMouseDown {
                guard tag != 0, held.insert(tag).inserted else { return false }
                holdNextUp = true
                return true
            }
            guard holdNextUp else { return false }
            holdNextUp = false
            return true
        }
        guard shouldHold, let copy = event.copy() else { return false }
        let after = type == .leftMouseDown ? delay : delay + 0.05
        DispatchQueue.global().asyncAfter(deadline: .now() + after) { copy.post(tap: .cghidEventTap) }
        return true
    }
}

/// 收下一次按下后很久不返回的钩子（K06）：相当于钩子回调无时限地等一个不回话的主线程
/// （修复之前 WindowShade 的钩子就是这样，docs/testing.md 第 5 节 2026-10-08 那一行）。
/// 只挡带 tag 标记的那一次按下，挡 hold 秒后放行；记下系统有没有因为超时停用它。
final class StuckTap: @unchecked Sendable {
    let tag: Int64
    let hold: Double
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var disabledAt: Date?
    private var returnedAt: Date?

    init(tag: Int64, hold: Double) {
        self.tag = tag
        self.hold = hold
    }

    func start() -> Bool {
        let mask = CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
            if let refcon { Unmanaged<StuckTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.start()
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    /// 系统因为超时停用它的时刻、挡住的那次回调返回的时刻。
    var facts: (disabled: Date?, returned: Date?) { lock.withLock { (disabledAt, returnedAt) } }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout {
            lock.withLock { if disabledAt == nil { disabledAt = Date() } }
            return
        }
        guard type == .leftMouseDown, event.getIntegerValueField(.eventSourceUserData) == tag else { return }
        Thread.sleep(forTimeInterval: hold)
        lock.withLock { returnedAt = Date() }
    }
}

/// 发一次带标记的按键（K06 测按键是否也排在被挡住的点击后面）。
func postTaggedKey(_ key: CGKeyCode, tag: Int64) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
        event.setIntegerValueField(.eventSourceUserData, value: down ? tag : 0)
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}

/// 在 AX 里按一扇窗口的关闭按钮（K03 用来对同一个应用程序发两次关闭请求）。
func pressCloseButton(_ window: AXUIElement) -> Bool {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &ref) == .success,
          let ref else { return false }
    return AXUIElementPerformAction(ref as! AXUIElement, kAXPressAction as CFString) == .success
}

let checkScenarios: [Scenario] = [
    Scenario(id: "K01", title: "检查的检查 I3：被监视的进程合成一次输入，检查报错", options: [], group: "checks") { _, h in
        // 驱动程序暂时顶替 WindowShade 成为被监视的进程，自己发一个指针移动事件。
        let watched = windowShadePID()
        _ = h.audit.takeSynthetic()
        h.audit.watch(getpid())
        post(.mouseMoved, at: h.neutral)
        await pause(0.5)
        let caught = h.audit.takeSynthetic()
        if let watched { h.audit.watch(watched) }
        let violations = Harness.inputViolations(caught)
        h.expect(violations.contains { $0.hasPrefix("I3:") },
                 "K01: I3 did not report an input event posted by the watched process (caught \(caught.count))")
        h.expect(Harness.inputViolations([]).isEmpty, "K01: I3 reported a violation with no events")
        h.result.notes["reported"] = violations
    },
    Scenario(id: "K02", title: "检查的检查 I2：探测点击被挡 1.5 秒，检查报错", options: [], group: "checks") { _, h in
        let delayer = ClickDelayer(delay: 1.5)
        guard delayer.start() else {
            h.result.violations.append("setup: cannot install the delaying event tap")
            return
        }
        let before = h.result.violations.count
        await h.probeInput()
        delayer.stop()
        let reported = Array(h.result.violations[before...])
        h.result.violations.removeSubrange(before...)
        h.expect(reported.contains { $0.hasPrefix("I2:") }, "K02: I2 did not report a probe click held for 1.5 s")
        h.result.notes["reported"] = reported
        // 拦截撤掉以后，探测点击照常穿过：这一次留在结果里，作为对照。
        await pause(0.5)
        await h.probeInput()
    },
    Scenario(id: "K03", title: "检查的检查 I4：关闭请求发了两次，检查报错", options: ["--windows=2"], group: "checks") { probe, h in
        // 驱动程序代替出错的 WindowShade，对同一个应用程序发两次关闭请求。
        var pressed = 0
        for window in probe.allWindows() where pressCloseButton(window) {
            pressed += 1
            await pause(0.3)
        }
        h.expect(pressed == 2, "setup: pressed \(pressed) close buttons, expected 2")
        _ = await eventually(3) { probe.count("close-request") >= 2 }
        let requests = probe.count("close-request")
        let reported = Harness.onceViolation("close was requested", requests)
        h.expect(requests == 2 && reported != nil, "K03: I4 did not report \(requests) close requests")
        // 日志那一侧（WindowShade 转发了几次）走同一个计数。
        let forwardedTwice = ["traffic: close forwarded id=1 how=press attempt=0",
                              "traffic: close forwarded id=1 how=press attempt=0"]
        h.expect(Harness.onceViolation("WindowShade forwarded close",
                                       forwardedTwice.filter { $0.contains("traffic: close forwarded") }.count) != nil,
                 "K03: I4 did not report close forwarded twice")
        h.expect(Harness.onceViolation("close was requested", 1) == nil, "K03: I4 reported a single close request")
        h.result.notes["reported"] = reported ?? ""
    },
    Scenario(id: "K04", title: "检查的检查 I5、I6：非法状态转换和超过 500 毫秒的停顿，检查报错", options: [], group: "checks") { _, h in
        let lines = [
            "12:00:00.000 main-thread stall ≈501ms 期间=未标记",
            "12:00:01.000 main-thread stall ≈499ms 期间=未标记",
            "12:00:02.000 main-thread tracking ended ≈900ms (menu or drag tracking; waiting for input, not a stall)",
            "12:00:03.000 main-thread stall sample 1/4 ≈620ms: AppKit:-[NSApplication run]",
            "12:00:04.000 state: illegal transition folded -> capturing id=1",
        ]
        let reported = Harness.logViolations(lines)
        h.expect(reported.contains { $0.hasPrefix("I6:") && $0.contains("≈501ms") }, "K04: I6 did not report a 501 ms stall")
        h.expect(!reported.contains { $0.contains("≈499ms") }, "K04: I6 reported a 499 ms stall")
        h.expect(!reported.contains { $0.contains("tracking") || $0.contains("sample") },
                 "K04: I6 counted a tracking period or a stack sample as a stall")
        h.expect(reported.contains { $0.hasPrefix("I5:") }, "K04: I5 did not report an illegal transition")
        h.expect(reported.count == 2, "K04: expected exactly 2 violations, got \(reported)")
        h.result.notes["reported"] = reported
    },
    Scenario(id: "K06", title: "检查的检查 I2：钩子收下一次点击后 8 秒不返回，检查报错；同时测按键是否也被挡",
             options: [], group: "checks") { _, h in
        // 同时是一次测量：系统会不会切断一个收下了事件、迟迟不返回的钩子，键盘是否也排在它后面。
        // 2026-10-08 用户那次：指针能动、触控板手势有效，点击和快捷键都没有反应，只能强制重启。
        let stuckTag: Int64 = 0x6B06_0001, clickTag: Int64 = 0x6B06_0002, keyTag: Int64 = 0x6B06_0003
        let stuck = StuckTap(tag: stuckTag, hold: 8)
        guard stuck.start() else {
            h.result.violations.append("setup: cannot install the stuck event tap")
            return
        }
        let start = Date()
        postTagged(.leftMouseDown, at: h.neutral, clicks: 1, tag: stuckTag)
        postTagged(.leftMouseUp, at: h.neutral, clicks: 1, tag: 0)
        await pause(0.3)
        let sent = Date()
        postTagged(.leftMouseDown, at: h.neutral, clicks: 1, tag: clickTag)
        postTagged(.leftMouseUp, at: h.neutral, clicks: 1, tag: 0)
        postTaggedKey(80, tag: keyTag)   // F19：系统和常用应用程序都不用它
        // 场景结束时用的同一段 I2 检查。
        let before = h.result.violations.count
        await h.probeInput()
        let reported = Array(h.result.violations[before...])
        h.result.violations.removeSubrange(before...)
        _ = await eventually(12) { [stuckTag, clickTag, keyTag].allSatisfy { h.audit.arrival($0) != nil } }
        stuck.stop()
        func milliseconds(_ date: Date?, from origin: Date) -> Any {
            date.map { Int($0.timeIntervalSince(origin) * 1000) } ?? "never"
        }
        let facts = stuck.facts
        let clickLatency = h.audit.arrival(clickTag)?.timeIntervalSince(sent)
        let keyLatency = h.audit.arrival(keyTag)?.timeIntervalSince(sent)
        h.result.notes["stuckClickMs"] = milliseconds(h.audit.arrival(stuckTag), from: start)
        h.result.notes["probeClickMs"] = milliseconds(h.audit.arrival(clickTag), from: sent)
        h.result.notes["probeKeyMs"] = milliseconds(h.audit.arrival(keyTag), from: sent)
        h.result.notes["tapDisabledByTimeoutMs"] = milliseconds(facts.disabled, from: start)
        h.result.notes["callbackReturnedMs"] = milliseconds(facts.returned, from: start)
        h.result.notes["keysWaited"] = keyLatency.map { $0 > 1 } ?? true
        h.result.notes["reported"] = reported
        // I2 的结论要和实测一致：点击晚于 1 秒（或没到）就必须报出来，按时到了就不能报。
        if clickLatency.map({ $0 > 1 }) ?? true {
            h.expect(reported.contains { $0.hasPrefix("I2:") }, "K06: I2 did not report while a tap held clicks for 8 s")
        } else {
            h.expect(reported.isEmpty, "K06: I2 reported although clicks got through in time: \(reported)")
        }
        await pause(0.5)
        await h.probeInput()
    },
]

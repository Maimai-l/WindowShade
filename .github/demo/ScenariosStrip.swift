// 卷帘条上的操作（docs/test-catalog.md 第 4 节）。C17 由第 3 层 StripTrafficLightTests 覆盖。

import AppKit
import ApplicationServices

/// 点卷帘条上的按钮（0 关闭、1 最小化、2 缩放），然后把指针移开。
func clickStripButton(_ folded: Folded, _ index: Int, _ harness: Harness) async {
    await click(stripButton(folded, index))
    await glide(to: harness.neutral, duration: 0.2)
}

/// 先单击卷帘条，让它成为当前窗口，再按键。
func pressOnStrip(_ folded: Folded, _ key: CGKeyCode, _ flags: CGEventFlags, _ harness: Harness) async {
    await click(folded.titleBar)
    await pause(0.5)
    await pressKey(key, flags)
    await glide(to: harness.neutral, duration: 0.2)
}

/// 在 ProbeApp 的对话框里按一个按钮。
func answerSheet(_ probe: Probe, _ button: String, _ harness: Harness) async {
    guard await eventually(4, { probe.count("sheet-shown") > 0 }) else {
        harness.result.violations.append("the save sheet did not appear within 4 s")
        return
    }
    await harness.probeFor(1.5)
    if let element = findButton(AXUIElementCreateApplication(probe.pid), button) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    } else {
        harness.result.violations.append("setup: no \(button) button in the sheet")
    }
    await pause(0.8)
}

func forwardedCount(_ harness: Harness, _ action: String) -> Int {
    harness.logLines().filter { $0.contains("traffic: \(action) forwarded") }.count
}

let stripScenarios: [Scenario] = [
    Scenario(id: "C01", title: "拖动卷帘条：不打开看一眼，松开后不展开", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await drag(from: folded.titleBar, to: CGPoint(x: folded.titleBar.x + 180, y: folded.titleBar.y + 120))
        h.expect(!glanceVisible(over: folded.frame.offsetBy(dx: 180, dy: 120)), "C01: the glance opened during or after a drag")
        await glide(to: h.neutral, duration: 0.2)
        await pause(0.8)
        h.expect(stripFrames().count == 1, "C01: the window unfolded after a drag")
    },
    Scenario(id: "C02", title: "把卷帘条拖到屏幕下边外：被拉回够得着的位置", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        let screen = CGDisplayBounds(CGMainDisplayID())
        await drag(from: folded.titleBar, to: CGPoint(x: folded.titleBar.x, y: screen.maxY + 150))
        await glide(to: h.neutral, duration: 0.2)
        await pause(1)
        guard let strip = stripFrames().first else { h.result.violations.append("C02: the strip disappeared"); return }
        h.expect(strip.maxY <= screen.maxY + 1 && strip.minY >= screen.minY, "C02: the strip is out of reach at \(strip)")
    },
    Scenario(id: "C03", title: "统一标题栏样式下拖右边缘加宽卷帘条，展开后窗口跟着变宽", options: [],
             changesSettings: true) { probe, h in
        _ = await relaunchWindowShade([["ShadeAppearanceMode", "-string", "proxyTitleBar"]])
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let folded = await foldProbe(probe, h), let strip = stripFrames().first else { return }
        await drag(from: CGPoint(x: strip.maxX - 2, y: strip.midY), to: CGPoint(x: strip.maxX + 150, y: strip.midY))
        await glide(to: h.neutral, duration: 0.2)
        let widened = stripFrames().first?.width ?? 0
        h.expect(widened > strip.width + 100, "C03: the strip did not widen (\(strip.width) → \(widened))")
        await doubleClick(at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await pause(1.5)
        let width = probe.window().flatMap(axFrame)?.width ?? 0
        h.expect(width > folded.frame.width + 100, "C03: the window did not widen (\(folded.frame.width) → \(width))")
    },
    Scenario(id: "C04", title: "有未保存内容：点关闭，对话框出现一次，选 Delete 后关闭", options: ["--sheet-on-close"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await clickStripButton(folded, 0, h)
        await answerSheet(probe, "Delete", h)
        h.expect(await eventually(3) { probe.count("closed") == 1 }, "C04: the window did not close after Delete")
        h.expectOnce("the sheet appeared", probe.count("sheet-shown"))
        h.expectOnce("close was requested", probe.count("close-request"))
        h.expectOnce("WindowShade forwarded close", forwardedCount(h, "close"))
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C04-cancel", title: "有未保存内容：点关闭后选 Cancel，窗口留下、不再收起", options: ["--sheet-on-close"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await clickStripButton(folded, 0, h)
        await answerSheet(probe, "Cancel", h)
        await pause(1)
        h.expect(probe.count("closed") == 0, "C04: the window closed after Cancel")
        h.expectOnce("close was requested", probe.count("close-request"))
        await expectRestored(probe, folded.frame, h, within: 3)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C05", title: "有未保存内容：点关闭后选 Save，存好后关闭", options: ["--sheet-on-close"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await clickStripButton(folded, 0, h)
        await answerSheet(probe, "Save", h)
        h.expect(await eventually(3) { probe.count("saved") == 1 && probe.count("closed") == 1 },
                 "C05: the document was not saved and closed")
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C06", title: "已保存的文档：点关闭直接关掉", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await clickStripButton(folded, 0, h)
        h.expect(await eventually(3) { probe.count("closed") == 1 }, "C06: the window did not close")
        h.expectOnce("close was requested", probe.count("close-request"))
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C07", title: "点卷帘条上的最小化按钮", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await clickStripButton(folded, 1, h)
        h.expect(await eventually(3) { probe.count("minimized") == 1 }, "C07: the window was minimized \(probe.count("minimized")) times")
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C08", title: "点卷帘条上的绿色按钮：展开并缩放", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await clickStripButton(folded, 2, h)
        await pause(2)
        await expectNoStrip(h, within: 2)
        let size = probe.window().flatMap(axFrame)?.size
        h.expect(size != nil && size != folded.frame.size, "C08: the window was not zoomed (\(size.map { "\($0)" } ?? "none"))")
    },
    Scenario(id: "C10", title: "卷帘条是当前窗口时按 Command-W", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressOnStrip(folded, 13, .maskCommand, h)   // W
        h.expect(await eventually(3) { probe.count("closed") == 1 }, "C10: Command-W did not close the window")
        h.expectOnce("close was requested", probe.count("close-request"))
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C11", title: "卷帘条是当前窗口时按 Command-M", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressOnStrip(folded, 46, .maskCommand, h)   // M
        h.expect(await eventually(3) { probe.count("minimized") == 1 }, "C11: Command-M did not minimize the window")
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "C12", title: "卷帘条是当前窗口时按 Command-H", options: ["--windows=2"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressOnStrip(folded, 4, .maskCommand, h)    // H
        h.expect(await eventually(3) { probe.count("hidden") >= 1 }, "C12: Command-H did not hide the app")
    },
    Scenario(id: "C13", title: "卷帘条是当前窗口时按 Command-N", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressOnStrip(folded, 45, .maskCommand, h)   // N
        h.expect(await eventually(3) { probe.count("new-window") == 1 }, "C13: Command-N made \(probe.count("new-window")) windows")
    },
    Scenario(id: "C14", title: "有未保存内容时在卷帘条上按 Command-Q：窗口先回来，再问一次", options: ["--sheet-on-close"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressOnStrip(folded, 12, .maskCommand, h)   // Q
        await expectRestored(probe, folded.frame, h, within: 4)
        await answerSheet(probe, "Delete", h)
        h.expectOnce("the quit sheet appeared", probe.count("sheet-shown"))
        h.expect(await eventually(4) { !probe.isRunning }, "C14: the app did not quit after Delete")
    },
    Scenario(id: "C15", title: "卷帘条是当前窗口时按其他组合键：不转给原应用程序", options: [],
             changesSettings: true) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        // 只数按键之后新增的。按的是 ⌘F、⌘,，不会隐藏应用程序；hidden 只会来自收起和“看一眼”收回时藏回去，不算。
        let kinds = ["closed", "minimized", "new-window", "quit-request"]
        let before = kinds.map(probe.count).reduce(0, +)
        await pressOnStrip(folded, 3, .maskCommand, h)    // F
        await pressKey(43, .maskCommand)                   // ,
        await pause(1)
        let sideEffects = kinds.map(probe.count).reduce(0, +) - before
        h.expect(sideEffects == 0, "C15: another key combination reached the app")
        // ⌘, 打开的是 WindowShade 自己的设置窗口，场景结束后由下一次重启关掉。
        await pressKey(53)
    },
    Scenario(id: "C16", title: "卷帘条是当前窗口时直接打字：文字不进入任何文档", options: ["--windows=2"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await click(folded.titleBar)
        await pause(0.5)
        await typeText("kx8")
        await glide(to: h.neutral, duration: 0.2)
        await pause(0.5)
        h.expect(probe.text(of: "Probe 1") == nil, "I10: typing on the strip changed the folded document")
        h.expect(!(probe.text(of: "Probe 2")?.contains("kx8") ?? false), "C16: typing on the strip reached another window")
    },
    Scenario(id: "C18", title: "右键点卷帘条：不展开", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await glide(to: folded.titleBar, duration: 0.3)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: folded.titleBar, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        }
        await pause(0.5)
        await pressKey(53)
        await glide(to: h.neutral, duration: 0.2)
        await pause(1)
        h.expect(stripFrames().count == 1, "C18: a right click unfolded the window")
    },
    Scenario(id: "C19", title: "在卷帘条上滚动：不展开，不影响别的窗口", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await glide(to: folded.titleBar, duration: 0.3)
        for _ in 0..<6 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            await pause(0.05)
        }
        await glide(to: h.neutral, duration: 0.2)
        await pause(1)
        h.expect(stripFrames().count == 1, "C19: scrolling unfolded the window")
    },
    Scenario(id: "C20", title: "卷帘条置顶：别的窗口点到前面也盖不住卷帘条", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h), let strip = stripFrames().first,
              let shade = windowShadePID() else { return }
        guard let other = await Probe.launch(Suite.probeApp, name: "C20-other", options: []) else { return }
        defer { other.forceQuit() }
        if let window = other.window() { place(window, origin: CGPoint(x: folded.frame.minX - 40, y: folded.frame.minY - 30), size: probeSize) }
        NSRunningApplication(processIdentifier: other.pid)?.activate()
        await pause(1)
        let stripZ = zOrder(ofOwner: shade, intersecting: strip)
        let otherZ = zOrder(ofOwner: other.pid, intersecting: strip)
        h.expect(stripZ != nil && (otherZ == nil || stripZ! < otherZ!), "C20: another window covers the strip (\(stripZ ?? -1) vs \(otherZ ?? -1))")
    },
    Scenario(id: "C21", title: "关掉置顶：别的窗口可以盖住卷帘条", options: [], changesSettings: true) { probe, h in
        _ = await relaunchWindowShade([["ShadeFloatingOnTop", "-bool", "false"]])
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let folded = await foldProbe(probe, h), let strip = stripFrames().first,
              let shade = windowShadePID() else { return }
        guard let other = await Probe.launch(Suite.probeApp, name: "C21-other", options: []) else { return }
        defer { other.forceQuit() }
        if let window = other.window() { place(window, origin: CGPoint(x: folded.frame.minX - 40, y: folded.frame.minY - 30), size: probeSize) }
        NSRunningApplication(processIdentifier: other.pid)?.activate()
        await pause(1)
        let stripZ = zOrder(ofOwner: shade, intersecting: strip)
        let otherZ = zOrder(ofOwner: other.pid, intersecting: strip)
        h.expect(otherZ != nil && (stripZ == nil || otherZ! < stripZ!), "C21: the strip stayed on top with floating off (\(stripZ ?? -1) vs \(otherZ ?? -1))")
    },
    Scenario(id: "C22", title: "整理卷帘条快捷键：排到一侧，再按一次回原位", options: ["--windows=2", "--size=360,220"]) { probe, h in
        _ = await foldAll(probe, h)
        let before = stripFrames().sorted { $0.minX < $1.minX }
        await pressShortcut(arrangeKey)
        await pause(1.5)
        let arranged = stripFrames().sorted { $0.minX < $1.minX }
        h.expect(arranged != before, "C22: arranging did not move the strips")
        await pressShortcut(arrangeKey)
        await pause(1.5)
        let back = stripFrames().sorted { $0.minX < $1.minX }
        h.expect(zip(back, before).allSatisfy { abs($0.minX - $1.minX) <= 2 && abs($0.minY - $1.minY) <= 2 } && back.count == before.count,
                 "C22: the strips did not return (\(before) → \(back))")
        _ = await pressWindowShadeMenu("全部展开")
    },
    Scenario(id: "C23", title: "卷帘条对读屏可见：标题里有应用程序名或窗口标题", options: []) { probe, h in
        guard await foldProbe(probe, h) != nil, let shade = windowShadePID(), let strip = stripFrames().first else { return }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(shade), kAXWindowsAttribute as CFString, &value)
        let windows = value as? [AXUIElement] ?? []
        let match = windows.first { window in
            guard let frame = axFrame(window) else { return false }
            return abs(frame.minX - strip.minX) <= 3 && abs(frame.minY - strip.minY) <= 3
        }
        guard let match else { h.result.violations.append("C23: the strip is not an accessibility window"); return }
        var texts = [axString(match, kAXTitleAttribute as String), axString(match, kAXDescriptionAttribute as String)]
        texts += axChildren(match).flatMap { [axString($0, kAXTitleAttribute as String), axString($0, kAXDescriptionAttribute as String),
                                              axString($0, kAXValueAttribute as String)] }
        h.expect(texts.contains { $0.contains("Probe") }, "C23: the strip does not name its window (\(texts.filter { !$0.isEmpty }))")
    },
    // 随机操作 Q01（种子 647145595，第 123 至 126 步）缩短而来：同一应用程序的两扇窗口都收起，双击展开后收起的那扇，
    // 再点先收起那扇的卷帘条上的关闭按钮。录像里指针停在关闭按钮上、按钮亮了，WindowShade 的日志里没有任何反应。
    Scenario(id: "C24", title: "展开同一应用程序的另一扇窗口后，点卷帘条上的关闭按钮", options: ["--windows=2"]) { probe, h in
        let windows = probe.allWindows().sorted {
            axString($0, kAXTitleAttribute as String) < axString($1, kAXTitleAttribute as String)
        }
        guard windows.count == 2 else {
            h.result.violations.append("setup: ProbeApp has \(windows.count) windows, expected 2")
            return
        }
        let app = AXUIElementCreateApplication(probe.pid)
        let size = CGSize(width: 340, height: 220)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(windows[0], kAXRaiseAction as CFString)
        guard let first = await fold(windows[0], at: CGPoint(x: 40, y: 80), size: size, h) else { return }
        AXUIElementPerformAction(windows[1], kAXRaiseAction as CFString)
        guard let second = await fold(windows[1], at: CGPoint(x: 440, y: 80), size: size, h) else { return }
        await glide(to: second.titleBar, duration: 0.25)
        await doubleClick(at: second.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        h.expect(await eventually(4) { stripFrames().count == 1 }, "setup: the second window did not unfold")
        await pause(0.5)
        await clickStripButton(first, 0, h)
        h.expect(await eventually(4) { probe.count("closed") == 1 },
                 "C24: the window did not close after its strip's close button was clicked")
        h.expectOnce("close was requested", probe.count("close-request"))
        await expectNoStrip(h, within: 2)
    },
]

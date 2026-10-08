// 展开（docs/test-catalog.md 第 3 节）。B01 由几乎每个场景的展开覆盖，B02 在 A04，B15 在 X01，B16 在 Scenarios.swift。

import AppKit
import ApplicationServices

/// 把一个 ProbeApp 的几扇窗口摆成互不重叠的格子，逐个双击收起；返回各自收起前的位置。
func foldAll(_ probe: Probe, _ harness: Harness, size: CGSize = CGSize(width: 360, height: 220)) async -> [CGRect] {
    var frames: [CGRect] = []
    // 按标题排好：辅助功能给的窗口顺序是前后层次，不是编号；expectAllRestored 按“Probe 序号+1”核对。
    let windows = probe.allWindows().sorted {
        axString($0, kAXTitleAttribute as String).localizedStandardCompare(axString($1, kAXTitleAttribute as String)) == .orderedAscending
    }
    // 每行放得下几扇就放几扇：伸出屏幕太多的窗口，卷帘条会被拉回屏幕，展开位置跟着变（2026-10-08 B17，屏幕宽 1024）。
    let screen = CGDisplayBounds(CGMainDisplayID())
    let columns = max(1, min(4, Int((screen.width - 60) / (size.width + 30))))
    for (index, window) in windows.enumerated() {
        let origin = CGPoint(x: 60 + CGFloat(index % columns) * (size.width + 30),
                             y: 80 + CGFloat(index / columns) * (size.height + 60))
        place(window, origin: origin, size: size)
        await pause(0.3)
        if let frame = axFrame(window) { frames.append(frame) }
    }
    // 从最下面一行收起：卷帘条的“看一眼”卡片挂在它下面，先收上面那扇，卡片会盖住下一行的标题栏，
    // 双击按规则被拒绝（2026-10-08 B05、B17：refused control role=AXImage）。
    for frame in frames.reversed() {
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.2)
        await doubleClick(at: point)
        await pause(1.0)
    }
    await glide(to: harness.neutral, duration: 0.2)
    harness.expect(await eventually(4) { stripFrames().count == frames.count },
                   "setup: expected \(frames.count) strips, saw \(stripFrames().count)")
    return frames
}

/// 每扇窗口都回到原处。
func expectAllRestored(_ probe: Probe, _ frames: [CGRect], _ harness: Harness, within seconds: Double) async {
    for (index, frame) in frames.enumerated() {
        await expectFrame({ probe.window("Probe \(index + 1)") }, frame, harness, within: seconds, "Probe \(index + 1)")
    }
    await expectNoStrip(harness, within: 2)
}

/// 程序坞里某个应用程序的图标（辅助功能）。
func dockItem(_ name: String) -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    return findElement(AXUIElementCreateApplication(dock.processIdentifier)) { axString($0, kAXTitleAttribute as String) == name }
}

/// 在 AX 树里找第一个满足条件的元素。
func findElement(_ root: AXUIElement, depth: Int = 0, maxDepth: Int = 8, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < maxDepth else { return nil }
    for child in axChildren(root) {
        if match(child) { return child }
        if let found = findElement(child, depth: depth + 1, maxDepth: maxDepth, match) { return found }
    }
    return nil
}

/// 某个应用程序菜单栏里的一项（例如 “Window” 菜单里的 “Probe 1”）。
func pressAppMenu(_ pid: pid_t, menu: String, item: String) async -> Bool {
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success,
          let bar else { return false }
    guard let menuItem = axChildren(bar as! AXUIElement).first(where: { axString($0, kAXTitleAttribute as String) == menu }),
          let target = findElement(menuItem, { axString($0, kAXTitleAttribute as String) == item }) else { return false }
    return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
}

let unfoldScenarios: [Scenario] = [
    Scenario(id: "B03", title: "按 Control-Command-1 展开；超出编号的组合不做任何事", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressKey(25, [.maskControl, .maskCommand])   // 9
        await pause(1)
        h.expect(stripFrames().count == 1, "B03: Control-Command-9 changed something with one folded window")
        await pressKey(18, [.maskControl, .maskCommand])   // 1
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "B04", title: "从菜单栏菜单选择收起的窗口展开", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(await pressWindowShadeMenu("Probe 1"), "B04: the folded window is not in the menu")
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "B05", title: "菜单里“全部展开”", options: ["--windows=3", "--size=360,220"]) { probe, h in
        let frames = await foldAll(probe, h)
        h.expect(await pressWindowShadeMenu("全部展开"), "B05: no Unfold All item")
        await expectAllRestored(probe, frames, h, within: 5)
    },
    Scenario(id: "B06", title: "点程序坞里的应用程序图标", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard let item = dockItem("ProbeApp") else { h.result.notes["skipped"] = "no Dock item"; return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 3)
    },
    Scenario(id: "B07", title: "切换到这个应用程序（与 Command-Tab 同效）", options: ["--windows=2"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        await pause(1.5)
        // 切到应用程序时，卷帘条留着还是展开，取决于它的另一扇窗口是否接住了焦点；无论哪种，窗口不能丢。
        if stripFrames().isEmpty {
            await expectRestored(probe, folded.frame, h, within: 3)
        } else {
            await unfold(folded, probe, h)
        }
    },
    Scenario(id: "B09", title: "应用程序“窗口”菜单里选这扇窗口", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(await pressAppMenu(probe.pid, menu: "Window", item: "Probe 1"), "B09: no Probe 1 in the Window menu")
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 3)
    },
    Scenario(id: "B11", title: "拖动卷帘条后展开，窗口出现在新位置（S2）", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        let delta = CGSize(width: 220, height: 160)
        await drag(from: folded.titleBar, to: CGPoint(x: folded.titleBar.x + delta.width, y: folded.titleBar.y + delta.height))
        await glide(to: h.neutral, duration: 0.2)
        h.expect(stripFrames().count == 1, "B11: the strip did not survive the drag")
        let moved = folded.frame.offsetBy(dx: delta.width, dy: delta.height)
        await doubleClick(at: CGPoint(x: folded.titleBar.x + delta.width, y: folded.titleBar.y + delta.height))
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, moved, h, within: 4)
    },
    Scenario(id: "B14", title: "应用程序自己关掉了收起的窗口（R3）", options: []) { probe, h in
        guard await foldProbe(probe, h) != nil else { return }
        probe.send("close")
        await expectNoStrip(h, within: 4)
    },
    Scenario(id: "B17", title: "收起 8 扇窗口后全部展开，5 秒内各回原处", options: ["--windows=8", "--size=300,180"]) { probe, h in
        let frames = await foldAll(probe, h, size: CGSize(width: 300, height: 180))
        let start = Date()
        h.expect(await pressWindowShadeMenu("全部展开"), "B17: no Unfold All item")
        await expectAllRestored(probe, frames, h, within: 5)
        h.result.notes["unfoldAllSeconds"] = Date().timeIntervalSince(start)
    },
]

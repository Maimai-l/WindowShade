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
    // 从最下面一行收起：卷帘条的“看一眼”卡片显示在它下面，先收上面那扇，卡片会盖住下一行的标题栏，
    // 双击按规则被拒绝（2026-10-08 B05、B17：refused control role=AXImage）。
    for frame in frames.reversed() {
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.2)
        await doubleClick(at: point)
        // 收起后指针马上离开卷帘条：停在上面会打开“看一眼”，屏幕下部的卡片向上展开，盖住上面一行待收起窗口的标题栏，
        // 双击落在卡片上被拒绝（02cd137 上 B17：refused control role=AXImage，8 扇只收起 6 扇）。
        await glide(to: harness.neutral, duration: 0.15)
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

/// 在 ProbeApp 的“窗口”菜单里选“Probe 1”。用辅助功能按不了这一项时（用户的 macOS 14.5 本机运行，8e9a4f1：
/// 已隐藏的应用程序的菜单打不开），让 ProbeApp 自己执行这个菜单项的动作，和用户点它一样。
/// ProbeApp 那边做没做成不回报，这时总是返回 true；窗口有没有回来由调用方接着检查。
func chooseProbeInWindowMenu(_ probe: Probe) async -> Bool {
    if await pressAppMenu(probe.pid, menu: "Window", item: "Probe 1") { return true }
    probe.send("window-menu")
    return true
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

/// 各个应用程序（连同 WindowShade 自己的卷帘条）里已经最小化的窗口，记成“应用程序名: 窗口标题”。
/// 每次辅助功能调用最多等 0.3 秒，以免前面场景留下的、没有响应的应用程序让这里一直等下去。
func minimizedWindowNames() -> Set<String> {
    var names: Set<String> = []
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular || app.bundleIdentifier == windowShadeBundleID {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { continue }
        for window in value as? [AXUIElement] ?? [] {
            AXUIElementSetMessagingTimeout(window, 0.3)
            guard axBool(window, kAXMinimizedAttribute as String) else { continue }
            names.insert("\(app.localizedName ?? "pid \(app.processIdentifier)"): \(axString(window, kAXTitleAttribute as String))")
        }
    }
    return names
}

/// 某个应用程序在当前桌面上显示着一扇普通窗口（层级 0），左上角离 frame 的左上角不超过 4 点。
func appWindowOnScreen(_ bundleID: String, at frame: CGRect) -> Bool {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    else { return false }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        return abs(rect.minX - frame.minX) <= 4 && abs(rect.minY - frame.minY) <= 4
    }
}

let unfoldScenarios: [Scenario] = [
    Scenario(id: "B03", title: "按 Control-Command-1 展开；超出编号的组合不做任何事", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await pressKey(25, [.maskControl, .maskCommand])   // 9
        await pause(1)
        h.expect(stripFrames().count == 1, "B03: Control-Command-9 changed something with one folded window (strips \(stripFrames()))")
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
    // 当前桌面上没有别的窗口：收起时焦点无处可交，原窗口停到屏幕角落，应用程序不隐藏。点程序坞图标只激活它，
    // 没有“取消隐藏”可等，卷帘条留着，窗口留在角落（2026-10-09 本机运行：测试跑到了一个空桌面上，B06、B09 失败）。
    Scenario(id: "B06-alone", title: "当前桌面上只有这扇窗口：收起后点程序坞里的应用程序图标", options: []) { probe, h in
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != probe.pid
                && $0.processIdentifier != getpid() && $0.bundleIdentifier != "com.windowshade.prototype"
        }
        others.forEach { $0.hide() }
        await pause(1.5)
        defer { others.forEach { $0.unhide() } }
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(h.logLines().contains { $0.contains("handoff strategy=stay-minimize") },
                 "B06-alone: setup: the focus went to another window, so this is plain B06")
        // 收起时不最小化：最小化会播放窗口缩进程序坞的动画（用户 2026-10-17 的录像）。
        h.expect(probe.count("minimized") == 0, "B06-alone: the window was minimized while folding")
        guard let item = dockItem("ProbeApp") else { h.result.notes["skipped"] = "no Dock item"; return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 3)
    },
    Scenario(id: "B07", title: "切换到这个应用程序（与 Command-Tab 同效）", options: ["--windows=2"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        await pause(1.5)
        // 切到应用程序时，卷帘条留着还是展开，取决于它的另一扇窗口是否得到了焦点；无论哪种，窗口不能丢。
        if stripFrames().isEmpty {
            await expectRestored(probe, folded.frame, h, within: 3)
        } else {
            await unfold(folded, probe, h)
        }
    },
    Scenario(id: "B09", title: "应用程序“窗口”菜单里选这扇窗口", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(await chooseProbeInWindowMenu(probe), "B09: no Probe 1 in the Window menu")
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
    // B09 的时序变体（2026-10-08 3b99ecb 上 B09 这样失败过）：收起后 1 秒内应用程序就显示了，
    // 这时的“已显示”通知按收起过程自己引起的处理、被忽略，卷帘条要等 5 秒一次的定期检查才撤。
    Scenario(id: "B18", title: "收起后 1 秒内在应用程序的“窗口”菜单里选这扇窗口", options: []) { probe, h in
        guard let window = probe.window() else { h.result.violations.append("setup: no Probe window"); return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let titleBar = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: titleBar, duration: 0.3)
        await pause(0.2)
        await doubleClick(at: titleBar)
        guard await eventually(3, { stripFrames().count == 1 }) else {
            h.result.violations.append("setup: the window did not fold")
            return
        }
        await glide(to: h.neutral, duration: 0.2)
        h.expect(await chooseProbeInWindowMenu(probe), "B18: no Probe 1 in the Window menu")
        await expectRestored(probe, frame, h, within: 3)
        await expectNoStrip(h, within: 2)
    },
    // macOS 14、15 上，系统在第二次按下时执行标题栏的双击动作（macOS 26 改在第二次松开时，
    // 见 prototype/App/EventTapCallback.swift 里 swallowNextMouseUp 的说明）。双击卷帘条展开时，第二次按下可能被卷帘条
    // 自己的标题栏当成双击，按系统设置把卷帘条或刚展开的窗口最小化。这个问题是代码审查提出的，还没有证实：
    // 用户的 macOS 14.5 本机日志里，设为“缩放”时 900 次双击都没有出现这种情况，设为“最小化”时还没有数据。
    // CI 的机器是 macOS 26，只能确认那里不出这个问题；要用 make-mac-kit.sh 打出测试包，在 macOS 14、15 上本机运行才测得到。
    Scenario(id: "B19", title: "系统设置里双击标题栏时最小化：双击卷帘条展开，窗口回到原位置，没有最小化", options: [],
             changesSettings: true) { _, h in
        let original = systemDoubleClick()
        setSystemDoubleClick("Minimize")
        defer { setSystemDoubleClick(original) }
        h.result.notes["system"] = ProcessInfo.processInfo.operatingSystemVersionString
        h.result.notes["originalDoubleClick"] = original ?? "absent"
        let now = systemDoubleClick()
        guard now == "Minimize" else {
            h.result.violations.append("B19: setup: AppleActionOnDoubleClick is \(now ?? "absent"), not Minimize"); return
        }
        // 先改成“最小化”，再重新启动 WindowShade，和平时就这样设置的用户一样。
        _ = await relaunchWindowShade()
        let textEdit = "com.apple.TextEdit"
        let textEditWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).isEmpty
        // 用 open 打开临时目录里的文件，不用 AppleScript：AppleScript 控制文本编辑要用户授权（见 S6-carry-fullscreen）。
        let note = FileManager.default.temporaryDirectory.appendingPathComponent("windowshade-b19.txt")
        try? "B19".write(to: note, atomically: true, encoding: .utf8)
        func cleanUp() {
            if let window = appWindow(textEdit, titlePrefix: "windowshade-b19") {
                // 失败时窗口可能在程序坞里：先放回来再关。
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                closeWindow(window)
            }
            if !textEditWasRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).forEach { _ = $0.terminate() }
            }
            try? FileManager.default.removeItem(at: note)
        }
        run("/usr/bin/open", ["-a", "TextEdit", note.path])
        var opened: AXUIElement?
        guard await eventually(8, { opened = appWindow(textEdit, titlePrefix: "windowshade-b19"); return opened != nil }),
              let window = opened else {
            h.result.violations.append("B19: setup: TextEdit did not open the note"); cleanUp(); return
        }
        // 测试窗口（Probe 1）可能盖在文本编辑的标题栏上：和 realAppRoundTrip 一样，用辅助功能把文本编辑和这扇窗口带到最前面。
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).first {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        await pause(0.6)
        guard let folded = await fold(window, at: CGPoint(x: 160, y: 120), size: CGSize(width: 700, height: 460), h) else {
            h.result.violations.append("B19: setup: cannot read the TextEdit window frame"); cleanUp(); return
        }
        // 没有收起时，fold 已经记下违规（setup: the window did not fold），这里只收尾。
        guard !stripFrames().isEmpty else { cleanUp(); return }
        h.result.notes["frame"] = "\(folded.frame)"

        // 双击卷帘条展开，之后 1.5 秒内每 0.1 秒看一次有没有窗口刚被最小化（双击之前就已最小化的不算）。
        let minimizedBefore = minimizedWindowNames()
        await doubleClick(at: folded.titleBar)
        var newlyMinimized: Set<String> = []
        for _ in 0..<15 {
            await pause(0.1)
            newlyMinimized.formUnion(minimizedWindowNames().subtracting(minimizedBefore))
        }
        await glide(to: h.neutral, duration: 0.2)
        h.expect(newlyMinimized.isEmpty,
                 "B19: within 1.5 s of the double-click on the strip these windows were minimized: \(newlyMinimized.sorted())")
        await expectFrame({ appWindow(textEdit, titlePrefix: "windowshade-b19") }, folded.frame, h, within: 4, "the TextEdit window")
        await expectNoStrip(h, within: 2)
        if let restored = appWindow(textEdit, titlePrefix: "windowshade-b19") {
            h.expect(!axBool(restored, kAXMinimizedAttribute as String), "B19: the TextEdit window is minimized after unfolding")
        } else {
            h.result.violations.append("B19: the TextEdit window is gone after unfolding")
        }
        h.expect(appWindowOnScreen(textEdit, at: folded.frame),
                 "B19: the TextEdit window is not on screen at \(folded.frame) after unfolding")
        // 卷帘条把系统的标题栏双击动作转给原窗口时，日志里有“traffic: minimize forwarded”这类记录（FoldTransaction.swift）。
        let forwarded = h.logLines().filter { line in
            ["traffic: minimize", "traffic: zoom", "traffic: fullScreen"].contains { line.contains($0) }
        }
        h.expect(forwarded.isEmpty, "B19: the double-click on the strip was forwarded to the window: \(forwarded)")
        cleanUp()
    },
]

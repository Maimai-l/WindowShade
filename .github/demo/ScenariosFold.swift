// 收起（docs/test-catalog.md 第 2 节）。每条场景结束后由 Harness.finish() 检查 I3、I5、I6、I9。

import AppKit
import ApplicationServices

/// I1：任意一扇窗口回到 frame（误差 2 点）。
func expectFrame(_ window: () -> AXUIElement?, _ frame: CGRect, _ harness: Harness, within seconds: Double,
                 _ label: String = "the window") async {
    var last: CGRect?
    let ok = await eventually(seconds) {
        guard let window = window(), let now = axFrame(window) else { return false }
        last = now
        return abs(now.minX - frame.minX) <= 2 && abs(now.minY - frame.minY) <= 2
            && abs(now.width - frame.width) <= 2 && abs(now.height - frame.height) <= 2
    }
    harness.expect(ok, "I1: \(label) is not back at \(frame) after \(seconds) s (now \(last.map { "\($0)" } ?? "unknown"))")
}

/// 双击卷帘条展开，检查窗口回到原处、卷帘条消失。
func unfold(_ folded: Folded, _ probe: Probe, _ harness: Harness) async {
    await doubleClick(at: folded.titleBar)
    await glide(to: harness.neutral, duration: 0.2)
    await expectRestored(probe, folded.frame, harness, within: 4)
    await expectNoStrip(harness, within: 2)
}

/// 没有新的卷帘条出现（等 seconds 秒）。
func expectNoFold(_ before: Int, _ harness: Harness, _ label: String, within seconds: Double = 2) async {
    await pause(seconds)
    harness.expect(stripFrames().count == before, "\(label): the window folded (\(stripFrames().count) strips)")
}

/// 等一个 App 出现标准窗口；没有就返回 nil。
func standardWindow(of bundleID: String, launch: [String], timeout: Double = 10) async -> AXUIElement? {
    if firstWindow(of: bundleID) == nil { run("/usr/bin/open", launch) }
    var found: AXUIElement?
    _ = await eventually(timeout) {
        found = firstWindow(of: bundleID)
        return found != nil
    }
    return found
}

/// 用真实的应用程序收起、展开一次；没有这个应用程序时记为跳过，不算失败。
func realAppRoundTrip(_ bundleID: String, launch: [String], size: CGSize?, barY: CGFloat = 14,
                      quitAfter: Bool, _ harness: Harness) async {
    // 场景开始前就开着的应用程序不结束：在自己的 Mac 上，A33-Terminal 会把运行测试的终端也关掉（2026-10-09）。
    let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    guard let window = await standardWindow(of: bundleID, launch: launch) else {
        harness.result.notes["skipped"] = "\(bundleID) has no window on this machine"
        // 启动了但没有窗口（多半停在系统的确认框上）：结束它，确认框由下一个场景前的 clearSystemPopups 撤掉。
        if !wasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.forceTerminate() }
        }
        return
    }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        app.activate()
    }
    await pause(0.8)
    // 备忘录第一次打开时在窗口上挂着“新功能”对话框；带对话框的窗口按规则不收起（A13），先把它关掉。
    for _ in 0..<3 {
        guard let sheet = axChildren(window).first(where: { axString($0, kAXRoleAttribute as String) == "AXSheet" }) else { break }
        // 先按“以后”“取消”这类按钮：备忘录的这个对话框是 iCloud 登录提示，默认按钮“系统设置”会打开系统设置的窗口，
        // 正好盖住备忘录的标题栏（2026-10-08 e1adeac 的 A33-Notes）。找不到才按默认按钮。
        var buttons: [AXUIElement] = []
        func collect(_ element: AXUIElement, _ depth: Int) {
            guard depth < 6 else { return }
            for child in axChildren(element) {
                if axString(child, kAXRoleAttribute as String) == "AXButton" { buttons.append(child) }
                collect(child, depth + 1)
            }
        }
        collect(sheet, 0)
        let dismissive = ["Not Now", "Later", "Cancel", "Continue", "以后", "稍后", "取消", "继续", "好"]
        var value: CFTypeRef?
        var defaultButton: AXUIElement?
        if AXUIElementCopyAttributeValue(sheet, kAXDefaultButtonAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            defaultButton = unsafeDowncast(value, to: AXUIElement.self)
        }
        let preferred = dismissive.lazy.compactMap { title in
            buttons.first { axString($0, kAXTitleAttribute as String) == title }
        }.first
        guard let button = preferred ?? defaultButton ?? buttons.first else {
            harness.result.notes["sheet"] = "\(bundleID) shows a sheet without a button"
            break
        }
        harness.result.notes["sheet"] = "dismissed a sheet on \(bundleID): \(axString(button, kAXTitleAttribute as String))"
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        await pause(1)
    }
    if let size { place(window, origin: CGPoint(x: 160, y: 120), size: size) }
    else { place(window, origin: CGPoint(x: 160, y: 120), size: axFrame(window)?.size ?? CGSize(width: 600, height: 400)) }
    await pause(0.6)
    guard let frame = axFrame(window) else { return }
    // 双击点要落在标题栏的空白处：备忘录、Safari 的标题栏上有按钮、地址栏，落在上面按规则不收起（A33-Notes、A33-Safari）。
    let controls: Set<String> = ["AXButton", "AXTextField", "AXSearchField", "AXPopUpButton", "AXMenuButton",
                                 "AXRadioButton", "AXCheckBox", "AXTabGroup", "AXComboBox", "AXSegmentedControl"]
    let candidates = [0.72, 0.6, 0.5, 0.4, 0.82, 0.3].map { CGPoint(x: frame.minX + frame.width * $0, y: frame.minY + barY) }
    let titleBar = candidates.first { point in
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        return !controls.contains(axString(element, kAXRoleAttribute as String))
    } ?? candidates[0]
    harness.result.notes["titleBarPoint"] = "\(Int(titleBar.x)),\(Int(titleBar.y))"
    let before = stripFrames().count
    await glide(to: titleBar, duration: 0.3)
    await pause(0.2)
    await doubleClick(at: titleBar)
    let folded = await eventually(3) { stripFrames().count > before }
    harness.expect(folded, "A33: \(bundleID) did not fold")
    await glide(to: harness.neutral, duration: 0.3)
    await harness.probeFor(1)
    if folded {
        await doubleClick(at: titleBar)
        await glide(to: harness.neutral, duration: 0.2)
        await expectFrame({ firstWindow(of: bundleID) }, frame, harness, within: 4, bundleID)
        await expectNoStrip(harness, within: 2)
    }
    if quitAfter, !wasRunning, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        kill(app.processIdentifier, SIGTERM)
    }
}

/// 三击：三次按下，点击次数 1、2、3。
func tripleClick(at point: CGPoint) async {
    for clicks: Int64 in 1...3 {
        post(.leftMouseDown, at: point, clicks: clicks)
        post(.leftMouseUp, at: point, clicks: clicks)
        await pause(0.08)
    }
}

func setSystemDoubleClick(_ value: String?) {
    if let value { run("/usr/bin/defaults", ["write", "-g", "AppleActionOnDoubleClick", value]) }
    else { run("/usr/bin/defaults", ["delete", "-g", "AppleActionOnDoubleClick"]) }
}

let foldScenarios: [Scenario] = [
    Scenario(id: "A01", title: "文本编辑：双击标题栏收起、展开", options: []) { _, h in
        await realAppRoundTrip("com.apple.TextEdit", launch: ["-a", "TextEdit"], size: CGSize(width: 700, height: 460),
                               quitAfter: false, h)
    },
    Scenario(id: "A02", title: "访达：双击工具栏空白处收起、展开", options: []) { _, h in
        await realAppRoundTrip("com.apple.finder", launch: ["/Applications"], size: CGSize(width: 900, height: 500),
                               barY: 8, quitAfter: false, h)
    },
    Scenario(id: "A03", title: "访达：双击工具栏上的按钮不收起", options: []) { _, h in
        guard let window = await standardWindow(of: "com.apple.finder", launch: ["/Applications"]) else {
            h.result.notes["skipped"] = "no Finder window"; return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        place(window, origin: CGPoint(x: 160, y: 120), size: CGSize(width: 900, height: 500))
        // 激活访达不一定把这扇窗口带到最上面：A01 留下的文本编辑窗口在同一位置，双击落到了它上面（2026-10-09 本机运行）
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        await pause(0.8)
        func toolbarButton(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 5 else { return nil }
            for child in axChildren(element) {
                let role = axString(child, kAXRoleAttribute as String)
                if role == "AXToolbar" {
                    return axChildren(child).first { axString($0, kAXRoleAttribute as String).contains("Button") }
                        ?? axChildren(child).flatMap(axChildren).first { axString($0, kAXRoleAttribute as String).contains("Button") }
                }
                if let found = toolbarButton(child, depth + 1) { return found }
            }
            return nil
        }
        guard let button = toolbarButton(window, 0), let frame = axFrame(button) else {
            h.result.notes["skipped"] = "no toolbar button found"; return
        }
        let before = stripFrames().count
        await glide(to: CGPoint(x: frame.midX, y: frame.midY), duration: 0.3)
        await doubleClick(at: CGPoint(x: frame.midX, y: frame.midY))
        await glide(to: h.neutral, duration: 0.2)
        await expectNoFold(before, h, "A03")
    },
    Scenario(id: "A04", title: "快捷键收起；卷帘条是当前窗口时再按一次展开（B02）", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        await pressShortcut(toggleKey)
        let folded = await eventually(3) { stripFrames().count == 1 }
        h.expect(folded, "A04: the shortcut did not fold the window")
        guard folded, let strip = stripFrames().first else { return }
        await click(CGPoint(x: strip.midX, y: strip.midY))
        await pause(0.4)
        await pressShortcut(toggleKey)
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, frame, h, within: 4)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "A05", title: "从菜单栏菜单收起当前窗口", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        h.expect(await pressWindowShadeMenu("收起"), "A05: no fold item in the menu")
        h.expect(await eventually(3) { stripFrames().count == 1 }, "A05: the menu did not fold the window")
        await doubleClick(at: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14))
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, frame, h, within: 4)
    },
    Scenario(id: "A06", title: "关掉“双击标题栏收起窗口”后双击：不收起，系统照常缩放", options: [],
             changesSettings: true) { probe, h in
        setSystemDoubleClick("Maximize")
        defer { setSystemDoubleClick(nil) }
        _ = await relaunchWindowShade([["ShadeTitlebarDoubleClickEnabled", "-bool", "false"]])
        guard let window = probe.window() else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        await glide(to: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14), duration: 0.3)
        await doubleClick(at: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14))
        await glide(to: h.neutral, duration: 0.2)
        await expectNoFold(0, h, "A06")
        h.expect(axFrame(window).map { $0.size != frame.size } ?? false, "A06: the system did not zoom the window")
    },
    Scenario(id: "A07", title: "系统设为双击缩放：三击标题栏缩放，不收起", options: []) { probe, h in
        setSystemDoubleClick("Maximize")
        defer { setSystemDoubleClick(nil) }
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await tripleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        await pause(2.5)
        h.expect(stripFrames().isEmpty, "A07: a triple click left the window folded")
        h.expect(axFrame(window).map { $0.size != frame.size } ?? false, "A07: the window was not zoomed")
    },
    Scenario(id: "A08", title: "系统设为双击最小化：三击标题栏最小化，不收起", options: []) { probe, h in
        setSystemDoubleClick("Minimize")
        defer { setSystemDoubleClick(nil) }
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await tripleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        await pause(2.5)
        h.expect(stripFrames().isEmpty, "A08: a triple click left the window folded")
        h.expect(probe.count("minimized") == 1, "A08: the window was minimized \(probe.count("minimized")) times")
    },
    Scenario(id: "A09", title: "系统设为双击不做任何事：双击照样收起", options: []) { probe, h in
        setSystemDoubleClick("None")
        defer { setSystemDoubleClick(nil) }
        guard let folded = await foldProbe(probe, h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "A10", title: "窗口上挂着对话框时双击标题栏：不收起", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        probe.send("sheet")
        await pause(0.8)
        guard let frame = axFrame(window) else { return }
        await glide(to: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14), duration: 0.3)
        await doubleClick(at: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14))
        await glide(to: h.neutral, duration: 0.2)
        await expectNoFold(0, h, "A10")
        h.expect(axChildren(window).contains { axString($0, kAXRoleAttribute as String) == "AXSheet" },
                 "A10: the sheet is gone")
    },
    Scenario(id: "A11", title: "应用程序弹出独立提示框时双击原窗口标题栏：不收起", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        probe.send("alert")
        await pause(0.8)
        guard let frame = axFrame(window) else { return }
        await glide(to: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14), duration: 0.3)
        await doubleClick(at: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14))
        await glide(to: h.neutral, duration: 0.2)
        await expectNoFold(0, h, "A11")
        h.expect(probe.count("alert-answered") == 0, "A11: the alert was dismissed")
        if let ok = findButton(AXUIElementCreateApplication(probe.pid), "OK") {
            AXUIElementPerformAction(ok, kAXPressAction as CFString)
        }
    },
    Scenario(id: "A12", title: "全屏窗口按快捷键：不收起", options: []) { probe, h in
        probe.send("fullscreen")
        _ = await eventually(5) { probe.count("fullscreen") > 0 }
        await pause(1.5)
        await pressShortcut(toggleKey)
        await expectNoFold(0, h, "A12")
        probe.send("fullscreen")
        await pause(2)
    },
    Scenario(id: "A13", title: "已最小化的窗口按快捷键：不收起，仍在程序坞里", options: []) { probe, h in
        guard let window = probe.window() else { h.result.violations.append("setup: no Probe window"); return }
        probe.send("minimize")
        guard await eventually(4, { probe.count("minimized") > 0 }) else {
            h.result.violations.append("setup: the window did not minimize"); return
        }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        await pause(1)
        await pressShortcut(toggleKey)
        await expectNoFold(0, h, "A13")
        h.expect(axBool(window, kAXMinimizedAttribute as String), "A13: the minimized window left the Dock")
    },
    Scenario(id: "A14", title: "唯一窗口收起后焦点交给别的应用程序，不切换桌面", options: []) { probe, h in
        guard await foldProbe(probe, h) != nil else { return }
        let front = frontmostPID()
        h.expect(front != nil && front != probe.pid, "A14: ProbeApp is still frontmost after folding its only window")
        h.expect(front.flatMap { NSRunningApplication(processIdentifier: $0)?.activationPolicy } == .regular,
                 "A14: focus went to a non-regular app")
    },
    Scenario(id: "A15", title: "多扇窗口中收起一扇：焦点交给同一应用程序的另一扇", options: ["--windows=2"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(await eventually(2) { probe.keyWindow == "Probe 2" }, "A15: Probe 2 did not become the key window")
        h.expect(NSRunningApplication(processIdentifier: probe.pid)?.isHidden == false, "A15: the app was hidden")
        await unfold(folded, probe, h)
    },
    Scenario(id: "A17-small", title: "很小的窗口收起、展开", options: ["--size=220,140"]) { probe, h in
        guard let window = probe.window(), let folded = await fold(window, at: probeOrigin, size: CGSize(width: 220, height: 140), h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "A17-large", title: "很大的窗口收起、展开", options: []) { probe, h in
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard let window = probe.window(),
              let folded = await fold(window, at: CGPoint(x: 0, y: 40), size: CGSize(width: screen.width, height: screen.height - 120), h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "A18-left", title: "左边伸出屏幕的窗口收起、展开", options: []) { probe, h in
        guard let window = probe.window(), let folded = await fold(window, at: CGPoint(x: -300, y: 200), size: probeSize, h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "A18-right", title: "右边伸出屏幕的窗口收起、展开", options: []) { probe, h in
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard let window = probe.window(),
              let folded = await fold(window, at: CGPoint(x: screen.maxX - 300, y: 200), size: probeSize, h) else { return }
        // 双击点按窗口算会落到屏幕外：改点卷帘条露在屏幕里的部分。
        let visible = Folded(window: folded.window, frame: folded.frame,
                             titleBar: CGPoint(x: screen.maxX - 150, y: folded.titleBar.y), close: folded.close)
        await unfold(visible, probe, h)
    },
    Scenario(id: "A18-bottom", title: "下边伸出屏幕的窗口收起、展开", options: []) { probe, h in
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard let window = probe.window(),
              let folded = await fold(window, at: CGPoint(x: 200, y: screen.maxY - 200), size: probeSize, h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "A23", title: "收起过程中再按一次快捷键", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        await probe.bringToFront()
        // 两次按下之间不停顿：第二次一定落在第一次收起的过程中（收起本身约 70 毫秒）。
        // 停顿 0.15 秒再按时，第一次已经收完、焦点已经交给别的应用程序，第二次收起的是那个应用程序的窗口，
        // 那是快捷键本来的意思，不是这里要测的情形（2026-10-08 CI：第二次收起了访达）。
        for _ in 0..<2 {
            post(.keyDown, key: toggleKey, flags: controlOptionCommand.flags)
            post(.keyUp, key: toggleKey, flags: controlOptionCommand.flags)
        }
        await pause(3)
        let strips = stripFrames().count
        h.expect(strips <= 1, "A23: \(strips) strips")
        if strips == 1 { await doubleClick(at: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)) }
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, frame, h, within: 4)
    },
    Scenario(id: "A24", title: "两扇窗口相继收起", options: ["--windows=2"]) { probe, h in
        let windows = probe.allWindows()
        guard windows.count >= 2 else { h.result.violations.append("setup: two windows expected"); return }
        place(windows[0], origin: CGPoint(x: 120, y: 120), size: CGSize(width: 520, height: 300))
        place(windows[1], origin: CGPoint(x: 700, y: 480), size: CGSize(width: 520, height: 300))
        await pause(0.8)
        guard let a = axFrame(windows[0]), let b = axFrame(windows[1]) else { return }
        // 第二扇窗口伸出屏幕右边：双击点取标题栏在屏幕内的那一段（伸出去的部分点不到）。
        let screenRight = CGDisplayBounds(CGMainDisplayID()).maxX
        func titlePoint(_ frame: CGRect) -> CGPoint {
            CGPoint(x: min(frame.minX + frame.width * 0.72, screenRight - 60), y: frame.minY + 14)
        }
        for frame in [a, b] {
            let point = titlePoint(frame)
            await glide(to: point, duration: 0.2)
            await doubleClick(at: point)
            await pause(0.15)
        }
        await glide(to: h.neutral, duration: 0.2)
        h.expect(await eventually(4) { stripFrames().count == 2 }, "A24: expected 2 strips, saw \(stripFrames().count)")
        for frame in [a, b] {
            await doubleClick(at: titlePoint(frame))
            await pause(0.8)
        }
        await glide(to: h.neutral, duration: 0.2)
        await expectFrame({ probe.window("Probe 1") }, a, h, within: 4, "Probe 1")
        await expectFrame({ probe.window("Probe 2") }, b, h, within: 4, "Probe 2")
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "A25", title: "展开后立刻再收起同一扇窗口", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await doubleClick(at: folded.titleBar)
        await pause(0.15)
        await doubleClick(at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await pause(3)
        let strips = stripFrames().count
        h.expect(strips <= 1, "A25: \(strips) strips")
        if strips == 1 { await doubleClick(at: folded.titleBar) }
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, folded.frame, h, within: 4)
    },
    Scenario(id: "A28-proxy", title: "简化标题栏样式收起、展开", options: [], changesSettings: true) { probe, h in
        _ = await relaunchWindowShade([["ShadeAppearanceMode", "-string", "proxyTitleBar"]])
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let folded = await foldProbe(probe, h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "A28-thumbnail", title: "缩略图样式收起、展开", options: [], changesSettings: true) { probe, h in
        _ = await relaunchWindowShade([["ShadeAppearanceMode", "-string", "thumbnail"]])
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window), let pid = windowShadePID() else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await doubleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        func windowShadeWindows() -> [CGRect] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { info -> CGRect? in
                    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                          let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
                    return CGRect(dictionaryRepresentation: bounds)
                }
        }
        // 缩略图比窗口小得多；收起动画的面板比窗口大，动画结束后应当移除。取与窗口相交的最小那一扇。
        var thumbnail: CGRect?
        _ = await eventually(3) {
            thumbnail = windowShadeWindows()
                .filter { $0.width > 60 && $0.height > 40 && $0.width < frame.width && $0.intersects(frame) }
                .min { $0.width * $0.height < $1.width * $1.height }
            return thumbnail != nil
        }
        guard let thumbnail else { h.result.violations.append("A28: no thumbnail appeared"); return }
        let cleared = await eventually(2) { !windowShadeWindows().contains { $0.width > frame.width && $0.height > frame.height } }
        h.expect(cleared, "A28: the fold animation panel is still on screen (\(windowShadeWindows()))")
        await glide(to: CGPoint(x: thumbnail.midX, y: thumbnail.midY), duration: 0.3)
        await doubleClick(at: CGPoint(x: thumbnail.midX, y: thumbnail.midY))
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, frame, h, within: 4)
    },
    Scenario(id: "A29", title: "收起后打字：文字进入接收焦点的窗口，不进入被收起的窗口", options: ["--windows=2"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        _ = await eventually(2) { probe.keyWindow == "Probe 2" }
        await typeText("zq7")
        await pause(0.5)
        h.expect(probe.text(of: "Probe 1") == nil, "I10: text reached the folded window (\(probe.text(of: "Probe 1") ?? ""))")
        h.expect(probe.text(of: "Probe 2")?.contains("zq7") == true, "A29: the typed text did not reach Probe 2")
        await unfold(folded, probe, h)
        h.expect(probe.text(of: "Probe 1") == nil, "I10: the folded window's text changed")
    },
    Scenario(id: "A31", title: "便笺：按快捷键不收起", options: []) { _, h in
        run("/usr/bin/open", ["-a", "Stickies"])
        guard await eventually(8, { firstWindow(of: "com.apple.Stickies") != nil }) else {
            h.result.notes["skipped"] = "Stickies has no window"; return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Stickies").first?.activate()
        await pause(0.8)
        await pressShortcut(toggleKey)
        await expectNoFold(0, h, "A31")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Stickies").first {
            kill(app.processIdentifier, SIGTERM)
        }
    },
    Scenario(id: "A34", title: "应用程序无响应时双击它的标题栏", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        probe.send("freeze:3")
        await pause(0.2)
        await doubleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        await h.probeFor(3)
        await pause(2)
        let strips = stripFrames().count
        h.expect(strips <= 1, "A34: \(strips) strips")
        if strips == 1 {
            await doubleClick(at: point)
            await glide(to: h.neutral, duration: 0.2)
            await expectRestored(probe, frame, h, within: 5)
        } else {
            // WindowShade 放弃了这次双击，双击照常交给应用程序：系统设的双击动作（缩放）作用在窗口上，这是用户本来会得到的结果。
            // 只要求窗口还在、看得见，没有被 WindowShade 藏起来。
            let visible = await eventually(5) {
                probe.window() != nil && NSRunningApplication(processIdentifier: probe.pid)?.isHidden == false
            }
            h.expect(visible, "A34: the window is gone or the app is hidden after the freeze")
        }
    },
    Scenario(id: "A35", title: "收起的过程中应用程序退出", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await doubleClick(at: point)
        // 等收起开始了再让它退出：双击后马上退出，WindowShade 处理双击时探测窗口已经关了，
        // 点到的是后面的访达窗口（2026-10-09 本机运行，退出比收起早 40 毫秒）。
        let started = Date()
        while Date().timeIntervalSince(started) < 2,
              !h.logLines().contains(where: { $0.contains(">>> shade") && $0.contains("app=ProbeApp") }) {
            await pause(0.01)
        }
        probe.send("quit")
        await glide(to: h.neutral, duration: 0.2)
        await expectNoStrip(h, within: 4)
        await h.probeFor(1)
    },
    // 隐藏整个应用程序来收起时，卷帘条要等确认藏好（约 160 毫秒）才显示，之前是透明的、不接点击。
    // 这时在原处再双击一次，双击会穿过去落到后面的窗口上，把它收起（2026-10-08 A05 的诊断里收起了访达）。
    Scenario(id: "A36", title: "收起后马上在原处再双击：不作用到后面的窗口", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await probe.bringToFront()
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await doubleClick(at: point)
        await pause(0.12)
        await doubleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        await pause(2)
        let others = h.logLines().filter { $0.contains(">>> shade") && !$0.contains("app=ProbeApp") }
        h.expect(others.isEmpty, "A36: the second double click folded a window behind (\(others.first ?? ""))")
        if !stripFrames().isEmpty {
            await doubleClick(at: point)
            await glide(to: h.neutral, duration: 0.2)
        }
        await expectRestored(probe, frame, h, within: 4)
        await expectNoStrip(h, within: 2)
    },
    // Q01 种子 1771577254 第 28 步缩短而来：收起最后一扇可见窗口时隐藏了整个应用程序，焦点交给了已收起、停在角落的窗口；
    // 展开另一扇时应用程序重新显示，这两扇都跟着展开了。
    Scenario(id: "A37", title: "同一应用程序的三扇窗口都收起后展开一扇：另外两扇仍收起",
             options: ["--windows=3", "--size=340,220"]) { probe, h in
        let windows = probe.allWindows().sorted {
            axString($0, kAXTitleAttribute as String) < axString($1, kAXTitleAttribute as String)
        }
        guard windows.count == 3 else {
            h.result.violations.append("setup: ProbeApp has \(windows.count) windows, expected 3")
            return
        }
        let origins = [CGPoint(x: 40, y: 80), CGPoint(x: 440, y: 80), CGPoint(x: 40, y: 380)]
        let app = AXUIElementCreateApplication(probe.pid)
        var folded: [Folded] = []
        for (index, window) in windows.enumerated() {
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            guard let one = await fold(window, at: origins[index], size: CGSize(width: 340, height: 220), h) else { return }
            folded.append(one)
        }
        h.expect(stripFrames().count == 3, "setup: \(stripFrames().count) strips after folding 3 windows")
        h.result.notes["hides"] = h.logLines().filter { $0.contains("fallback →") || $0.contains("corner →") || $0.contains("handoff") }
        await glide(to: folded[1].titleBar, duration: 0.3)
        await doubleClick(at: folded[1].titleBar)
        await glide(to: h.neutral, duration: 0.2)
        let back = await eventually(4) { axFrame(folded[1].window).map { abs($0.minX - folded[1].frame.minX) <= 2 && abs($0.minY - folded[1].frame.minY) <= 2 } ?? false }
        h.expect(back, "I1: the unfolded window is not back at \(folded[1].frame)")
        // 展开的那一扇的卷帘条要等窗口到了最前面才撤（最多约 0.6 秒），先等它撤掉；之后另外两扇在 3 秒里一直收着。
        h.expect(await eventually(2) { stripFrames().count == 2 },
                 "A37: \(stripFrames().count) strips 2 s after unfolding one window, expected 2")
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if stripFrames().count != 2 {
                h.result.violations.append("A37: unfolding one window left \(stripFrames().count) strips, expected 2")
                break
            }
            await pause(0.2)
        }
        for index in [0, 2] where !stripFrames().isEmpty {
            await doubleClick(at: folded[index].titleBar)
            await glide(to: h.neutral, duration: 0.2)
            await pause(1)
        }
        await expectNoStrip(h, within: 3)
    },
] + [
    ("A33-Calculator", "com.apple.calculator", ["-a", "Calculator"], nil as CGSize?),
    ("A33-Terminal", "com.apple.Terminal", ["-a", "Terminal"], CGSize(width: 700, height: 420)),
    ("A33-SystemSettings", "com.apple.systempreferences", ["-a", "System Settings"], nil),
    ("A33-Safari", "com.apple.Safari", ["-a", "Safari"], CGSize(width: 900, height: 600)),
    ("A33-Notes", "com.apple.Notes", ["-a", "Notes"], CGSize(width: 900, height: 600)),
    ("A33-Chrome", "com.google.Chrome", ["-a", "Google Chrome", "--args", "--no-first-run"], CGSize(width: 900, height: 600)),
].map { entry -> Scenario in
    let (id, bundleID, launch, size) = entry
    return Scenario(id: id, title: "\(bundleID)：收起、展开", options: []) { probe, h in
        await realAppRoundTrip(bundleID, launch: launch, size: size, barY: bundleID == "com.apple.Safari" ? 10 : 14,
                               quitAfter: true, h)
        // 应用程序的窗口开在别的桌面上时，系统跟着切过去，结束它之后仍停在那个（空）桌面上，后面的场景都在那里跑
        // （2026-10-09 本机运行：系统设置开在 5 号桌面，B03、B06、B09、B11 的窗口没有别处可交焦点，停到了角落）。
        // 测试窗口开在原来的桌面上：把它带到前面，系统切回去。
        if probe.isRunning { await probe.bringToFront() }
    }
}

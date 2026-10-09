// 系统事件、WindowShade 的生命周期、被收起的应用程序、故障注入、设置窗口、权限
// （docs/test-catalog.md 第 6 至 10 节）。权限场景（group 不是 main）只在 record.sh 收回权限后单独运行。

import AppKit
import ApplicationServices

/// 浅色、深色切换：与 dark-mode 命令行工具相同的系统调用（只在测试驱动程序里用）。
func setDarkMode(_ dark: Bool) -> Bool {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let symbol = dlsym(handle, "SLSSetAppearanceThemeLegacy") else { return false }
    typealias Setter = @convention(c) (Bool) -> Void
    unsafeBitCast(symbol, to: Setter.self)(dark)
    return true
}

func windowShadeInstances() -> Int {
    NSRunningApplication.runningApplications(withBundleIdentifier: windowShadeBundleID).count
}

func readDefault(_ key: String) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["read", windowShadeBundleID, key]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// WindowShade 的某扇窗口（按标题）。
func windowShadeWindow(_ title: String) -> AXUIElement? {
    guard let pid = windowShadePID() else { return nil }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement] ?? []).first { axString($0, kAXTitleAttribute as String).contains(title) }
}

/// 某个元素里标题或说明含 name 的控件。SwiftUI 表单的层次很深（窗口、标签页、托管视图、滚动区域、分组……），
/// 搜到 30 层。
func control(_ root: AXUIElement, _ name: String, role: String? = nil) -> AXUIElement? {
    findElement(root, maxDepth: 30) { element in
        let texts = [kAXTitleAttribute, kAXDescriptionAttribute].map { axString(element, $0 as String) }
        return texts.contains { $0.contains(name) } && (role == nil || axString(element, kAXRoleAttribute as String) == role)
    }
}

/// 设置窗口里的开关。SwiftUI 表单里的开关自己没有标题，名字是同一行里另一段文字的 AXValue：
/// 先按标题找，找不到就找写着 name 的文字，取和它在同一行（中线相差不到 20 点）的开关。
func toggle(_ root: AXUIElement, _ name: String) -> AXUIElement? {
    if let titled = control(root, name, role: "AXCheckBox") { return titled }
    var labels: [CGRect] = []
    var boxes: [(AXUIElement, CGRect)] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard depth < 30 else { return }
        for child in axChildren(element) {
            let role = axString(child, kAXRoleAttribute as String)
            if role == "AXStaticText", axString(child, kAXValueAttribute as String) == name, let frame = axFrame(child) {
                labels.append(frame)
            } else if role == "AXCheckBox", let frame = axFrame(child) {
                boxes.append((child, frame))
            }
            walk(child, depth + 1)
        }
    }
    walk(root, 0)
    guard let label = labels.first else { return nil }
    return boxes.filter { abs($0.1.midY - label.midY) < 20 }.min { abs($0.1.midY - label.midY) < abs($1.1.midY - label.midY) }?.0
}

func isEnabled(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
    return (value as? Bool) ?? true
}

/// 让 record.sh 在测试中途授予一项权限：写一个请求文件，等它回一个完成文件。
func requestGrant(_ name: String, timeout: Double = 40) async -> Bool {
    let request = "/tmp/windowshade-e2e-grant-\(name)"
    let done = request + ".done"
    FileManager.default.createFile(atPath: request, contents: nil)
    return await eventually(timeout) { FileManager.default.fileExists(atPath: done) }
}

/// 收起时隐藏了整个应用程序，应用程序在隐藏状态下移动自己的窗口：窗口仍然看不见，卷帘条应当留着，
/// 双击卷帘条展开后窗口在屏幕上。返回 true 表示按这种情况检查完了。
func stillHiddenAfterMove(_ probe: Probe, _ folded: Folded, _ h: Harness) async -> Bool {
    await pause(1.5)
    guard NSRunningApplication(processIdentifier: probe.pid)?.isHidden == true else { return false }
    h.result.notes["hidden"] = "the app was hidden by the fold, so moving its window kept it out of sight"
    h.expect(stripFrames().count == 1, "the strip disappeared while the window was still hidden")
    await doubleClick(at: folded.titleBar)
    await glide(to: h.neutral, duration: 0.2)
    let screen = CGDisplayBounds(CGMainDisplayID())
    let back = await eventually(4) {
        NSRunningApplication(processIdentifier: probe.pid)?.isHidden == false
            && (probe.window().flatMap(axFrame).map { screen.intersects($0) } ?? false)
    }
    h.expect(back, "the window is not on screen after unfolding (\(probe.window().flatMap(axFrame).map { "\($0)" } ?? "none"))")
    return true
}

let systemScenarios: [Scenario] = [
    // MARK: 系统事件（第 7 节）
    Scenario(id: "E05", title: "收起后切换深色、浅色外观", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard setDarkMode(true) else { h.result.notes["skipped"] = "cannot switch appearance"; return }
        await pause(2)
        h.expect(stripFrames().count == 1, "E05: the strip disappeared after switching to dark")
        _ = setDarkMode(false)
        await pause(2)
        h.expect(stripFrames().count == 1, "E05: the strip disappeared after switching to light")
        await unfold(folded, probe, h)
    },
    Scenario(id: "E06", title: "台前调度打开时收起、展开", options: []) { probe, h in
        writeDefaults([["GloballyEnabled", "-bool", "true"]], domain: "com.apple.WindowManager")
        defer { writeDefaults([["GloballyEnabled", "-bool", "false"]], domain: "com.apple.WindowManager") }
        await pause(2)
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let folded = await foldProbe(probe, h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "E07", title: "程序坞放在左边时收起、展开", options: []) { probe, h in
        writeDefaults([["orientation", "-string", "left"]], domain: "com.apple.dock")
        run("/usr/bin/killall", ["Dock"])
        await pause(3)
        defer {
            writeDefaults([["orientation", "-string", "bottom"]], domain: "com.apple.dock")
            run("/usr/bin/killall", ["Dock"])
        }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let window = probe.window(),
              let folded = await fold(window, at: CGPoint(x: 0, y: 120), size: probeSize, h) else { return }
        let visible = Folded(window: folded.window, frame: folded.frame,
                             titleBar: CGPoint(x: folded.frame.minX + folded.frame.width * 0.72, y: folded.titleBar.y), close: folded.close)
        await unfold(visible, probe, h)
        await pause(1)
    },

    // MARK: WindowShade 的生命周期（第 8 节）
    Scenario(id: "L01", title: "有窗口收起着时从菜单退出 WindowShade：全部回到原处", options: ["--windows=2", "--size=360,220"],
             changesSettings: true) { probe, h in
        let frames = await foldAll(probe, h)
        h.expect(await pressWindowShadeMenu("退出"), "L01: no Quit item")
        h.expect(await eventually(5) { windowShadePID() == nil }, "L01: WindowShade did not quit")
        await expectAllRestored(probe, frames, h, within: 4)
        _ = await relaunchWindowShade()
    },
    Scenario(id: "L02", title: "kill -9 结束 WindowShade 后重新启动：窗口回到原处（R1）", options: [],
             changesSettings: true) { probe, h in
        guard let folded = await foldProbe(probe, h), let pid = windowShadePID() else { return }
        kill(pid, SIGKILL)
        await pause(1)
        run("/usr/bin/open", [Suite.shadeApp])
        _ = await eventually(8) { windowShadePID() != nil }
        if let pid = windowShadePID() { Suite.audit?.watch(pid) }
        await expectRestored(probe, folded.frame, h, within: 8)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "L03", title: "收起进行中 kill -9，重新启动后窗口回到原处", options: [],
             changesSettings: true) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await pause(0.6)
        guard let frame = axFrame(window), let pid = windowShadePID() else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await doubleClick(at: point)
        await pause(0.12)
        kill(pid, SIGKILL)
        await pause(1)
        run("/usr/bin/open", [Suite.shadeApp])
        _ = await eventually(8) { windowShadePID() != nil }
        if let pid = windowShadePID() { Suite.audit?.watch(pid) }
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, frame, h, within: 8)
    },
    Scenario(id: "L07", title: "再启动一个 WindowShade：只留一个", options: []) { _, h in
        run("/usr/bin/open", ["-n", Suite.shadeApp])
        await pause(5)
        h.expect(windowShadeInstances() == 1, "L07: \(windowShadeInstances()) WindowShade processes are running")
    },

    // MARK: 被收起的应用程序（第 9 节）
    Scenario(id: "P03", title: "收起后应用程序新开一扇窗口：不多出卷帘条", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        probe.send("new-window")
        await pause(2)
        let strips = stripFrames().count
        h.expect(strips <= 1, "P03: \(strips) strips after the app opened a window")
        h.expect(probe.window("Probe 2") != nil, "P03: the new window is missing")
        // 收起时隐藏了整个应用程序：它为新窗口取消隐藏，被收起的窗口跟着露出来，WindowShade 把它展开放回原处。
        if strips == 0 { await expectFrame({ probe.window("Probe 1") }, folded.frame, h, within: 3, "Probe 1") }
    },
    Scenario(id: "P04", title: "收起后应用程序自己把窗口移走：卷帘条移除，窗口不丢", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        probe.send("move:400,300")
        if await stillHiddenAfterMove(probe, folded, h) { return }
        await expectNoStrip(h, within: 4)
        let frame = probe.window().flatMap(axFrame)
        let screen = CGDisplayBounds(CGMainDisplayID())
        h.expect(frame.map { screen.intersects($0) } ?? false, "P04: the window is not on screen (\(frame.map { "\($0)" } ?? "none"))")
    },
    Scenario(id: "P05", title: "收起后应用程序弹出提示框：提示框看得见", options: []) { probe, h in
        guard await foldProbe(probe, h) != nil else { return }
        probe.send("alert")
        let screen = CGDisplayBounds(CGMainDisplayID())
        let visible = await eventually(3) {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).contains { info in
                guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == probe.pid,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                return rect.height > 80 && screen.intersection(rect).width > rect.width * 0.9
            }
        }
        h.expect(visible, "P05: the alert is not visible on screen")
        if let ok = findButton(AXUIElementCreateApplication(probe.pid), "OK") {
            AXUIElementPerformAction(ok, kAXPressAction as CFString)
        }
    },
    Scenario(id: "P06", title: "收起后应用程序让这扇窗口进入全屏：卷帘条移除", options: ["--windows=2"]) { probe, h in
        guard await foldProbe(probe, h) != nil else { return }
        probe.send("fullscreen")
        await expectNoStrip(h, within: 5)
        probe.send("fullscreen")
        await pause(2)
    },
    Scenario(id: "P07", title: "一个应用程序卡住时，另一个应用程序的卷帘条照常展开", options: []) { probe, h in
        guard let other = await Probe.launch(Suite.probeApp, name: "P07-other", options: []) else { return }
        defer { other.forceQuit() }
        guard let window = probe.window(), let otherWindow = other.window() else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        // 两扇都放在屏幕（CI 是 1024×768）里面：伸出去太多，卷帘条会被拉回屏幕，两条叠在一起。
        guard let a = await fold(window, at: CGPoint(x: 60, y: 120), size: CGSize(width: 440, height: 280), h) else { return }
        NSRunningApplication(processIdentifier: other.pid)?.activate()
        await pause(0.6)
        guard let b = await fold(otherWindow, at: CGPoint(x: 540, y: 400), size: CGSize(width: 440, height: 280), h) else { return }
        probe.send("freeze:6")
        await pause(0.3)
        await doubleClick(at: b.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await expectFrame({ other.window() }, b.frame, h, within: 1.5, "the responsive app's window")
        await h.probeFor(2)
        await pause(4)
        await unfold(a, probe, h)
    },

    // MARK: 故障注入（第 10 节，X01 至 X05 在 Scenarios.swift）
    Scenario(id: "X08", title: "窗口标题每 0.1 秒变一次：收起、看一眼、展开", options: ["--title-churn"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        _ = await hoverForGlance(folded)
        await glide(to: h.neutral, duration: 0.3)
        await pause(1)
        await unfold(folded, probe, h)
    },
    Scenario(id: "X09", title: "窗口拒绝被移动：仍能收起，展开后在原处", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await pause(0.6)
        probe.send("pin")
        await pause(0.3)
        guard let frame = axFrame(window) else { return }
        let point = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: point, duration: 0.3)
        await doubleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        let folded = await eventually(4) { stripFrames().count == 1 }
        h.result.notes["folded"] = folded
        await h.probeFor(1)
        if folded { await doubleClick(at: point) }
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, frame, h, within: 5)
        await expectNoStrip(h, within: 2)
        h.expect(probe.window().map { !axBool($0, kAXMinimizedAttribute as String) } ?? false, "X09: the window is still minimized")
    },
    Scenario(id: "X10", title: "收起后应用程序把窗口移回原处：卷帘条移除，窗口在原处", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        probe.send("move:\(Int(folded.frame.minX)),\(Int(folded.frame.minY))")
        if await stillHiddenAfterMove(probe, folded, h) { return }
        await expectNoStrip(h, within: 4)
        await expectRestored(probe, folded.frame, h, within: 3)
    },

    // MARK: 设置窗口（第 6 节）
    Scenario(id: "H01", title: "在设置窗口里改开关：立即写入设置", options: [], changesSettings: true) { _, h in
        h.expect(await pressWindowShadeMenu("设置"), "H01: no Settings item")
        guard await eventually(4, { windowShadeWindow("卷帘") != nil || windowShadeWindow("设置") != nil }),
              let settings = windowShadeWindow("卷帘") ?? windowShadeWindow("设置") else {
            h.result.violations.append("H01: the settings window did not open"); return
        }
        for (name, key) in [("卷帘条置顶", "ShadeFloatingOnTop"), ("看一眼", "GlanceEnabled")] {
            let before = readDefault(key)
            guard let element = toggle(settings, name) else {
                h.result.violations.append("H01: no control named \(name)"); continue
            }
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            await pause(0.6)
            let after = readDefault(key)
            h.expect(after != before, "H01: \(name) did not change \(key) (\(before) → \(after))")
        }
        if let proxy = control(settings, "统一标题栏") {
            AXUIElementPerformAction(proxy, kAXPressAction as CFString)
            await pause(0.6)
            h.expect(readDefault("ShadeAppearanceMode") == "proxyTitleBar", "H01: the appearance choice was not saved")
        } else {
            h.result.violations.append("H01: no appearance choice named 统一标题栏")
        }
    },
    Scenario(id: "H02", title: "有窗口收起着时改“收起后的样子”：已收起的窗口照常展开", options: [], changesSettings: true) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        _ = await pressWindowShadeMenu("设置")
        await pause(1.5)
        if let settings = windowShadeWindow("卷帘") ?? windowShadeWindow("设置"), let thumbnail = control(settings, "缩略图") {
            AXUIElementPerformAction(thumbnail, kAXPressAction as CFString)
            await pause(0.8)
        } else {
            h.result.violations.append("H02: could not change the appearance in settings")
        }
        await unfold(folded, probe, h)
    },
    Scenario(id: "H10", title: "欢迎窗口点关闭：记为看过，下次不再自动出现", options: [], changesSettings: true) { _, h in
        _ = await relaunchWindowShade([["ShadeOnboardingShown", "-bool", "false"]])
        guard await eventually(4, { windowShadeWindow("欢迎") != nil }), let welcome = windowShadeWindow("欢迎") else {
            h.result.violations.append("H10: the welcome window did not appear on first launch"); return
        }
        var close: CFTypeRef?
        AXUIElementCopyAttributeValue(welcome, kAXCloseButtonAttribute as CFString, &close)
        if let close { AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) }
        await pause(1)
        h.expect(readDefault("ShadeOnboardingShown") == "1", "H10: closing the welcome window did not mark it as seen")
    },

    // MARK: 真实应用程序里的标签页和快速查看
    Scenario(id: "A21", title: "访达有两个标签页时收起、展开：标签页不丢", options: []) { _, h in
        guard let window = await standardWindow(of: "com.apple.finder", launch: ["/Applications"]) else {
            h.result.notes["skipped"] = "no Finder window"; return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        place(window, origin: CGPoint(x: 160, y: 120), size: CGSize(width: 900, height: 500))
        await pause(0.8)
        await pressKey(17, .maskCommand)   // T
        await pause(1.5)
        func tabs() -> Int {
            findElement(window) { axString($0, kAXRoleAttribute as String) == "AXTabGroup" }.map { axChildren($0).count } ?? 0
        }
        let before = tabs()
        await realAppRoundTrip("com.apple.finder", launch: ["/Applications"], size: CGSize(width: 900, height: 500),
                               barY: 8, quitAfter: false, h)
        h.expect(tabs() == before, "A21: tabs changed from \(before) to \(tabs())")
        await pressKey(13, .maskCommand)   // W 关掉多开的标签页
    },
    // 用户打开快速查看的方式：在访达里选中一项，按空格。以前用 `qlmanage -p` 代替，但那是命令行调试工具，
    // 它的预览窗口不回答辅助功能查询（命中测试很快返回 -25204），WindowShade 动不了它（docs/testing.md 第 5 节）。
    // 选中的方式：打开只放一个文件的文件夹，按 ⌘A。`open -R` 定位临时目录里的文件在 CI 上没有反应（5b53a02）；
    // 在“应用程序”文件夹里键入名字选中也不可靠，紧跟着的空格被当成名字的一部分，快速查看没有打开（7158a9e、17f75fa）。
    Scenario(id: "A32", title: "快速查看窗口收起、展开：展开时重新打开同一个文件", options: []) { _, h in
        let item = "A32 preview"
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WindowShade-A32")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "WindowShade A32\n".write(to: folder.appendingPathComponent(item + ".txt"), atomically: true, encoding: .utf8)
        let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        func finderWindows() -> [AXUIElement] {
            guard let finderPID else { return [] }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finderPID), kAXWindowsAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        let before = Set(finderWindows().map { axString($0, kAXTitleAttribute as String) })
        defer {
            // 关掉预览和为这一条打开的访达窗口，免得盖住后面场景的窗口。
            post(.keyDown, key: 53)
            post(.keyUp, key: 53)
            for window in finderWindows() where !before.contains(axString(window, kAXTitleAttribute as String)) {
                _ = pressCloseButton(window)
            }
            run("/usr/bin/killall", ["qlmanage"], timeout: 5)
            try? FileManager.default.removeItem(at: folder)
        }
        /// 预览窗口：按空格之后新出现在屏幕上、高过 100 点、不属于 WindowShade 的窗口。7047ba0 上预览已经打开，
        /// 但按标题（文件名）和所属进程名都没有认出来，所以不再猜它的标题和进程，只看是不是新出现的。
        func onScreen() -> [[String: Any]] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                let owner = $0[kCGWindowOwnerName as String] as? String ?? ""
                let layer = $0[kCGWindowLayer as String] as? Int ?? 0
                let height = ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.height ?? 0
                return owner != "WindowShade" && owner != "Window Server" && owner != "Dock" && layer < 1000 && height > 100
            }
        }
        var baseline: Set<Int> = []
        func newWindows() -> [[String: Any]] {
            onScreen().filter { !baseline.contains($0[kCGWindowNumber as String] as? Int ?? 0) }
        }
        func bounds(_ info: [String: Any]) -> CGRect? {
            (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        func describe(_ windows: [[String: Any]]) -> [String] {
            windows.map { info in
                let rect = bounds(info) ?? .zero
                return "\(info[kCGWindowOwnerName as String] as? String ?? "?") \"\(info[kCGWindowName as String] as? String ?? "")\" "
                    + "layer=\(info[kCGWindowLayer as String] as? Int ?? 0) \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
            }
        }
        /// 新出现、不透明的窗口里最大的一扇。快速查看打开时访达新出现两扇第 3 层的窗口：一扇是面板，
        /// 一扇是放大动画用的半透明过渡窗口（e1cc7bd：透明度 0.16）。
        func qlWindow() -> CGRect? {
            newWindows().filter { ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0.9 }
                .compactMap(bounds).max { $0.width * $0.height < $1.width * $1.height }
        }
        run("/usr/bin/open", [folder.path])
        await pause(2)
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        await pause(0.6)
        await pressKey(0, .maskCommand)   // ⌘A：文件夹里只有这一个文件
        await pause(1.5)
        baseline = Set(onScreen().compactMap { $0[kCGWindowNumber as String] as? Int })
        await pressKey(49)   // 空格
        let opened = await eventually(6) { qlWindow() != nil }
        h.result.notes["preview"] = describe(newWindows())
        h.result.notes["finderWindows"] = finderWindowFacts(finderPID)
        // 面板打开时有放大动画，CI 上要一两秒；动画没走完就按当时的外框双击，点会落在最终标题栏下面（e1cc7bd：
        // 取外框时在 (123,116 721x483)，双击时已是 (104,65 816x611)）。等外框连续 0.6 秒不变再取。
        var stable: CGRect?
        if opened {
            let started = Date()
            var last = qlWindow(), since = Date()
            while Date().timeIntervalSince(started) < 5 {
                await pause(0.1)
                let now = qlWindow()
                if now != last { last = now; since = Date() } else if Date().timeIntervalSince(since) >= 0.6 { stable = now; break }
            }
            h.result.notes["previewFrame"] = stable.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "not stable in 5 s"
        }
        guard opened, let frame = stable else {
            h.result.violations.append(opened ? "setup: the Quick Look panel kept changing size for 5 s" : "setup: Quick Look did not open from Finder")
            h.result.notes["onScreen"] = describe(onScreen())
            return
        }
        let point = CGPoint(x: frame.minX + frame.width * 0.6, y: frame.minY + 12)
        await glide(to: point, duration: 0.3)
        await doubleClick(at: point)
        await glide(to: h.neutral, duration: 0.2)
        let folded = await eventually(3) { stripFrames().count == 1 }
        h.expect(folded, "A32: the Quick Look window did not fold")
        guard folded, let strip = stripFrames().first else { return }
        await doubleClick(at: CGPoint(x: strip.midX, y: strip.midY))
        await glide(to: h.neutral, duration: 0.2)
        let reopened = await eventually(6) { qlWindow() != nil }
        h.result.notes["reopened"] = describe(newWindows())
        h.expect(reopened, "A32: Quick Look did not reopen")
        await expectNoStrip(h, within: 3)
    },

    // MARK: 权限（record.sh 收回权限后单独运行）
    Scenario(id: "A26", title: "没有屏幕录制权限时收起：改用统一标题栏", options: [], group: "no-screen-recording") { probe, h in
        guard permissionRevoked("screenRecording", h) else { return }
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(h.logLines().contains { $0.contains(">>> shade") && $0.contains("mode=proxyTitleBar") },
                 "A26: the strip did not fall back to the unified title bar")
        await unfold(folded, probe, h)
    },
    Scenario(id: "D08", title: "没有屏幕录制权限时停在卷帘条上：不出错", options: [], group: "no-screen-recording") { probe, h in
        guard permissionRevoked("screenRecording", h) else { return }
        guard let folded = await foldProbe(probe, h) else { return }
        _ = await hoverForGlance(folded, 1.5)
        await glide(to: h.neutral, duration: 0.3)
        await pause(1)
        await unfold(folded, probe, h)
    },
    Scenario(id: "A27", title: "没有辅助功能权限时按快捷键：不收起，欢迎窗口出现，辅助功能一行是“去授权”（H08）",
             options: [], group: "no-accessibility") { probe, h in
        guard permissionRevoked("accessibility", h) else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        await pause(0.6)
        await pressShortcut(toggleKey)
        await expectNoFold(0, h, "A27")
        guard await eventually(4, { windowShadeWindow("欢迎") != nil }), let welcome = windowShadeWindow("欢迎") else {
            h.result.violations.append("A27: the welcome window did not appear"); return
        }
        h.expect(control(welcome, "去授权") != nil, "H08: no Grant button for Accessibility")
        if let start = control(welcome, "开始使用") {
            h.expect(!isEnabled(start), "H08: Start is enabled without Accessibility")
        } else {
            h.result.violations.append("H08: no Start button")
        }
    },
    Scenario(id: "H09", title: "欢迎窗口开着时授予辅助功能：变成已授权，“开始使用”可以点", options: [],
             group: "no-accessibility") { probe, h in
        guard permissionRevoked("accessibility", h) else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        await pressShortcut(toggleKey)
        guard await eventually(4, { windowShadeWindow("欢迎") != nil }) else {
            h.result.violations.append("H09: the welcome window did not appear"); return
        }
        guard await requestGrant("accessibility") else { h.result.violations.append("setup: the grant was not done"); return }
        let granted = await eventually(4) {
            guard let welcome = windowShadeWindow("欢迎") else { return false }
            return control(welcome, "去授权") == nil && (control(welcome, "开始使用").map(isEnabled) ?? false)
        }
        h.expect(granted, "H09: the welcome window did not show the new permission within 4 s")
    },
]

@_silgen_name("_AXUIElementGetWindow")
private func axGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 访达的全部窗口（A32）：窗口列表里每一扇（含不在屏幕上的）和辅助功能里每一扇，各自的编号、外框。
/// 快速查看面板在辅助功能里的窗口不在屏幕上，画出预览的是别的窗口（a228492），要据此找出两者的对应关系。
func finderWindowFacts(_ pid: pid_t?) -> [String] {
    guard let pid else { return [] }
    var lines: [String] = []
    for info in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
    where (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid {
        let rect = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        lines.append("cg id=\(info[kCGWindowNumber as String] as? Int ?? 0) layer=\(info[kCGWindowLayer as String] as? Int ?? 0) "
            + "alpha=\(info[kCGWindowAlpha as String] as? Double ?? -1) onscreen=\(info[kCGWindowIsOnscreen as String] as? Bool ?? false) "
            + "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) \"\(info[kCGWindowName as String] as? String ?? "")\"")
    }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
    for window in value as? [AXUIElement] ?? [] {
        var id: CGWindowID = 0
        _ = axGetWindow(window, &id)
        let rect = axFrame(window) ?? .zero
        lines.append("ax id=\(id) role=\(axString(window, kAXRoleAttribute as String)) subrole=\(axString(window, kAXSubroleAttribute as String)) "
            + "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) \"\(axString(window, kAXTitleAttribute as String))\"")
    }
    return lines
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (value as? Bool) ?? false
}

/// WindowShade 启动时记下的权限状态（日志里 “permissions:” 那一行）里，这项权限确实没有。
/// 收回没有生效时记成测试准备失败，不当成 App 的缺陷。
func permissionRevoked(_ name: String, _ harness: Harness) -> Bool {
    let path = NSHomeDirectory() + "/Library/Logs/WindowShade/windowshade.log"
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    guard let line = text.split(separator: "\n").last(where: { $0.contains("permissions: accessibility=") }) else {
        harness.result.violations.append("setup: WindowShade did not log its permissions at launch")
        return false
    }
    guard line.contains("\(name)=false") else {
        // CI 机器上辅助功能收不回：两份数据库里都已没有 WindowShade 的记录，tccutil 也报成功，App 仍然有权限
        // （2026-10-08 三次运行）。记为跳过并写明原因，结果表里显示“跳过”，不算通过。
        harness.result.notes["skipped"] = "\(name) is still granted after the revoke on this machine (\(line))"
        return false
    }
    return true
}

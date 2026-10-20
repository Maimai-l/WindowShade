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

/// 找到设置窗口（最多等 4 秒）并切到“卷帘”页，找不到时返回 nil。窗口标题是当前那一页的名字，不是“设置”。
func shadeSettingsWindow() async -> AXUIElement? {
    let pages = ["通用", "快捷键", "权限与更新", "高级"]
    var window: AXUIElement?
    guard await eventually(4, { window = pages.lazy.compactMap(windowShadeWindow).first; return window != nil }),
          let window else { return nil }
    // 工具栏上的分页按钮：标题等于“卷帘”。不用 control()：它按“含有”匹配，可能先找到当前页里含“卷帘”的文字。
    if axString(window, kAXTitleAttribute as String) != "通用",
       let tab = findElement(window, maxDepth: 8, { axString($0, kAXTitleAttribute as String) == "通用" }) {
        AXUIElementPerformAction(tab, kAXPressAction as CFString)
        await pause(0.8)
    }
    return window
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

/// SkyLight：当前桌面的编号，和这台 Mac 上普通桌面（不含全屏应用程序的桌面）的个数。只在测试驱动程序里用。
private func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY).flatMap { dlsym($0, name) }
}

private func skyLightConnection() -> Int32? {
    guard let symbol = skyLightSymbol("SLSMainConnectionID") else { return nil }
    typealias Main = @convention(c) () -> Int32
    return unsafeBitCast(symbol, to: Main.self)()
}

func activeSpaceID() -> UInt64? {
    guard let cid = skyLightConnection(), let symbol = skyLightSymbol("SLSGetActiveSpace") else { return nil }
    typealias Get = @convention(c) (Int32) -> UInt64
    return unsafeBitCast(symbol, to: Get.self)(cid)
}

func desktopCount() -> Int {
    guard let cid = skyLightConnection(), let symbol = skyLightSymbol("SLSCopyManagedDisplaySpaces") else { return 0 }
    typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
    guard let displays = unsafeBitCast(symbol, to: Copy.self)(cid)?.takeRetainedValue() as? [[String: Any]] else { return 0 }
    // type 0 是普通桌面，4 是全屏应用程序占的桌面。
    return displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.filter { ($0["type"] as? Int) == 0 }.count
}

/// 每块屏幕上各个桌面的 ID（含全屏应用程序占的桌面），一块屏幕一行，按调度中心里从左到右排。
func desktopRows() -> [[UInt64]] {
    guard let cid = skyLightConnection(), let symbol = skyLightSymbol("SLSCopyManagedDisplaySpaces") else { return [] }
    typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
    guard let displays = unsafeBitCast(symbol, to: Copy.self)(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return displays.map { display in
        (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
    }
}

/// 回到 home 那个桌面：按 Control-左右方向键，一次一格，最多 8 格。当前桌面和 home 不在同一块屏幕上，或按键没有切换桌面时，放弃。
/// 返回是否回到了 home。
@discardableResult
func returnToDesktop(_ home: UInt64) async -> Bool {
    for _ in 0..<8 {
        guard let now = activeSpaceID() else { return false }
        if now == home { return true }
        guard let row = desktopRows().first(where: { $0.contains(now) && $0.contains(home) }),
              let from = row.firstIndex(of: now), let to = row.firstIndex(of: home) else { return false }
        await switchDesktop(right: to > from)
        if activeSpaceID() == now { return false }
    }
    return activeSpaceID() == home
}

/// 只有一个桌面时（CI 的虚拟机）新建一个：打开调度中心，按桌面栏上的“添加桌面”按钮，再按 Esc 关掉调度中心。
/// 返回值：做完之后是否至少有两个桌面。
func ensureTwoDesktops() async -> Bool {
    if desktopCount() >= 2 { return true }
    run("/usr/bin/open", ["-a", "Mission Control"])
    await pause(1.5)
    var added = false
    if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
       let button = findElement(AXUIElementCreateApplication(dock.processIdentifier), maxDepth: 12, { element in
           let id = axString(element, "AXIdentifier"), role = axString(element, kAXRoleAttribute as String)
           let text = (axString(element, kAXDescriptionAttribute as String) + " " + axString(element, kAXTitleAttribute as String)).lowercased()
           return id == "mc.spaces.add" || (role == "AXButton" && (text.contains("add desktop") || text.contains("添加桌面")))
       }) {
        added = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        await pause(1.5)
    }
    await pressKey(53)
    await pause(1.5)
    log("add desktop: pressed=\(added) desktops=\(desktopCount())")
    return desktopCount() >= 2
}

/// 按 Control-右方向键（或左方向键）切到相邻的桌面，和系统设置里“调度中心”的默认快捷键一样。
func switchDesktop(right: Bool) async {
    await pressKey(right ? 124 : 123, [.maskControl, .maskSecondaryFn, .maskNumericPad])
    await pause(1.2)
}

/// 访达里标题是 title 的那扇窗口。
func finderWindow(titled title: String) -> AXUIElement? {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return nil }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finder.processIdentifier), kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement] ?? []).first { axString($0, kAXTitleAttribute as String) == title }
}

/// 测试窗口是否显示在当前桌面上（窗口列表里只有当前桌面上的窗口算“在屏幕上”）。
func probeWindowOnThisDesktop(_ probe: Probe) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { info in
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == probe.pid
            && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
}

/// S6-carry（需求 S6）：收起测试窗口，按住卷帘条按 Control-右方向键，松开。卷帘条要留在右边的桌面，不挪回原来的桌面；
/// 双击展开后，窗口出现在右边的桌面，屏幕不切回原来的桌面。依据：2026-10-18 用户的日志，卷帘条被挪回了原来的桌面。
func carryStripToNextDesktop(_ probe: Probe, _ h: Harness) async {
    guard await ensureTwoDesktops(), let home = activeSpaceID() else {
        h.result.notes["skipped"] = "this Mac has only one desktop and adding one failed"; return
    }
    guard await foldProbe(probe, h) != nil, let strip = stripFrames().first else { await returnToDesktop(home); return }
    // 按在卷帘条的中间（避开左边的红绿灯），按住时切到右边的桌面，再松开。
    let grab = CGPoint(x: strip.midX, y: strip.midY)
    await glide(to: grab, duration: 0.3)
    await pause(0.3)
    post(.leftMouseDown, at: grab)
    await pause(0.4)
    await switchDesktop(right: true)
    let other = activeSpaceID()
    post(.leftMouseUp, at: grab)
    await pause(1.5)
    guard let other, other != home else {
        h.result.notes["skipped"] = "Control-Right Arrow did not switch desktops"
        await returnToDesktop(home)
        return
    }
    h.result.notes["desktops"] = "home=\(home) carried to=\(other) now=\(activeSpaceID().map { String($0) } ?? "?")"
    h.expect(activeSpaceID() == other, "S6-carry: the desktop switched back after the strip was released (now \(activeSpaceID() ?? 0))")
    let carried = stripFrames().first
    h.expect(carried != nil, "S6-carry: the strip did not stay on the new desktop")
    if let carried {
        await doubleClick(at: CGPoint(x: carried.midX, y: carried.midY))
        await pause(2.0)
        h.expect(activeSpaceID() == other, "S6-carry: unfolding switched the desktop (\(other) → \(activeSpaceID() ?? 0))")
        h.expect(probeWindowOnThisDesktop(probe), "S6-carry: the window did not open on the new desktop")
        await expectNoStrip(h, within: 3)
    }
    await returnToDesktop(home)
}

/// 每个桌面的类型，按桌面编号查：0 是普通桌面，4 是全屏应用程序的桌面，读不到记 -1。
func spaceTypes() -> [UInt64: Int] {
    guard let cid = skyLightConnection(), let symbol = skyLightSymbol("SLSCopyManagedDisplaySpaces") else { return [:] }
    typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
    guard let displays = unsafeBitCast(symbol, to: Copy.self)(cid)?.takeRetainedValue() as? [[String: Any]] else { return [:] }
    var types: [UInt64: Int] = [:]
    for space in displays.flatMap({ $0["Spaces"] as? [[String: Any]] ?? [] }) {
        if let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value { types[id] = space["type"] as? Int ?? -1 }
    }
    return types
}

/// S6-carry-fullscreen：原桌面右边紧挨着全屏应用程序的桌面时，按住卷帘条按 Control-右方向键。
/// 按住普通窗口按 Control-右方向键时，系统跳过全屏应用程序的桌面，直接到下一个普通桌面；按住卷帘条也要这样：
/// 屏幕不停在全屏应用程序的桌面上，卷帘条和原窗口都到下一个普通桌面。
/// 先用没收起的测试窗口试一次：系统对普通窗口也不跳过全屏应用程序的桌面时（例如虚拟机上），这个场景记为没有运行，不算失败。
/// 依据：用户 macOS 15.2 的录像和日志（869b8b0）里，WindowShade 把卷帘条带进了全屏应用程序的桌面（编号 25 至 30），
/// 原窗口移不进去，又把卷帘条挪回原桌面，屏幕在几个桌面之间来回切换。用户 2026-10-19 指出，按住普通窗口时系统会跳过全屏应用程序的桌面。
func carryStripPastFullScreenDesktop(_ probe: Probe, _ h: Harness) async {
    let id = "S6-carry-fullscreen"
    guard await ensureTwoDesktops(), let home = activeSpaceID() else {
        h.result.notes["skipped"] = "this Mac has only one desktop and adding one failed"; return
    }
    // 在这个桌面上开一个文本编辑的空文稿，设成全屏：系统把全屏应用程序的桌面放在这个桌面右边。
    let textEdit = "com.apple.TextEdit"
    let textEditWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).isEmpty
    // 在临时目录写一个空文件，用 open 让文本编辑打开它，不用 AppleScript：AppleScript 控制文本编辑要用户授权，
    // CI 上会弹出授权框，盖住要测的窗口（a0a3612）。
    let note = FileManager.default.temporaryDirectory.appendingPathComponent("S6 full screen.txt")
    try? Data().write(to: note)
    run("/usr/bin/open", ["-a", "TextEdit", note.path])
    await pause(2)
    var fullScreenWindow: AXUIElement?
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).first {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &value)
        if let value, CFGetTypeID(value) == AXUIElementGetTypeID() { fullScreenWindow = unsafeDowncast(value, to: AXUIElement.self) }
    }
    func cleanUp() async {
        if let window = fullScreenWindow {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            await pause(2)
            var close: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close) == .success, let close,
               CFGetTypeID(close) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(unsafeDowncast(close, to: AXUIElement.self), kAXPressAction as CFString)
            }
        }
        if !textEditWasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).forEach { $0.terminate() }
        }
        await pause(1)
        await returnToDesktop(home)
    }
    guard let window = fullScreenWindow,
          AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success else {
        h.result.notes["skipped"] = "TextEdit could not go full screen"; await cleanUp(); return
    }
    await pause(2.5)
    await returnToDesktop(home)
    let types = spaceTypes()
    guard activeSpaceID() == home, let row = desktopRows().first(where: { $0.contains(home) }),
          let at = row.firstIndex(of: home), at + 2 < row.count, types[row[at + 1]] == 4, types[row[at + 2]] == 0 else {
        h.result.notes["skipped"] = "the full-screen desktop is not between this desktop and the next one: \(desktopRows()) types=\(types)"
        await cleanUp(); return
    }
    let next = row[at + 2]
    h.result.notes["desktops"] = "home=\(home) fullScreen=\(row[at + 1]) next=\(next)"

    // 先用没收起的测试窗口试：按住标题栏按 Control-右方向键，看系统是否跳过全屏应用程序的桌面；再按 Control-左方向键带回来。
    NSRunningApplication(processIdentifier: probe.pid)?.activate()
    await pause(0.5)
    guard let frame = probe.window().flatMap(axFrame) else {
        h.result.violations.append("\(id): setup: no test window"); await cleanUp(); return
    }
    let titleBar = CGPoint(x: frame.midX, y: frame.minY + 12)
    await glide(to: titleBar, duration: 0.3)
    await pause(0.3)
    post(.leftMouseDown, at: titleBar)
    await pause(0.4)
    await switchDesktop(right: true)
    let normalLanded = activeSpaceID()
    await switchDesktop(right: false)
    post(.leftMouseUp, at: titleBar)
    await pause(1)
    h.result.notes["normalWindow"] = "landed on \(normalLanded.map(String.init) ?? "?")"
    guard normalLanded == next, activeSpaceID() == home else {
        h.result.notes["skipped"] = "the system did not skip the full-screen desktop for a normal window either "
            + "(landed on \(normalLanded.map(String.init) ?? "?"), now \(activeSpaceID().map(String.init) ?? "?"))"
        await cleanUp(); return
    }

    guard await foldProbe(probe, h) != nil, let strip = stripFrames().first else { await cleanUp(); return }
    let grab = CGPoint(x: strip.midX, y: strip.midY)
    await glide(to: grab, duration: 0.3)
    await pause(0.3)
    post(.leftMouseDown, at: grab)
    await pause(0.4)
    await switchDesktop(right: true)
    let landed = activeSpaceID()
    post(.leftMouseUp, at: grab)
    await pause(1.5)
    h.expect(landed == next, "\(id): the screen stopped on \(landed.flatMap { types[$0] } == 4 ? "the full-screen app's desktop" : "desktop \(landed.map(String.init) ?? "?")") "
             + "instead of the next desktop \(next)")
    h.expect(activeSpaceID() == landed, "\(id): the desktop switched by itself after the strip was released (\(landed.map(String.init) ?? "?") → \(activeSpaceID().map(String.init) ?? "?"))")
    if activeSpaceID() == next {
        let carried = stripFrames().first
        h.expect(carried != nil, "\(id): the strip did not come to the next desktop")
        if let carried {
            await doubleClick(at: CGPoint(x: carried.midX, y: carried.midY))
            await pause(2.0)
            h.expect(activeSpaceID() == next, "\(id): unfolding switched the desktop (\(next) → \(activeSpaceID().map(String.init) ?? "?"))")
            h.expect(probeWindowOnThisDesktop(probe), "\(id): the window did not open on the next desktop")
        }
    }
    await cleanUp()
}

/// S6-carry-sip：和 S6-carry 一样按住卷帘条切到右边的桌面，但让 WindowShade 当作系统完整性保护开着（用户的 Mac 开着，CI 的虚拟机关着）。
/// 这时已隐藏的应用程序的窗口等展开时再移：按住切桌面时应用程序一直不显示，屏幕和卷帘条都留在右边的桌面；
/// 展开后窗口在右边的桌面上，屏幕不切回原来的桌面。
/// 依据：用户 macOS 15.2 的录像和日志（2026-10-18，869b8b0）：WindowShade 为了移窗口临时取消隐藏应用程序，窗口露了出来；
/// 窗口没移过去，卷帘条挪回后又重新移，屏幕在几个桌面之间来回切换。
func carryStripWithSIPEnabled(_ probe: Probe, _ h: Harness) async {
    guard await relaunchWindowShade([["WindowShadeAssumeSIPEnabled", "-bool", "true"]]) else {
        h.result.violations.append("S6-carry-sip: setup: WindowShade did not start again"); return
    }
    NSRunningApplication(processIdentifier: probe.pid)?.activate()
    guard await ensureTwoDesktops(), let home = activeSpaceID() else {
        h.result.notes["skipped"] = "this Mac has only one desktop and adding one failed"; return
    }
    guard let folded = await foldProbe(probe, h), let strip = stripFrames().first else { await returnToDesktop(home); return }
    let grab = CGPoint(x: strip.midX, y: strip.midY)
    await glide(to: grab, duration: 0.3)
    await pause(0.3)
    post(.leftMouseDown, at: grab)
    await pause(0.4)
    // 从切桌面到松开后 1.5 秒，每 0.1 秒看一次应用程序有没有显示出来（共 3 秒）：
    // ef0fc70 之前，WindowShade 在按住期间就取消隐藏，只在松开后看会漏掉。
    let pid = probe.pid
    let watcher = Task.detached { () -> Int in
        var count = 0
        for _ in 0..<30 {
            if NSRunningApplication(processIdentifier: pid)?.isHidden == false { count += 1 }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return count
    }
    await switchDesktop(right: true)
    let other = activeSpaceID()
    post(.leftMouseUp, at: grab)
    await pause(1.5)
    let shown = await watcher.value
    guard let other, other != home else {
        h.result.notes["skipped"] = "Control-Right Arrow did not switch desktops"
        await returnToDesktop(home)
        return
    }
    h.expect(shown == 0, "S6-carry-sip: the app was shown while the strip was carried (\(shown) of 30 checks)")
    h.expect(activeSpaceID() == other, "S6-carry-sip: the desktop switched by itself (\(other) → \(activeSpaceID() ?? 0))")
    let carried = stripFrames().first
    h.expect(carried != nil, "S6-carry-sip: the strip did not stay on the new desktop")
    if let carried {
        await doubleClick(at: CGPoint(x: carried.midX, y: carried.midY))
        await pause(2.0)
        h.expect(activeSpaceID() == other, "S6-carry-sip: unfolding switched the desktop (\(other) → \(activeSpaceID() ?? 0))")
        h.expect(probeWindowOnThisDesktop(probe), "S6-carry-sip: the window did not open on the new desktop")
        await expectNoStrip(h, within: 3)
    } else if await returnToDesktop(home) {
        await unfold(folded, probe, h)
    }
    await returnToDesktop(home)
}

/// S6-carry-finder-sip：让 WindowShade 当作系统完整性保护开着，收起一扇访达窗口（访达不隐藏整个应用程序，窗口移到屏幕外），
/// 按住卷帘条切到右边的桌面：卷帘条留在右边的桌面，展开后窗口在右边的桌面，屏幕不切回原来的桌面。
/// 依据：用户 macOS 15.2 的日志（869b8b0），移到屏幕外的访达窗口跟过去了 4 次；系统完整性保护开着时这种窗口照样要跟过去。
func carryFinderStripWithSIPEnabled(_ h: Harness) async {
    guard await relaunchWindowShade([["WindowShadeAssumeSIPEnabled", "-bool", "true"]]) else {
        h.result.violations.append("S6-carry-finder-sip: setup: WindowShade did not start again"); return
    }
    guard await ensureTwoDesktops(), let home = activeSpaceID() else {
        h.result.notes["skipped"] = "this Mac has only one desktop and adding one failed"; return
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("windowshade-s6-finder")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    run("/usr/bin/open", [folder.path])
    var window: AXUIElement?
    _ = await eventually(5) { window = finderWindow(titled: folder.lastPathComponent); return window != nil }
    await pause(1)
    guard let window, let frame = axFrame(window) else {
        h.result.violations.append("S6-carry-finder-sip: setup: the Finder window did not open"); return
    }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let point = emptyTitleBarPoint(CGPoint(x: frame.midX, y: frame.minY + 14), minX: frame.minX + 80, maxX: frame.maxX - 20)
    let stripsBefore = stripFrames().count
    await glide(to: point, duration: 0.3)
    await doubleClick(at: point)
    _ = await eventually(4) { stripFrames().count > stripsBefore }
    await pause(0.8)
    guard let strip = stripFrames().first(where: { $0.contains(point) || abs($0.minY - frame.minY) < 30 }) ?? stripFrames().first else {
        h.result.violations.append("S6-carry-finder-sip: the Finder window did not fold")
        closeWindow(window); return
    }
    let grab = CGPoint(x: strip.midX, y: strip.midY)
    await glide(to: grab, duration: 0.3)
    await pause(0.3)
    post(.leftMouseDown, at: grab)
    await pause(0.4)
    await switchDesktop(right: true)
    let other = activeSpaceID()
    post(.leftMouseUp, at: grab)
    await pause(1.5)
    defer { closeWindow(window) }
    guard let other, other != home else {
        h.result.notes["skipped"] = "Control-Right Arrow did not switch desktops"
        await returnToDesktop(home)
        return
    }
    h.result.notes["desktops"] = "home=\(home) carried to=\(other) now=\(activeSpaceID().map { String($0) } ?? "?")"
    h.expect(activeSpaceID() == other, "S6-carry-finder-sip: the desktop switched back after the strip was released")
    let carried = stripFrames().first
    h.expect(carried != nil, "S6-carry-finder-sip: the strip did not stay on the new desktop")
    if let carried {
        await doubleClick(at: CGPoint(x: carried.midX, y: carried.minY + 8))
        await pause(2.0)
        h.expect(activeSpaceID() == other, "S6-carry-finder-sip: unfolding switched the desktop (\(other) → \(activeSpaceID() ?? 0))")
        h.expect(!finderWindowFramesOnThisDesktop().isEmpty, "S6-carry-finder-sip: the Finder window did not open on the new desktop")
    }
    await returnToDesktop(home)
}

/// E11 和 E11-trash：在当前桌面上开一扇访达窗口，切到右边的桌面，用 openTarget 打开要收起的访达窗口，
/// 只留它一扇在右边的桌面上，收起、展开，检查桌面都没有切换。openTarget 收到一个可以打开的空文件夹，E11 打开它，E11-trash 不用它。
func foldFinderOnSecondDesktop(_ h: Harness, id: String, openTarget: (URL) -> Void) async {
        guard await ensureTwoDesktops(), let home = activeSpaceID() else {
            h.result.notes["skipped"] = "this Mac has only one desktop and adding one failed"; return
        }
        let base = FileManager.default.temporaryDirectory
        let here = base.appendingPathComponent("windowshade-e11-a"), there = base.appendingPathComponent("windowshade-e11-b")
        for folder in [here, there] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        run("/usr/bin/open", [here.path])
        guard await eventually(5, { finderWindow(titled: here.lastPathComponent) != nil }) else {
            h.result.notes["skipped"] = "no Finder window opened"; return
        }
        await switchDesktop(right: true)
        guard let other = activeSpaceID(), other != home else {
            h.result.notes["skipped"] = "Control-Right Arrow did not switch desktops"
            if let window = finderWindow(titled: here.lastPathComponent) { closeWindow(window) }
            return
        }
        let before = finderWindowElements()
        openTarget(there)
        var target: AXUIElement?
        _ = await eventually(5) {
            target = finderWindowElements().first { window in !before.contains { CFEqual($0, window) } }
            return target != nil
        }
        await pause(1)
        // 这个桌面上只能有要收起的这一扇访达窗口：别的访达窗口（例如前面场景留下的）会得到焦点，
        // 就测不到这个桌面上没有别的访达窗口可以得到焦点的情形（2026-10-10 本机运行时 E11 因此通过，但没有测到）。
        var parked: [AXUIElement] = []
        if let target {
            parked = minimizeFinderWindowsOnThisDesktop(except: target)
            if !parked.isEmpty { await pause(1) }
        }
        let finderHere = finderWindowFramesOnThisDesktop().count
        if finderHere != 1 {
            h.result.violations.append("\(id): setup: \(finderHere) Finder windows on this desktop, expected only the one to fold")
        }
        if let target, let frame = axFrame(target), finderHere == 1 {
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            let point = emptyTitleBarPoint(CGPoint(x: frame.midX, y: frame.minY + 14), minX: frame.minX + 80, maxX: frame.maxX - 20)
            await glide(to: point, duration: 0.3)
            await doubleClick(at: point)
            var jumpedTo: UInt64?
            for _ in 0..<25 {
                await pause(0.1)
                if let now = activeSpaceID(), now != other { jumpedTo = now; break }
            }
            h.result.notes["desktops"] = "home=\(home) folded on=\(other) after=\(activeSpaceID().map { String($0) } ?? "?")"
            h.expect(jumpedTo == nil, "\(id): folding the Finder window switched the desktop (\(other) → \(jumpedTo ?? 0))")
            if activeSpaceID() == other, let strip = stripFrames().first {
                await doubleClick(at: CGPoint(x: strip.midX, y: strip.minY + 8))
                await pause(1.5)
                let afterUnfold = activeSpaceID()
                h.expect(afterUnfold == other,
                         "\(id): unfolding the Finder window switched the desktop (\(other) → \(afterUnfold ?? 0))")
            } else if jumpedTo != nil {
                await switchDesktop(right: true)
                if let strip = stripFrames().first {
                    await doubleClick(at: CGPoint(x: strip.midX, y: strip.minY + 8))
                    await pause(1.5)
                }
            }
        } else if target == nil {
            h.result.violations.append("\(id): setup: the Finder window on the second desktop did not open")
        } else if finderHere == 1 {
            h.result.violations.append("\(id): setup: cannot read the frame of the Finder window on the second desktop")
        }
        if let target { closeWindow(target) }
        for window in parked { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        while let now = activeSpaceID(), now != home {
            await switchDesktop(right: false)
            if activeSpaceID() == now { break }
        }
        if let window = finderWindow(titled: here.lastPathComponent) { closeWindow(window) }
        await glide(to: h.neutral, duration: 0.2)
}

/// 应用程序 bundleID 的窗口里，标题以 prefix 开头的第一扇，各个桌面上的都算。
func appWindow(_ bundleID: String, titlePrefix prefix: String) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement] ?? []).first { axString($0, kAXTitleAttribute as String).hasPrefix(prefix) }
}

/// E12：ProbeApp 只有一扇窗口，在这个桌面上收起它时，焦点应交给这个桌面上的访达窗口；
/// 最近用过的文本编辑窗口在右边的桌面上。最近使用顺序要排成 ProbeApp、文本编辑、访达：
/// 这样排，是因为修复前 WindowShade 隐藏 ProbeApp 时访达还没到前台，系统按这个顺序激活了文本编辑，屏幕切到右边的桌面。
/// 依据：用户的 macOS 14.5 本机运行（4f1a815），收起 ProbeApp 后系统激活了别的桌面上的 LocalSend；见 docs/testing.md 第 5 节。
/// textEditHereToo 为 true 时（场景 E12-both）：这个桌面上 ProbeApp 下面还有一扇文本编辑的窗口，焦点交给文本编辑，
/// 而文本编辑最近用过的窗口在右边的桌面上。检查激活文本编辑后屏幕没有切过去。
/// 依据：用户的 macOS 14.5 本机运行（8e9a4f1）里 E11-trash、E12 失败，接手的应用程序在两个桌面上都有窗口。
func foldWithRecentAppOnOtherDesktop(_ probe: Probe, _ h: Harness, textEditHereToo: Bool = false) async {
    let id = textEditHereToo ? "E12-both" : "E12"
    let textEdit = "com.apple.TextEdit"
    guard await ensureTwoDesktops(), let home = activeSpaceID() else {
        h.result.notes["skipped"] = "this Mac has only one desktop and adding one failed"; return
    }
    let textEditWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).isEmpty
    let base = FileManager.default.temporaryDirectory
    let folder = base.appendingPathComponent("windowshade-e12"), note = base.appendingPathComponent("windowshade-e12-note.txt")
    let hereNote = base.appendingPathComponent("windowshade-e12-here.txt")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? "E12".write(to: note, atomically: true, encoding: .utf8)
    try? "E12 here".write(to: hereNote, atomically: true, encoding: .utf8)
    func cleanUp() async {
        if let window = appWindow(textEdit, titlePrefix: "windowshade-e12-note") { closeWindow(window) }
        if let window = appWindow(textEdit, titlePrefix: "windowshade-e12-here") { closeWindow(window) }
        if !textEditWasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).forEach { _ = $0.terminate() }
        }
        if let window = finderWindow(titled: folder.lastPathComponent) { closeWindow(window) }
        await returnToDesktop(home)
        try? FileManager.default.removeItem(at: note)
        try? FileManager.default.removeItem(at: hereNote)
    }
    // 1. 在这个桌面上打开一扇访达窗口，再让 ProbeApp 到前台、窗口在最上面。
    run("/usr/bin/open", [folder.path])
    guard await eventually(5, { finderWindow(titled: folder.lastPathComponent) != nil }) else {
        h.result.notes["skipped"] = "no Finder window opened"; await cleanUp(); return
    }
    await pause(0.5)
    if textEditHereToo {
        // 文本编辑的这扇窗口在访达窗口上面、ProbeApp 下面：收起 ProbeApp 的窗口后，焦点交给它。
        run("/usr/bin/open", ["-a", "TextEdit", hereNote.path])
        guard await eventually(8, { appWindow(textEdit, titlePrefix: "windowshade-e12-here") != nil }) else {
            h.result.violations.append("\(id): setup: TextEdit did not open a note on the first desktop"); await cleanUp(); return
        }
        await pause(0.5)
    }
    guard let window = probe.window() else {
        h.result.violations.append("setup: no Probe window"); await cleanUp(); return
    }
    place(window, origin: probeOrigin, size: probeSize)
    await probe.bringToFront()
    await pause(0.5)
    // 2. 在右边的桌面上用文本编辑打开记事文件。
    await switchDesktop(right: true)
    guard let other = activeSpaceID(), other != home else {
        h.result.notes["skipped"] = "Control-Right Arrow did not switch desktops"; await cleanUp(); return
    }
    run("/usr/bin/open", ["-a", "TextEdit", note.path])
    let textEditInFront = await eventually(8) {
        appWindow(textEdit, titlePrefix: "windowshade-e12-note") != nil
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == textEdit
    }
    guard textEditInFront else {
        h.result.violations.append("\(id): setup: TextEdit did not open the note on the second desktop"); await cleanUp(); return
    }
    await pause(0.5)
    // 3. 回到这个桌面：系统激活这个桌面最上面那扇窗口的应用程序，也就是 ProbeApp。
    await switchDesktop(right: false)
    guard activeSpaceID() == home else {
        h.result.violations.append("\(id): setup: Control-Left Arrow did not return to the first desktop"); await cleanUp(); return
    }
    _ = await eventually(2) { frontmostPID() == probe.pid }
    h.result.notes["frontmostAfterReturn"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    if frontmostPID() != probe.pid { await probe.bringToFront() }
    // 4. 收起 ProbeApp 唯一的窗口，2 秒内每 50 毫秒看一次桌面和前台应用程序。
    guard let frame = axFrame(window) else {
        h.result.violations.append("setup: cannot read the Probe window frame"); await cleanUp(); return
    }
    let titleBar = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
    await glide(to: titleBar, duration: 0.3)
    await pause(0.2)
    await doubleClick(at: titleBar)
    var jumpedTo: UInt64?
    var frontApps: [String] = []
    for _ in 0..<40 {
        await pause(0.05)
        if jumpedTo == nil, let now = activeSpaceID(), now != home { jumpedTo = now }
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        if frontApps.last != name { frontApps.append(name) }
    }
    h.result.notes["frontmostSequence"] = frontApps
    h.result.notes["desktops"] = "home=\(home) other=\(other)"
    h.expect(h.logLines().contains { $0.contains(">>> shade") }, "setup: the Probe window did not fold")
    h.expect(jumpedTo == nil, "\(id): folding the only Probe window switched the desktop (\(home) → \(jumpedTo ?? 0))")
    if !textEditHereToo {
        h.expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier != textEdit,
                 "E12: TextEdit on the other desktop became the active app after folding (\(frontApps.joined(separator: " → ")))")
    }
    // 5. 展开窗口，关掉场景打开的窗口，删掉临时文件。
    await returnToDesktop(home)
    if let strip = stripFrames().first {
        await doubleClick(at: CGPoint(x: strip.midX, y: strip.minY + 8))
        await pause(1.5)
    }
    await cleanUp()
    await glide(to: h.neutral, duration: 0.2)
}

/// 访达的所有标准窗口，各个桌面上的和最小化的都算，从辅助功能接口取。
func finderWindowElements() -> [AXUIElement] {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finder.processIdentifier), kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement] ?? []).filter { axString($0, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String) }
}

/// 当前桌面上访达的普通窗口（层级 0）的位置和大小，按从前到后的顺序。
func finderWindowFramesOnThisDesktop() -> [CGRect] {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
    return (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter {
            ($0[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == finder.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
}

/// 把当前桌面上访达除 keep 以外的窗口都最小化，返回最小化了的窗口，由调用方在场景结束时还原。别的桌面上的窗口不动。
/// 辅助功能接口看不出窗口在哪个桌面，按位置和大小和屏幕上的窗口对上。
func minimizeFinderWindowsOnThisDesktop(except keep: AXUIElement) -> [AXUIElement] {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
    let here = finderWindowFramesOnThisDesktop()
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finder.processIdentifier), kAXWindowsAttribute as CFString, &value)
    var minimized: [AXUIElement] = []
    for window in value as? [AXUIElement] ?? [] where !CFEqual(window, keep) {
        guard let frame = axFrame(window),
              here.contains(where: { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2
                                       && abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2 }),
              AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        else { continue }
        minimized.append(window)
    }
    return minimized
}

func closeWindow(_ window: AXUIElement) {
    var button: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }
}

let systemScenarios: [Scenario] = [
    // MARK: 系统事件（第 7 节）
    // 用户 2026-10-09 报告：访达在一个桌面上有窗口，在另一个桌面上打开废纸篓、双击标题栏，屏幕切到了前一个桌面。
    // 要两个以上的桌面：只有一个时（CI 的虚拟机）先在调度中心里添加一个，添加不了时跳过。
    Scenario(id: "E11", title: "访达在别的桌面上有窗口时，在这个桌面上收起访达的窗口：不切换桌面", options: []) { _, h in
        await foldFinderOnSecondDesktop(h, id: "E11") { there in run("/usr/bin/open", [there.path]) }
    },
    // 和用户报告里一样，这个桌面上打开的是废纸篓。
    Scenario(id: "E11-trash", title: "访达在别的桌面上有窗口时，在这个桌面上收起废纸篓窗口：不切换桌面", options: []) { _, h in
        await foldFinderOnSecondDesktop(h, id: "E11-trash") { _ in
            run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to open trash", "-e", "tell application \"Finder\" to activate"])
        }
    },
    Scenario(id: "S6-carry", title: "按住卷帘条按 Control-右方向键：卷帘条留在右边的桌面，展开后窗口也在那里", options: []) { probe, h in
        await carryStripToNextDesktop(probe, h)
    },
    Scenario(id: "S6-carry-fullscreen", title: "右边紧挨着全屏应用程序的桌面时按住卷帘条按 Control-右方向键：和按住普通窗口一样，屏幕跳过那个桌面，卷帘条和窗口到下一个普通桌面",
             options: []) { probe, h in
        await carryStripPastFullScreenDesktop(probe, h)
    },
    Scenario(id: "S6-carry-sip", title: "系统完整性保护开着时按住卷帘条切桌面：应用程序不显示，屏幕不自己切换桌面，展开后窗口在右边的桌面",
             options: [], changesSettings: true) { probe, h in
        await carryStripWithSIPEnabled(probe, h)
    },
    Scenario(id: "S6-carry-finder-sip", title: "系统完整性保护开着时按住访达的卷帘条切桌面：卷帘条留在新桌面，展开后窗口也在那里",
             options: [], changesSettings: true) { _, h in
        await carryFinderStripWithSIPEnabled(h)
    },
    Scenario(id: "E12", title: "别的桌面上有最近用过的应用程序时，收起只有一扇窗口的应用程序：不切换桌面", options: []) { probe, h in
        await foldWithRecentAppOnOtherDesktop(probe, h)
    },
    Scenario(id: "E12-both", title: "接手焦点的应用程序在两个桌面上都有窗口、最近用过的那扇在别的桌面上时，收起只有一扇窗口的应用程序：不切换桌面", options: []) { probe, h in
        await foldWithRecentAppOnOtherDesktop(probe, h, textEditHereToo: true)
    },
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
        await probe.bringToFront()
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
    Scenario(id: "P07", title: "一个应用程序无响应时，另一个应用程序的卷帘条照常展开", options: []) { probe, h in
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
        await probe.bringToFront()
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
    // 预防全系统输入停止响应（2026-10-08 用户遇到过）：WindowShade 的鼠标钩子是主动钩子，排在最前；
    // 它整个进程停住时（调试器挂起、正在崩溃、内存紧张被换出），系统要等钩子超时才放行点击。
    // 量这段时间：停住 3 秒，期间不断发探测单击、双击，每一次都要在 1 秒内穿过钩子（I2）；恢复后双击照常收起。
    Scenario(id: "X11", title: "WindowShade 整个进程停住 3 秒：点击最多延迟 1 秒，恢复后照常收起", options: []) { probe, h in
        guard let pid = windowShadePID() else { h.result.violations.append("setup: WindowShade is not running"); return }
        // 钩子在钩子进程里（docs/design.md 第 5.9 节）时，WindowShade 停住不挡点击。
        h.result.notes["tapHelper"] = tapHelperPID().map { Int($0) } ?? "none"
        let stopped = Date()
        kill(pid, SIGSTOP)
        await h.probeFor(3)
        kill(pid, SIGCONT)
        h.result.notes["stoppedFor"] = Date().timeIntervalSince(stopped)
        // 停住期间主线程没有运行：恢复后它记下的那次“停顿”不是 WindowShade 自己停顿，不算 I6。
        await pause(1.5)
        h.excuseStallsBeforeNow()
        await h.probeFor(1)
        guard let folded = await foldProbe(probe, h) else { return }
        await unfold(folded, probe, h)
    },
    Scenario(id: "X12", title: "鼠标钩子进程被强制结束：点击照常穿过，WindowShade 重新启动它，之后照常收起", options: []) { probe, h in
        guard let first = tapHelperPID() else {
            h.result.violations.append("X12: no tap helper is running (WindowShade fell back to its own event tap)")
            return
        }
        kill(first, SIGKILL)
        // 钩子进程被结束时正在处理的点击可能被系统丢掉（1b5c572 上的 X12：结束钩子进程后马上发出的探测点击没有到）；
        // 这里要求的是钩子进程退出以后的点击照常送到，所以等 0.2 秒再连续探测 1.5 秒。
        await pause(0.2)
        await h.probeFor(1.5)
        let relaunched = await eventually(4) { tapHelperPID().map { $0 != first } ?? false }
        h.expect(relaunched, "X12: WindowShade did not launch the tap helper again after it was killed")
        h.result.notes["helpers"] = [Int(first), tapHelperPID().map { Int($0) } ?? 0]
        await pause(0.5)
        guard let folded = await foldProbe(probe, h) else { return }
        await unfold(folded, probe, h)
    },

    // MARK: 设置窗口（第 6 节）
    Scenario(id: "H01", title: "在设置窗口里改开关：立即写入设置", options: [], changesSettings: true) { _, h in
        h.expect(await pressWindowShadeMenu("设置"), "H01: no Settings item")
        guard let settings = await shadeSettingsWindow() else {
            h.result.violations.append("H01: the settings window did not open"); return
        }
        for (name, key) in [("卷帘条置顶", "ShadeFloatingOnTop"), ("指针悬停在卷帘条上时显示窗口", "GlanceEnabled")] {
            let before = readDefault(key)
            guard let element = toggle(settings, name) else {
                h.result.violations.append("H01: no control named \(name)"); continue
            }
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            await pause(0.6)
            let after = readDefault(key)
            h.expect(after != before, "H01: \(name) did not change \(key) (\(before) → \(after))")
        }
        if let proxy = control(settings, "简化标题栏") {
            AXUIElementPerformAction(proxy, kAXPressAction as CFString)
            await pause(0.6)
            h.expect(readDefault("ShadeAppearanceMode") == "proxyTitleBar", "H01: the appearance choice was not saved")
        } else {
            h.result.violations.append("H01: no appearance choice named 简化标题栏")
        }
    },
    Scenario(id: "H02", title: "有窗口收起着时改“收起后显示”：已收起的窗口照常展开", options: [], changesSettings: true) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        _ = await pressWindowShadeMenu("设置")
        await pause(1.5)
        if let settings = await shadeSettingsWindow(), let thumbnail = control(settings, "缩略图") {
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
    // 用户打开快速查看的方式：在访达里选中一项，按空格。不用 `qlmanage -p`：那是命令行调试工具，
    // 它的预览窗口不回答辅助功能查询，WindowShade 无法操作它（docs/testing.md 第 5 节）。
    // 选中的方式：打开只放一个文件的文件夹，按 ⌘A。`open -R` 定位临时目录里的文件在 CI 上没有反应；
    // 在“应用程序”文件夹里键入名字选中也不可靠：紧跟着的空格会被当成名字的一部分，快速查看不会打开。
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
        /// 预览窗口：按空格之后新出现在屏幕上、高过 100 点、不属于 WindowShade 的窗口。按标题（文件名）或所属进程名
        /// 都认不出预览窗口（7047ba0），所以不看标题和进程，只看是不是新出现的。
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
        // 面板打开时有放大动画，CI 上要一两秒；动画没走完就按当时的外框双击，点会落在最终标题栏下面（e1cc7bd）。
        // 所以等外框连续 0.6 秒不变再取。
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
    Scenario(id: "A26", title: "没有屏幕录制权限时收起：改用简化标题栏", options: [], group: "no-screen-recording") { probe, h in
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
    Scenario(id: "A27", title: "没有辅助功能权限时按快捷键：不收起，欢迎窗口出现，辅助功能一行是“打开系统设置”（H08）",
             options: [], group: "no-accessibility") { probe, h in
        guard permissionRevoked("accessibility", h) else { return }
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        await pause(0.6)
        await pressShortcut(toggleKey)
        await expectNoFold(0, h, "A27")
        guard await eventually(4, { windowShadeWindow("欢迎") != nil }), let welcome = windowShadeWindow("欢迎") else {
            h.result.violations.append("A27: the welcome window did not appear"); return
        }
        h.expect(control(welcome, "打开系统设置") != nil, "H08: no Grant button for Accessibility")
        if let start = control(welcome, "开始使用") {
            h.expect(!isEnabled(start), "H08: Start is enabled without Accessibility")
        } else {
            h.result.violations.append("H08: no Start button")
        }
    },
    Scenario(id: "H09", title: "欢迎窗口开着时授予辅助功能：变成“已允许”，“开始使用”变为可用", options: [],
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
            return control(welcome, "打开系统设置") == nil && (control(welcome, "开始使用").map(isEnabled) ?? false)
        }
        h.expect(granted, "H09: the welcome window did not show the new permission within 4 s")
    },
]

@_silgen_name("_AXUIElementGetWindow")
private func axGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 访达的全部窗口（A32）：窗口列表里每一扇（含不在屏幕上的）和辅助功能里每一扇，各自的编号、外框。
/// 快速查看打开时有放大动画和一扇过渡窗口（e1cc7bd），这里记下全部窗口，用来对照。
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
            + "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) \"\(axString(window, kAXTitleAttribute as String))\" "
            + "document=\(axDescribe(window, "AXDocument"))")
        // 快速查看面板：它自己不给文件路径（3fbe19b），看子元素里有没有文件名、网址，展开时要靠它重新打开。
        if axString(window, kAXSubroleAttribute as String) == "Quick Look" {
            lines += axTreeFacts(window, depth: 0, budget: 60)
        }
        // 面板只给文件名（3064c36：AXStaticText “A32 preview.txt”），访达窗口不给 AXDocument。
        // 看文件夹窗口里有没有带网址的元素（选中的那一项、路径栏），由此得到完整路径。
        if axString(window, kAXTitleAttribute as String) == "WindowShade-A32" {
            lines += axURLFacts(window, budget: 30)
        }
    }
    return lines
}

func axDescribe(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "-" }
    return String(String(describing: value).prefix(160))
}

/// 一棵辅助功能子树里带网址类属性、或被选中的元素（最多 budget 行、10 层、看 2000 个元素）。
func axURLFacts(_ root: AXUIElement, budget: Int) -> [String] {
    var lines: [String] = []
    var visited = 0
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard lines.count < budget, depth <= 10, visited < 2000 else { return }
        visited += 1
        var fields: [String] = []
        for attribute in ["AXURL", "AXDocument", "AXFilename"] {
            let text = axDescribe(element, attribute)
            if text != "-" && !text.isEmpty { fields.append("\(attribute)=\(text)") }
        }
        let selected = axDescribe(element, "AXSelected") == "1"
        if !fields.isEmpty || selected {
            lines.append("url d=\(depth) \(axString(element, kAXRoleAttribute as String)) selected=\(selected) "
                + "title=\(axDescribe(element, "AXTitle")) " + fields.joined(separator: " "))
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(root, 0)
    lines.append("url visited=\(visited)")
    return lines
}

/// 一棵辅助功能子树里每个元素的角色和文字、网址类属性（最多 budget 行、6 层）。
func axTreeFacts(_ element: AXUIElement, depth: Int, budget: Int) -> [String] {
    var lines: [String] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard lines.count < budget, depth <= 6 else { return }
        var fields: [String] = []
        for attribute in ["AXTitle", "AXValue", "AXDescription", "AXDocument", "AXURL", "AXFilename", "AXHelp"] {
            let text = axDescribe(element, attribute)
            if text != "-" && !text.isEmpty { fields.append("\(attribute)=\(text)") }
        }
        lines.append(String(repeating: "  ", count: depth) + axString(element, kAXRoleAttribute as String) + " " + fields.joined(separator: " "))
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(element, depth)
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

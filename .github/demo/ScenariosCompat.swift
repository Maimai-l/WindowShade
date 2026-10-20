// 其他开发者的应用程序：记下窗口顶部的样子和收起的结果，用来判断卷帘条从哪里裁切、哪些窗口不该收起。
// 这些应用程序在 RECORD_PART 的 only: 里列出 COMPAT- 场景时，由 record.sh 用 Homebrew 装上；没装上的场景跳过。

import AppKit
import ApplicationServices

/// 把辅助功能元素的角色、子角色、位置大小和标题前 30 个字写成一行，供日志用。
func axSummary(_ element: AXUIElement) -> String {
    let frame = axFrame(element).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-"
    let subrole = axString(element, kAXSubroleAttribute as String)
    let title = axString(element, kAXTitleAttribute as String).prefix(30)
    return "\(axString(element, kAXRoleAttribute as String))\(subrole.isEmpty ? "" : "/" + subrole) \(frame)"
        + (title.isEmpty ? "" : " \"\(title)\"")
}

/// 窗口顶部 150 点以内的辅助功能元素；最多查看 300 个。
func axTopElements(_ window: AXUIElement, top: CGFloat) -> [String] {
    var lines: [String] = []
    var budget = 300
    func walk(_ element: AXUIElement, depth: Int) {
        guard budget > 0, depth <= 8 else { return }
        budget -= 1
        if let frame = axFrame(element), frame.minY - top <= 150 {
            lines.append(String(repeating: "  ", count: depth) + axSummary(element))
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement] ?? []).prefix(40) { walk(child, depth: depth + 1) }
    }
    walk(window, depth: 0)
    return lines
}

func axHasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && value != nil
}

/// 记下一个应用程序所有窗口的信息和截图，再双击最大那扇窗口的顶部，看 WindowShade 怎么处理；收起了的话，
/// 再换成简化标题栏收起一次，两种样子都截图。
func compatDump(_ name: String, appPath: String, _ h: Harness) async {
    guard let bundleID = Bundle(path: appPath)?.bundleIdentifier else {
        h.result.notes["skipped"] = "\(appPath) is not installed"
        return
    }
    run("/usr/bin/open", ["-a", appPath])
    var app: NSRunningApplication?
    _ = await eventually(30) {
        app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return app != nil
    }
    guard let app else { h.expect(false, "\(name): did not start"); return }
    await pause(15)   // 等启动画面、登录提示和首次运行的说明出完
    let pid = app.processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var cgLines: [String] = []
    for info in list where (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
        let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        cgLines.append("cg id=\(id) layer=\(layer) alpha=\(alpha) bounds=\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))x\(Int(bounds.height)) name=\(info[kCGWindowName as String] as? String ?? "")")
        if bounds.width > 40, bounds.height > 40 {
            run("/usr/sbin/screencapture", ["-x", "-o", "-l\(id)", "\(Suite.outputDir)/compat-\(name)-\(id).png"], timeout: 10)
        }
    }
    h.result.notes["cgWindows"] = cgLines

    var windowsValue: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windowsValue)
    let windows = windowsValue as? [AXUIElement] ?? []
    var axLines: [String] = []
    for window in windows {
        let buttons = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute,
                       kAXFullScreenButtonAttribute, kAXToolbarButtonAttribute]
            .map { "\($0)=\(axHasAttribute(window, $0 as String))" }.joined(separator: " ")
        axLines.append("window \(axSummary(window)) \(buttons)")
        if let frame = axFrame(window) { axLines += axTopElements(window, top: frame.minY) }
    }
    h.result.notes["axWindows"] = axLines
    for line in cgLines + axLines { log("\(name): \(line)") }

    // 最大的那扇窗口：双击顶部往下 12 点、正中附近的空白处，看 WindowShade 是否收起、卷帘条多高。
    guard let window = windows.max(by: { (axFrame($0)?.width ?? 0) * (axFrame($0)?.height ?? 0)
                                          < (axFrame($1)?.width ?? 0) * (axFrame($1)?.height ?? 0) }),
          let frame = axFrame(window) else { h.result.notes["fold"] = "no AX window"; return }
    let point = emptyTitleBarPoint(CGPoint(x: frame.midX, y: frame.minY + 12), minX: frame.minX + 80, maxX: frame.maxX - 80)
    // 收起一次：截全屏和卷帘条一带的特写（compat-名字-样子-strip.png），再双击卷帘条展开。返回有没有收起。
    func foldOnce(_ look: String) async -> Bool {
        let before = Set(compatStripWindows().map(\.id))
        await glide(to: point, duration: 0.3)
        await pause(0.3)
        await doubleClick(at: point)
        await pause(3)
        let after = compatStripWindows().filter { !before.contains($0.id) }
        let movedTo = axFrame(window)
        h.result.notes["fold-\(look)"] = "clicked=\(Int(point.x)),\(Int(point.y)) window=\(frame) after=\(movedTo.map { "\($0)" } ?? "-") "
            + "newWindowShadeWindows=\(after.map { "\($0.id):\($0.bounds)" })"
        log("\(name): fold \(look) \(h.result.notes["fold-\(look)"] ?? "")")
        run("/usr/sbin/screencapture", ["-x", "\(Suite.outputDir)/compat-\(name)-\(look)-folded.png"], timeout: 10)
        guard let strip = after.first else { return false }
        let area = strip.bounds.insetBy(dx: -12, dy: -12).offsetBy(dx: 0, dy: 20)
        run("/usr/sbin/screencapture", ["-x", "-R\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))",
                                        "\(Suite.outputDir)/compat-\(name)-\(look)-strip.png"], timeout: 10)
        await doubleClick(at: CGPoint(x: strip.bounds.midX, y: strip.bounds.minY + min(10, strip.bounds.height / 2)))
        await pause(2)
        return true
    }
    // 先按默认的“原标题栏”收起，再换成“简化标题栏”收起一次，两种样子放在一起比。
    if await foldOnce("native") {
        _ = await relaunchWindowShade([["ShadeAppearanceMode", "-string", "proxyTitleBar"]])
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        await pause(1)
        _ = await foldOnce("simplified")
        _ = await relaunchWindowShade()
    }
    kill(pid, SIGTERM)
    await pause(2)
}

/// WindowShade 自己的窗口，不限高度：其他开发者的应用程序的卷帘条可能高于 stripFrames 限定的 60 点。
func compatStripWindows() -> [(id: Int, bounds: CGRect)] {
    guard let pid = windowShadePID(),
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) < 24,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue else { return nil }
        return (id, bounds)
    }
}

let compatScenarios: [Scenario] = [
    Scenario(id: "COMPAT-texpile", title: "Texpile：记下窗口顶部，双击顶部看结果", options: [], changesSettings: true, group: "compat") { _, h in
        await compatDump("texpile", appPath: "/Applications/Texpile.app", h)
    },
    Scenario(id: "COMPAT-netease", title: "网易云音乐：记下窗口顶部，双击顶部看结果", options: [], changesSettings: true, group: "compat") { _, h in
        await compatDump("netease", appPath: "/Applications/NeteaseMusic.app", h)
    },
    Scenario(id: "COMPAT-quickrecorder", title: "QuickRecorder：记下各个面板，双击最大那扇的顶部", options: [], changesSettings: true, group: "compat") { _, h in
        await compatDump("quickrecorder", appPath: "/Applications/QuickRecorder.app", h)
    },
]

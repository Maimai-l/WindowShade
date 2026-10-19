// 别家应用程序的窗口：记下窗口顶部的样子和收起的结果，用来判断卷帘条从哪里切开、哪些窗口不该收起。
// 这些应用程序由 record.sh 在 RECORD_PART 里点到 COMPAT- 场景时装上（Homebrew）。没装上的跳过。

import AppKit
import ApplicationServices

/// 一个辅助功能元素的角色、子角色、位置大小，写进日志。
func axSummary(_ element: AXUIElement) -> String {
    let frame = axFrame(element).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "-"
    let subrole = axString(element, kAXSubroleAttribute as String)
    let title = axString(element, kAXTitleAttribute as String).prefix(30)
    return "\(axString(element, kAXRoleAttribute as String))\(subrole.isEmpty ? "" : "/" + subrole) \(frame)"
        + (title.isEmpty ? "" : " \"\(title)\"")
}

/// 窗口顶部 150 点以内的辅助功能元素，最多 300 个。
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

/// 记下一个应用程序所有窗口的信息和截图，再双击主窗口顶部看 WindowShade 怎么处理。
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
    await pause(15)   // 启动画面、登录提示、首次运行的说明
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

    // 最大的那扇窗口：双击顶部正中往下 12 点处，看 WindowShade 收没收、卷帘条多高。
    guard let window = windows.max(by: { (axFrame($0)?.width ?? 0) * (axFrame($0)?.height ?? 0)
                                          < (axFrame($1)?.width ?? 0) * (axFrame($1)?.height ?? 0) }),
          let frame = axFrame(window) else { h.result.notes["fold"] = "no AX window"; return }
    let point = emptyTitleBarPoint(CGPoint(x: frame.midX, y: frame.minY + 12), minX: frame.minX + 80, maxX: frame.maxX - 80)
    let before = Set(compatStripWindows().map(\.id))
    await glide(to: point, duration: 0.3)
    await pause(0.3)
    await doubleClick(at: point)
    await pause(3)
    let after = compatStripWindows().filter { !before.contains($0.id) }
    let movedTo = axFrame(window)
    h.result.notes["fold"] = "clicked=\(Int(point.x)),\(Int(point.y)) window=\(frame) after=\(movedTo.map { "\($0)" } ?? "-") "
        + "newWindowShadeWindows=\(after.map { "\($0.id):\($0.bounds)" })"
    log("\(name): fold \(h.result.notes["fold"] ?? "")")
    run("/usr/sbin/screencapture", ["-x", "\(Suite.outputDir)/compat-\(name)-folded.png"], timeout: 10)
    if let strip = after.first {
        await doubleClick(at: CGPoint(x: strip.bounds.midX, y: strip.bounds.minY + min(10, strip.bounds.height / 2)))
        await pause(2)
    }
    kill(pid, SIGTERM)
    await pause(2)
}

/// WindowShade 自己的窗口（不限高度）：卷帘条可能比 stripFrames 认的 60 点高。
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
    Scenario(id: "COMPAT-netease", title: "网易云音乐：记下窗口顶部，双击收起", options: [], group: "compat") { _, h in
        await compatDump("netease", appPath: "/Applications/NeteaseMusic.app", h)
    },
    Scenario(id: "COMPAT-quickrecorder", title: "QuickRecorder：记下面板，双击顶部", options: [], group: "compat") { _, h in
        await compatDump("quickrecorder", appPath: "/Applications/QuickRecorder.app", h)
    },
]

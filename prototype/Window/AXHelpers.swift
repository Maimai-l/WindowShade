// 辅助功能相关的函数：红绿灯、快速查看窗口重新打开、系统的标题栏双击设置、窗口管理能力、
// 外部唤回回调和调试输出。

import Cocoa
import Carbon.HIToolbox

// MARK: - AX 辅助

enum TrafficAction { case close, minimize, zoom, fullScreen }

enum ProxyTrafficLightStyle {
    case standard
    case quickLook
}

struct ProxyTrafficLightConfiguration {
    var closeVisible = true
    var minimizeVisible = true
    var zoomVisible = true
    var closeEnabled = true
    var minimizeEnabled = true
    var zoomEnabled = true
    var style: ProxyTrafficLightStyle = .standard

    static let standard = ProxyTrafficLightConfiguration()

    var visibleActions: [TrafficAction] {
        var actions: [TrafficAction] = []
        if closeVisible { actions.append(.close) }
        if minimizeVisible { actions.append(.minimize) }
        if zoomVisible { actions.append(style == .quickLook ? .fullScreen : .zoom) }
        return actions
    }

    var visibleSlotCount: Int {
        max(visibleActions.count, 1)
    }
}

func proxyTrafficLightConfiguration(of win: AXUIElement, pid: pid_t) -> ProxyTrafficLightConfiguration {
    let closeExists = axButtonFrame(win, kAXCloseButtonAttribute as String) != nil
    let minimizeExists = axButtonFrame(win, kAXMinimizeButtonAttribute as String) != nil
    let zoomExists = axButtonFrame(win, kAXZoomButtonAttribute as String) != nil

    // 临时出现的系统面板偶尔三个按钮都读不到：这时仍用 AppKit 的三个标准按钮，不做没有按钮的简化标题栏。
    guard closeExists || minimizeExists || zoomExists else { return .standard }

    var configuration = ProxyTrafficLightConfiguration(
        closeVisible: closeExists,
        minimizeVisible: minimizeExists,
        zoomVisible: zoomExists,
        closeEnabled: isAXButtonEnabled(win, kAXCloseButtonAttribute as String),
        minimizeEnabled: isAXButtonEnabled(win, kAXMinimizeButtonAttribute as String),
        zoomEnabled: isAXButtonEnabled(win, kAXZoomButtonAttribute as String)
    )
    if appProfile(for: pid).id == .finder,
       configuration.visibleActions.count == 2,
       firstToolbar(win) == nil {
        configuration.style = .quickLook
        configuration.closeVisible = true
        configuration.minimizeVisible = false
        configuration.zoomVisible = true
        configuration.closeEnabled = isAXButtonEnabled(win, kAXCloseButtonAttribute as String)
        configuration.minimizeEnabled = false
        configuration.zoomEnabled = isAXButtonEnabled(win, kAXFullScreenButtonAttribute as String) ||
            isAXButtonEnabled(win, kAXZoomButtonAttribute as String) ||
            isAXAttributeSettable(win, axFullScreenAttribute)
    }
    return configuration
}

func urlFromAXAttribute(_ win: AXUIElement, _ attr: String) -> URL? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, attr as CFString, &value) == .success,
          let value else { return nil }
    if let url = value as? URL, url.isFileURL {
        return url
    }
    let raw = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
        return url
    }
    if raw.hasPrefix("/") {
        return URL(fileURLWithPath: raw)
    }
    return nil
}

func quickLookReopenURL(for win: AXUIElement) -> URL? {
    for attr in ["AXDocument", "AXURL", "AXFilename"] {
        if let url = urlFromAXAttribute(win, attr),
           FileManager.default.fileExists(atPath: url.path) {
            wlog("quicklook: reopen url from \(attr) path=\(url.path)")
            return url
        }
    }
    // 访达的面板不给上面三项，只把文件名写在子元素里；到访达窗口里找名字相同的选中项（Window/QuickLookSource.swift）。
    var pid: pid_t = 0
    guard AXUIElementGetPid(win, &pid) == .success, let name = quickLookPreviewName(win) else {
        wlog("quicklook: panel shows no file name")
        return nil
    }
    var selected: [SelectedFinderItem] = []
    var budget = 1500
    for window in appWindows(pid: pid) where !CFEqual(window, win) {
        collectSelectedItems(window, depth: 0, budget: &budget, into: &selected)
        if selected.contains(where: { $0.name == name }) || budget <= 0 { break }
    }
    guard let url = quickLookSourceURL(previewName: name, selected: selected) else {
        wlog("quicklook: no selected item matches the panel selected=\(selected.count) budgetLeft=\(budget)")
        return nil
    }
    wlog("quicklook: reopen url from the selected item in the app's windows")
    return url
}

/// 面板写出的文件名：前两层子元素里第一段文字。
private func quickLookPreviewName(_ win: AXUIElement) -> String? {
    for child in axChildren(win).prefix(axTraversalMaxChildrenPerNode) {
        if axRole(child) == (kAXStaticTextRole as String), let value = axStringValue(child), !value.isEmpty { return value }
        for grandchild in axChildren(child).prefix(axTraversalMaxChildrenPerNode)
        where axRole(grandchild) == (kAXStaticTextRole as String) {
            if let value = axStringValue(grandchild), !value.isEmpty { return value }
        }
    }
    return nil
}

private func axStringValue(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}

/// 窗口里被选中、带文件网址的条目（访达的图标、列表项）。最多看 budget 个元素、10 层。
private func collectSelectedItems(_ element: AXUIElement, depth: Int, budget: inout Int,
                                  into items: inout [SelectedFinderItem]) {
    guard budget > 0, depth <= 10 else { return }
    budget -= 1
    if axBoolAttribute(element, kAXSelectedAttribute as String), let url = urlFromAXAttribute(element, "AXURL") {
        var name: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXFilename" as CFString, &name)
        items.append(SelectedFinderItem(name: (name as? String) ?? url.lastPathComponent, url: url))
        return
    }
    for child in axChildren(element).prefix(axTraversalMaxChildrenPerNode) {
        collectSelectedItems(child, depth: depth + 1, budget: &budget, into: &items)
    }
}

@discardableResult
func reopenQuickLookPreview(url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    process.arguments = ["-p", url.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        return true
    } catch {
        return false
    }
}

enum SystemTitlebarDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none
}

func systemTitlebarDoubleClickAction() -> SystemTitlebarDoubleClickAction {
    let raw = (UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Zoom")
        .lowercased()
    if raw.contains("mini") { return .minimize }
    if raw.contains("none") || raw.contains("nothing") { return .none }
    return .zoom
}

func systemTitlebarTripleClickDescription() -> String? {
    switch systemTitlebarDoubleClickAction() {
    case .zoom:
        return "三击标题栏会缩放窗口"
    case .minimize:
        return "三击标题栏会最小化窗口"
    case .none:
        return nil
    }
}

enum WindowManagementCapability {
    case none
    case zoom
    case fullScreen

    var isEnabled: Bool { self != .none }
}

func realWindowManagementCapability(_ win: AXUIElement) -> WindowManagementCapability {
    if isAXButtonEnabled(win, kAXFullScreenButtonAttribute as String) ||
        isAXAttributeSettable(win, axFullScreenAttribute) {
        return .fullScreen
    }
    if isAXButtonEnabled(win, kAXZoomButtonAttribute as String) {
        return .zoom
    }
    return .none
}

// refcon 是一个不复用的登记号，不是窗口号，也不是指针。
let axWindowCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon, Thread.isMainThread else { return }
    let routeID = UInt(bitPattern: refcon)
    let note = notification as String
    // 唯一注册这个回调的地方把它挂在主线程的 RunLoop 上。
    MainActor.assumeIsolated { appDelegate?.receiveFoldAXNotification(routeID: routeID, notification: note) }
}

// 原窗口三个标准按钮（关闭、最小化、缩放）在卷帘条里的位置：以窗口左上角为准换算，左下原点，高 barH。
func trafficLightRects(_ win: AXUIElement, winTopLeft pos: CGPoint, barH: CGFloat) -> [(CGRect, TrafficAction)] {
    let specs: [(String, TrafficAction)] = [
        (kAXCloseButtonAttribute as String, .close),
        (kAXMinimizeButtonAttribute as String, .minimize),
        (kAXZoomButtonAttribute as String, .zoom),
    ]
    return specs.compactMap { (attr, action) -> (CGRect, TrafficAction)? in
        guard let f = axButtonFrame(win, attr) else { return nil }
        let r = CGRect(x: f.minX - pos.x, y: barH - (f.minY - pos.y) - f.height, width: f.width, height: f.height)
        return (r, action)
    }
}

func trafficLightRects(_ rects: [(CGRect, TrafficAction)],
                       normalizedFor configuration: ProxyTrafficLightConfiguration) -> [(CGRect, TrafficAction)] {
    guard configuration.style == .quickLook else { return rects }
    let sorted = rects.sorted { $0.0.minX < $1.0.minX }
    var normalized: [(CGRect, TrafficAction)] = []
    if let close = sorted.first {
        let r = close.0
        normalized.append((CGRect(x: r.minX,
                                  y: (quickLookOriginalTitleBarHeight - r.height) / 2,
                                  width: r.width,
                                  height: r.height), .close))
    }
    if let fullscreen = sorted.dropFirst().last {
        let r = fullscreen.0
        normalized.append((CGRect(x: r.minX,
                                  y: (quickLookOriginalTitleBarHeight - r.height) / 2,
                                  width: r.width,
                                  height: r.height), .fullScreen))
    }
    return normalized
}

func axTitle(_ e: AXUIElement) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &v) == .success else { return "?" }
    return (v as? String) ?? "?"
}

// 把窗口及其直接子元素的 role/frame 全部打印出来，用于定位标题栏边界
func dumpWindow(_ win: AXUIElement) {
    let pos = axPosition(win) ?? .zero
    wlog("ax-window: diagnostic title=[redacted]")
    for c in axChildren(win) {
        let cp = axPosition(c) ?? .zero
        let cs = axSize(c) ?? .zero
        let relTop = cp.y - pos.y
        wlog("    child role=\(axRole(c) ?? "?") relTop=\(Int(relTop)) frame=(\(Int(cp.x)),\(Int(cp.y)) \(Int(cs.width))x\(Int(cs.height)))")
    }
}

// 应用窗口枚举（事务级备忘、并发枚举）、应用元数据与窗口显示标题。

import Cocoa

// app 当前有几个窗口（用于决定：单窗口可整体隐藏，多窗口只能最小化单个）
func appWindowCount(_ pid: pid_t) -> Int {
    appWindows(pid: pid).count
}

func appCurrentUserWindowCount(_ pid: pid_t) -> Int {
    appWindows(pid: pid).filter { win in
        guard !axBoolAttribute(win, kAXMinimizedAttribute as String) else { return false }
        guard let size = axSize(win), size.width > 40, size.height > 40 else { return false }
        guard let pos = axPosition(win) else { return true }
        return windowIsVisible(pos: pos, size: size)
    }.count
}

// Adobe AE/Premiere 的 AX 树把工作区窗口的 role 报成 AXLayoutArea（非标准），
// 但它们是货真价实的窗口（有 layer-0 CGWindow 背书）。仅对 Adobe app 放行该
// 角色，避免把其他 app 的布局容器误当窗口。
func isWindowLikeRole(_ role: String?, pid: pid_t) -> Bool {
    if role == kAXWindowRole as String { return true }
    return role == "AXLayoutArea" && isAdobeApp(pid: pid)
}

// kAXWindowsAttribute 是这条链路上最贵的一次调用：实测约 20ms，比把全系统
// 窗口列一遍（CGWindowList 全量 3.3ms）还贵 6 倍，而单个属性读只要 0.1ms。
// 计数用于定位「一次折叠到底枚举了多少遍」，只在主线程累加。
nonisolated(unsafe) var axWindowListEnumerations = 0

// 折叠内部的分段耗时累计。单次折叠每段都只有几十毫秒，逐次打日志会淹掉日志，
// 所以累计起来，按需要做差报出一次折叠的分段。
nonisolated(unsafe) var foldPhaseTotals: [String: Double] = [:]

@discardableResult
func foldPhase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    let started = CFAbsoluteTimeGetCurrent()
    defer { foldPhaseTotals[name, default: 0] += CFAbsoluteTimeGetCurrent() - started }
    return try body()
}

func foldPhaseReport() -> String {
    foldPhaseTotals.sorted { $0.value > $1.value }
        .map { "\($0.key) \(Int($0.value * 1000))ms" }
        .joined(separator: " · ")
}

// 事务级备忘，不是带 TTL 的缓存：只在显式开启的区间内生效（一次折叠/展开事务），
// 区间结束立刻丢弃。一次折叠里同一个 App 的窗口列表会被问三四遍——刷新元素、
// 找焦点继承者、数窗口数决定隐藏策略——而事务内这个列表不会变。
nonisolated(unsafe) private var appWindowsMemo: [pid_t: [AXUIElement]]?

func beginAppWindowsMemo() -> [pid_t: [AXUIElement]]? {
    guard Thread.isMainThread else { return nil }
    let outer = appWindowsMemo
    appWindowsMemo = [:]
    return outer
}

func endAppWindowsMemo(_ outer: [pid_t: [AXUIElement]]?) {
    guard Thread.isMainThread else { return }
    appWindowsMemo = outer
}

func appWindows(pid: pid_t) -> [AXUIElement] {
    if Thread.isMainThread, let cached = appWindowsMemo?[pid] { return cached }
    if Thread.isMainThread { axWindowListEnumerations += 1 }
    let app = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
          let arr = ref as? [AXUIElement] else { return [] }
    let result = arr.filter { win in
        guard isWindowLikeRole(axRole(win), pid: pid) else { return false }
        guard let id = windowID(of: win) else { return true }
        return !isDesktopWidgetWindow(id: id)
    }
    if Thread.isMainThread, appWindowsMemo != nil { appWindowsMemo?[pid] = result }
    return result
}

func runningApp(pid: pid_t) -> NSRunningApplication? {
    NSRunningApplication(processIdentifier: pid)
}

func appDisplayName(pid: pid_t) -> String {
    if let cached = WindowRegistry.shared.appInfo(pid: pid) { return cached.name }
    let app = runningApp(pid: pid)
    let name = app?.localizedName ?? "?"
    WindowRegistry.shared.cacheAppInfo(pid: pid, name: name, bundleID: app?.bundleIdentifier ?? "")
    return name
}

func appBundleID(pid: pid_t) -> String {
    if let cached = WindowRegistry.shared.appInfo(pid: pid) { return cached.bundleID }
    let app = runningApp(pid: pid)
    let bundleID = app?.bundleIdentifier ?? ""
    WindowRegistry.shared.cacheAppInfo(pid: pid, name: app?.localizedName ?? "?", bundleID: bundleID)
    return bundleID
}

func cleanDisplayTitle(_ title: String) -> String {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean == "?" ? "" : clean
}

func proxyDisplayTitle(appName: String, windowTitle: String) -> String {
    let cleanTitle = cleanDisplayTitle(windowTitle)
    return cleanTitle.isEmpty ? appName : cleanTitle
}

func descriptiveDisplayTitle(appName: String, windowTitle: String) -> String {
    let cleanTitle = cleanDisplayTitle(windowTitle)
    if cleanTitle.isEmpty { return appName }
    if cleanTitle.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                          locale: .current) ==
       appName.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                       locale: .current) {
        return appName
    }
    return "\(appName) — \(cleanTitle)"
}

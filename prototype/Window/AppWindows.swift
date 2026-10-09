// 应用程序窗口枚举（收起和展开期间的备忘）、应用程序信息与窗口显示标题。

import Cocoa

// 应用程序当前有几个窗口。
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

// Adobe After Effects、Premiere 的辅助功能树把工作区窗口的角色报成 AXLayoutArea（不标准），
// 但它们确实是窗口（窗口服务器里有对应的第 0 层窗口）。只对 Adobe 应用程序放行这个角色，
// 免得把其他应用程序的布局容器当成窗口。
func isWindowLikeRole(_ role: String?, pid: pid_t) -> Bool {
    if role == kAXWindowRole as String { return true }
    return role == "AXLayoutArea" && isAdobeApp(pid: pid)
}

// kAXWindowsAttribute 是这条链路上最贵的一次调用：实测约 20ms，比把全系统
// 窗口列一遍（CGWindowList 全量 3.3ms）还贵 6 倍，而单个属性读只要 0.1ms。
// 计数用于定位“一次收起到底枚举了多少遍”，只在主线程累加。
nonisolated(unsafe) var axWindowListEnumerations = 0

// 收起各阶段的累计耗时。一次收起每段只有几十毫秒，每次都记日志会让日志太长，
// 所以先累计，需要时做差，报出一次收起的各段耗时。
nonisolated(unsafe) var foldPhaseTotals: [String: Double] = [:]

/// 只在主线程上用（收起流程）。标成主线程：闭包和调用方同在主线程，Swift 6.0 就不会把闭包里用到的
/// 收起状态当作已转移给别的并发域（见 ShadeController.swift 的 transactionID）。
@MainActor @discardableResult
func foldPhase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    let started = CFAbsoluteTimeGetCurrent()
    defer { foldPhaseTotals[name, default: 0] += CFAbsoluteTimeGetCurrent() - started }
    return try body()
}

/// foldPhase 的不带闭包写法：调用方自己记开始时刻，做完了记一笔。闭包里要用收起状态时用它
/// （Swift 6.0 会把闭包捕获的收起状态当作已经转移出去，之后再用就报数据竞争）。
@MainActor
func foldPhaseRecord(_ name: String, since started: CFAbsoluteTime) {
    foldPhaseTotals[name, default: 0] += CFAbsoluteTimeGetCurrent() - started
}

func foldPhaseReport() -> String {
    foldPhaseTotals.sorted { $0.value > $1.value }
        .map { "\($0.key) \(Int($0.value * 1000))ms" }
        .joined(separator: " · ")
}

// 一次收起或展开期间的备忘，不是带过期时间的缓存：只在显式开启的区间内生效，
// 区间结束立刻丢弃。一次收起里同一个应用程序的窗口列表会被问三四遍——刷新元素、
// 找接手焦点的窗口、数窗口数决定隐藏策略——而这期间这个列表不会变。
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

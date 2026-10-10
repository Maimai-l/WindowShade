// AX 辅助层：AXUIElement 读写、窗口几何/ID 解析、标题栏 chrome 探测、
// 按钮/指针交互。全部为文件级函数，可跨文件引用，不持有 AppDelegate 状态。

import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import Darwin

func copyAXValue(_ element: AXUIElement, _ attr: String) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value else { return nil }
    // CF 类型在 Swift 里 `as?` 被编译器视为恒真，不能当运行时检查；
    // 先用类型 ID 校验外部返回值，再强转（此时类型已确认）。
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    return (v as! AXValue)
}

// 辅助功能的布尔属性可能是 CFBoolean，也可能是 NSNumber；两者是 toll-free 桥接的，
// 统一按 NSNumber 读 boolValue，其他类型返回 nil。
func cfBooleanValue(_ value: CFTypeRef) -> Bool? {
    (value as? NSNumber)?.boolValue
}

func axPosition(_ e: AXUIElement) -> CGPoint? {
    guard let v = copyAXValue(e, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v, .cgPoint, &p) ? p : nil
}

func axSize(_ e: AXUIElement) -> CGSize? {
    guard let v = copyAXValue(e, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v, .cgSize, &s) ? s : nil
}

func setAXPosition(_ e: AXUIElement, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) {
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v)
    }
}

@discardableResult
func setAXSize(_ e: AXUIElement, _ s: CGSize) -> AXError {
    var s = s
    guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
    return AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v)
}

@discardableResult
func setAXPositionReturningError(_ e: AXUIElement, _ p: CGPoint) -> AXError {
    var p = p
    guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
    return AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v)
}

@discardableResult
func setAXMinimizedReturningError(_ e: AXUIElement, _ v: Bool) -> AXError {
    AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString,
                                 (v ? kCFBooleanTrue : kCFBooleanFalse))
}

func setAXMinimized(_ e: AXUIElement, _ v: Bool) {
    _ = setAXMinimizedReturningError(e, v)
}

@discardableResult
func setAXAppHidden(pid: pid_t, _ hidden: Bool) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    let value: CFTypeRef = (hidden ? kCFBooleanTrue : kCFBooleanFalse)!
    let ok = AXUIElementSetAttributeValue(app, kAXHiddenAttribute as CFString, value) == .success
    // 每一次隐藏、取消隐藏都记下来：场景里应用程序“不知被谁隐藏”时，日志能说清是不是 WindowShade。
    wlog("ax: app hidden=\(hidden) pid=\(pid) ok=\(ok)")
    return ok
}

func axBoolAttribute(_ e: AXUIElement, _ attr: String) -> Bool {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success,
          let value = ref else { return false }
    return cfBooleanValue(value) ?? false
}

func isAXSizeSettable(_ e: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(e, kAXSizeAttribute as CFString, &settable) == .success else {
        return false
    }
    return settable.boolValue
}

func isAXAttributeSettable(_ e: AXUIElement, _ attr: String) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(e, attr as CFString, &settable) == .success else {
        return false
    }
    return settable.boolValue
}

func allowsProxyHorizontalResize(_ win: AXUIElement, pid: pid_t) -> Bool {
    guard appProfile(for: pid).stripResizable else { return false }
    return isAXSizeSettable(win)
}

func axButtonElement(_ win: AXUIElement, _ attr: String) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, attr as CFString, &ref) == .success,
          let button = ref else { return nil }
    guard CFGetTypeID(button) == AXUIElementGetTypeID() else { return nil }
    return (button as! AXUIElement)
}

func isAXButtonEnabled(_ win: AXUIElement, _ attr: String) -> Bool {
    guard let button = axButtonElement(win, attr),
          let p = axPosition(button),
          let s = axSize(button),
          s.width > 0, s.height > 0,
          p.x.isFinite, p.y.isFinite else { return false }

    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &ref) == .success,
       let value = ref {
        return cfBooleanValue(value) ?? false
    }
    return true
}

func axButtonFrame(_ win: AXUIElement, _ attr: String) -> CGRect? {
    guard let btn = axButtonElement(win, attr) else { return nil }
    guard let p = axPosition(btn), let s = axSize(btn) else { return nil }
    return CGRect(origin: p, size: s)
}

@discardableResult
func pressAXButton(_ win: AXUIElement, _ attr: String) -> Bool {
    guard let button = axButtonElement(win, attr) else { return false }
    return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
}

func cocoaMousePoint(fromAXPoint p: CGPoint) -> CGPoint {
    CGPoint(x: p.x, y: coordinateBaselineY() - p.y)
}

func raiseAXWindow(_ win: AXUIElement) {
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
}

func focusAXWindow(_ win: AXUIElement, pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, win)
    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}

/// 露出一块看得见的部分才算可见；停在屏幕角上只剩一像素的窗口不算（见 Core/CornerParking.swift）。
func windowIsVisible(pos: CGPoint, size: CGSize) -> Bool {
    let winRect = cocoaFrame(fromAXPosition: pos, size: size)
    return rectIsVisible(winRect, onScreens: NSScreen.screens.map(\.frame))
}

/// 卷帘条还在可操作的范围内：某块屏幕的可用区域里露出它完整的高度和至少 120 点宽（整条不到 120 点时要求整条）。
/// 原来的窗口就伸出屏幕边时，卷帘条跟着伸出去是对的，不用拉回来。
func overlayIsReachable(_ frame: NSRect) -> Bool {
    let needWidth = min(frame.width, 120)
    return NSScreen.screens.contains { screen in
        let overlap = screen.visibleFrame.intersection(frame)
        return !overlap.isNull && overlap.width >= needWidth && overlap.height >= frame.height - 1
    }
}

func cgWindowIsVisible(id: CGWindowID, fallbackSize: CGSize) -> Bool? {
    guard let info = cgWindowInfo(id), let bounds = cgWindowBounds(info) else { return nil }
    let size = bounds.size.width > 0 && bounds.size.height > 0 ? bounds.size : fallbackSize
    let axPos = CGPoint(x: bounds.minX, y: bounds.minY)
    return windowIsVisible(pos: axPos, size: size)
}

func currentOnScreenWindowIDs() -> Set<CGWindowID> {
    WindowListCache.shared.onScreenIDs()
}

func cgWindowIsCurrentlyOnScreen(_ id: CGWindowID) -> Bool {
    WindowListCache.shared.isOnScreen(id)
}

/// 实时问 WindowServer（不走 150ms 缓存）：这扇窗此刻是否在屏幕上。
/// 用于“藏好了没有 / 回来了没有”这类必须看到当下状态的判断。
func windowIsOnScreenNow(_ id: CGWindowID) -> Bool {
    (cgWindowInfo(id)?[kCGWindowIsOnscreen as String] as? Bool) == true
}

func focusedWindow() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    var win: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
          let w = win else { return nil }
    guard CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
    return (w as! AXUIElement)
}

func cgWindowBounds(_ info: [String: Any]) -> CGRect? {
    guard let raw = info[kCGWindowBounds as String] else { return nil }
    var rect = CGRect.zero
    // CFDictionary 与 NSDictionary toll-free 桥接，as? 是真实运行时检查。
    guard let dict = raw as? NSDictionary else { return nil }
    return CGRectMakeWithDictionaryRepresentation(dict, &rect) ? rect : nil
}

func cocoaFrame(fromWindowServerBounds bounds: CGRect) -> NSRect {
    cocoaFrame(fromAXPosition: CGPoint(x: bounds.minX, y: bounds.minY), size: bounds.size)
}

func cgWindowName(_ info: [String: Any]) -> String {
    (info[kCGWindowName as String] as? String) ?? ""
}

func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
    abs(a.minX - b.minX) + abs(a.minY - b.minY) +
    abs(a.width - b.width) + abs(a.height - b.height)
}

func publicWindowID(of e: AXUIElement) -> CGWindowID? {
    guard let pos = axPosition(e), let size = axSize(e) else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(e, &pid) == .success, pid > 0 else { return nil }

    let axFrame = CGRect(origin: pos, size: size)
    let title = cleanDisplayTitle(axTitle(e))
    // 在所有桌面的窗口里比，透明窗口也算：原窗口被隐藏或不在当前桌面时，不能因此选中另一扇可见的窗口。
    let candidates = WindowListCache.shared.allWindows(ofPID: pid).filter { info in
        guard let bounds = cgWindowBounds(info) else { return false }
        return frameDistance(bounds, axFrame) <= 96
    }
    // 按几何位置匹配只是兼容做法：不止一扇窗口位置相近时，前后顺序说明不了是哪一扇。
    guard candidates.count == 1, let info = candidates.first,
          let number = info[kCGWindowNumber as String] as? NSNumber,
          number.uint32Value != 0 else { return nil }
    let name = cleanDisplayTitle(cgWindowName(info))
    guard title.isEmpty || name.isEmpty || title == name else { return nil }
    return number.uint32Value
}

func windowID(of e: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    let error = _AXUIElementGetWindow(e, &id)
    if error == .success, id != 0 { return id }
    // 有些辅助功能窗口一切正常，却报告成功并给出 0。这种情况仍走兼容匹配：
    // publicWindowID 只接受唯一一扇、标题相符的窗口，不会悄悄换成另一扇。
    if error == .success { return publicWindowID(of: e) }
    // 读取失败或元素已失效时，不能用外形相似的窗口代替。
    guard error != .invalidUIElement, error != .cannotComplete else { return nil }
    return publicWindowID(of: e)
}

func axRole(_ e: AXUIElement) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success else { return nil }
    return v as? String
}

func axSubrole(_ e: AXUIElement) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &v) == .success else { return nil }
    return v as? String
}

// 从“点中的元素”往上找它所属的窗口
func containingWindow(_ el: AXUIElement) -> AXUIElement? {
    if axRole(el) == (kAXWindowRole as String) { return el }
    var winRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef) == .success,
       let w = winRef {
        guard CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (w as! AXUIElement)
    }
    return nil
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
          let arr = ref as? [AXUIElement] else { return [] }
    return arr
}

// 在窗口里找工具栏（含浅层递归），用于量出真实的标题栏+工具栏高度
func firstToolbar(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 2 { return nil }
    // 工具栏几乎总在子列表最前，前缀截断只为挡住极端 AX 树（数千子节点的窗口）。
    let kids = axChildren(el).prefix(axTraversalMaxChildrenPerNode)
    for c in kids where axRole(c) == (kAXToolbarRole as String) { return c }
    for c in kids { if let t = firstToolbar(c, depth: depth + 1) { return t } }
    return nil
}

func isChromeControlRole(_ role: String?) -> Bool {
    switch role ?? "" {
    case "AXButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXSearchField",
         "AXComboBox", "AXCheckBox", "AXRadioButton", "AXSlider", "AXSegmentedControl",
         "AXTabGroup", "AXRadioGroup", "AXDisclosureTriangle", "AXImage", "AXLink":
        return true
    default:
        return false
    }
}

// 双击、三击标题栏时，哪些控件自己要用双击：地址栏和输入框（双击选词）、按钮、滑块等，
// 点在它们上面时不收起。标签和标签条除外：Safari 等浏览器双击标签没有反应（2026-07 实测），
// 而标签条所在位置就是标题栏，所以照常收起。点击位置还要通过 titlebarContains 的标题栏范围检查，
// 对话框内容区里的单选按钮不会触发收起。
func stealsTitlebarDoubleClick(_ role: String?) -> Bool {
    switch role ?? "" {
    case "AXRadioButton", "AXTabGroup", "AXRadioGroup":
        return false
    default:
        return isChromeControlRole(role)
    }
}

struct TopChromeControlSample {
    let minTop: CGFloat
    let maxBottom: CGFloat
}

func collectTopChromeControlSamples(_ el: AXUIElement, winTop: CGFloat, winSize: CGSize,
                                    ignoredFrames: [CGRect] = [],
                                    depth: Int = 0, scanLimit: CGFloat = 120,
                                    nodeBudget: inout Int,
                                    into samples: inout [TopChromeControlSample]) {
    if depth > 6 || nodeBudget <= 0 { return }
    nodeBudget -= 1
    if isChromeControlRole(axRole(el)), let p = axPosition(el), let s = axSize(el) {
        let relTop = p.y - winTop
        let relBottom = relTop + s.height
        let frame = CGRect(origin: p, size: s)
        let ignored = ignoredFrames.contains { $0.insetBy(dx: -3, dy: -3).contains(CGPoint(x: frame.midX, y: frame.midY)) }
        let sane = s.width >= 4 && s.width <= winSize.width + 8 && s.height >= 4 && s.height <= 80 &&
                   relTop >= -4 && relTop <= scanLimit && relBottom <= scanLimit + 40
        if sane && !ignored {
            samples.append(TopChromeControlSample(minTop: max(0, relTop), maxBottom: relBottom))
        }
    }

    // 每节点最多展开前 40 个子节点：顶部 chrome 控件（红绿灯、搜索框、工具栏
    // 按钮）几乎总在子列表最前，越界展开只会把预算浪费在内容区深层节点上。
    for c in axChildren(el).prefix(axTraversalMaxChildrenPerNode) {
        collectTopChromeControlSamples(c, winTop: winTop, winSize: winSize,
                                       ignoredFrames: ignoredFrames,
                                       depth: depth + 1, scanLimit: scanLimit,
                                       nodeBudget: &nodeBudget,
                                       into: &samples)
    }
}

func firstTopChromeControlCluster(of win: AXUIElement, winTop: CGFloat, winSize: CGSize,
                                  ignoredFrames: [CGRect] = [],
                                  scanLimit: CGFloat = 120) -> TopChromeControlSample? {
    var samples: [TopChromeControlSample] = []
    var nodeBudget = axTraversalNodeBudget
    collectTopChromeControlSamples(win, winTop: winTop, winSize: winSize,
                                   ignoredFrames: ignoredFrames,
                                   scanLimit: scanLimit,
                                   nodeBudget: &nodeBudget,
                                   into: &samples)
    guard !samples.isEmpty else { return nil }

    samples.sort {
        if abs($0.minTop - $1.minTop) > 0.5 { return $0.minTop < $1.minTop }
        return $0.maxBottom < $1.maxBottom
    }

    let gap: CGFloat = 8
    var clusters: [TopChromeControlSample] = []
    var current = samples[0]
    for sample in samples.dropFirst() {
        if sample.minTop <= current.maxBottom + gap {
            current = TopChromeControlSample(minTop: min(current.minTop, sample.minTop),
                                             maxBottom: max(current.maxBottom, sample.maxBottom))
        } else {
            clusters.append(current)
            current = sample
        }
    }
    clusters.append(current)

    return clusters.first
}

// 自绘或没有工具栏的窗口，常把搜索框、标题、按钮放在 AXSplitGroup、AXGroup 里面。
// 顶部确实有控件时，保留到控件底边，再补一段和顶部留白相当的下边距（4–28 点），不截断控件。
func topChromeControlsHeight(of win: AXUIElement, winTop: CGFloat, winSize: CGSize,
                             titleBarBottom: CGFloat?,
                             allowBelowTitleBar: Bool = false) -> CGFloat? {
    let ignored = standardTrafficButtonFrames(of: win)
    guard let e = firstTopChromeControlCluster(of: win, winTop: winTop, winSize: winSize,
                                               ignoredFrames: ignored) else { return nil }
    if let titleBarBottom = titleBarBottom, !allowBelowTitleBar, e.minTop >= titleBarBottom - 2 {
        return nil
    }
    if allowBelowTitleBar, let titleBarBottom = titleBarBottom {
        let maxChromeStart = max(titleBarBottom + 44, CGFloat(76))
        if e.minTop > maxChromeStart { return nil }
    }
    return paddedChromeHeight(for: e, containerTop: 0)
}

func paddedChromeHeight(for e: TopChromeControlSample, containerTop: CGFloat) -> CGFloat {
    let topPadding = max(0, e.minTop - containerTop)
    let bottomPadding = max(4, min(topPadding, 28))
    return e.maxBottom + bottomPadding
}

func standardTrafficButtonFrames(of win: AXUIElement) -> [CGRect] {
    [
        kAXCloseButtonAttribute as String,
        kAXMinimizeButtonAttribute as String,
        kAXZoomButtonAttribute as String,
    ].compactMap { axButtonFrame(win, $0) }
}

func hasContentControlsBelowTitleBar(_ win: AXUIElement, winTop: CGFloat, winSize: CGSize,
                                     titleBarBottom: CGFloat?) -> Bool {
    guard let titleBarBottom = titleBarBottom else { return false }
    let ignored = standardTrafficButtonFrames(of: win)
    guard let e = firstTopChromeControlCluster(of: win, winTop: winTop, winSize: winSize,
                                               ignoredFrames: ignored) else { return false }
    return e.minTop >= titleBarBottom - 2
}

// 用原生红绿灯按钮推算标题栏高度：红绿灯在标题栏里垂直居中，
// 所以 高度 ≈ 2 ×（按钮中心到窗口顶的距离）。Electron 等自绘标题栏也适用，
// 因为红绿灯始终是 macOS 原生绘制、AX 可读。
func trafficLightHeight(of win: AXUIElement, winTop: CGFloat) -> CGFloat? {
    guard let btn = axButtonElement(win, kAXCloseButtonAttribute as String) else { return nil }
    guard let bp = axPosition(btn), let bs = axSize(btn) else { return nil }
    let centerY = bp.y + bs.height / 2
    return (centerY - winTop) * 2
}

func trafficLightPaddedHeight(of win: AXUIElement, winTop: CGFloat) -> CGFloat? {
    let frames = standardTrafficButtonFrames(of: win)
    guard !frames.isEmpty else { return nil }
    let top = max(0, frames.map { $0.minY - winTop }.min() ?? 0)
    let bottom = max(0, frames.map { $0.maxY - winTop }.max() ?? 0)
    return bottom + min(top, 28)
}

// 收起后保留的标题栏高度：固定高度、Adobe、只要标准标题栏的窗口各有各的规则；
// 其余取默认值、红绿灯推算、工具栏底边、顶部控件四者中最大的，最多 300 点。
// 宁可多保留一点，也不切断标题栏。
func chromeHeight(of win: AXUIElement, winTop: CGFloat, winSize: CGSize? = nil, pid: pid_t? = nil) -> CGFloat {
    let trafficH = trafficLightPaddedHeight(of: win, winTop: winTop) ??
                   trafficLightHeight(of: win, winTop: winTop)
    if let pid = pid, let fixed = fixedNonstandardChromeHeight(pid: pid) {
        return min(max(titleBarHeight, fixed), winSize?.height ?? fixed)
    }
    if let pid = pid, isAdobeApp(pid: pid) {
        let profile = adobeChromeProfile(for: win, pid: pid, size: winSize)
        let adobeH = max(profile.preservedChromeHeight, trafficH ?? titleBarHeight)
        return min(adobeH, min(winSize?.height ?? adobeH, 300))
    }
    if let pid = pid, let winSize = winSize,
       usesStandardTitleBarOnly(pid: pid) ||
        windowLooksToolbarlessStandardTitleBar(win,
                                               winTop: winTop,
                                               winSize: winSize,
                                               pid: pid,
                                               trafficLightHeight: trafficH) {
        return standardTitleBarCropHeight(of: win, winTop: winTop, winSize: winSize)
    }
    if pid.map({ usesStandardTitleBarOnly(pid: $0) }) ?? false {
        return min(trafficH ?? titleBarHeight, 300)
    }

    var h = titleBarHeight
    if let bh = trafficH { h = max(h, bh) }
    if let winSize = winSize, let pid = pid, needsControlPaddedChrome(pid: pid),
       let controlsH = topChromeControlsHeight(of: win, winTop: winTop, winSize: winSize,
                                               titleBarBottom: trafficH,
                                               allowBelowTitleBar: true) {
        return min(max(h, controlsH), min(winSize.height, 300))
    }

    let toolbar = firstToolbar(win)
    if let tb = toolbar, let tp = axPosition(tb), let ts = axSize(tb) {
        h = max(h, (tp.y + ts.height) - winTop)
    }
    if toolbar == nil, let winSize = winSize,
       let controlsH = topChromeControlsHeight(of: win, winTop: winTop, winSize: winSize,
                                               titleBarBottom: trafficH,
                                               allowBelowTitleBar: pid.map { isElpass(pid: $0) } ?? false) {
        h = max(h, controlsH)
    }
    return min(h, 300)
}

func titlebarHitHeight(of win: AXUIElement, id: CGWindowID,
                       winTop: CGFloat, winSize: CGSize, pid: pid_t) -> CGFloat {
    // 双击判定的第一下已解析过完整 profile 的话，第二下直接取缓存，不再重跑
    // 整棵 AX 子树的 chrome 计算（cache 按元素身份 + 窗口尺寸校验新鲜度）。
    if let cached = ChromeProfileCache.shared.cachedHitBarHeight(id: id, win: win, size: winSize) {
        return cached
    }
    return measuredTitlebarHitHeight(of: win, winTop: winTop, winSize: winSize, pid: pid)
}

/// 不看缓存、当场量。只有辅助功能查询，不读写 ChromeProfileCache，可以在后台线程上做。
func measuredTitlebarHitHeight(of win: AXUIElement, winTop: CGFloat, winSize: CGSize, pid: pid_t) -> CGFloat {
    let visualHeight = chromeHeight(of: win, winTop: winTop, winSize: winSize, pid: pid)
    if isAdobeApp(pid: pid) {
        let profile = adobeChromeProfile(for: win, pid: pid, size: winSize)
        return min(max(visualHeight, profile.hitChromeHeight), min(winSize.height, 300))
    }
    return visualHeight
}

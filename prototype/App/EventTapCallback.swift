// 全局鼠标事件钩子（CGEventTap）的 C 回调与标题栏带预过滤。

import Cocoa

// MARK: - 全局鼠标事件钩子（CGEventTap）

// 钩子回调里的快速预过滤：只用窗口服务器的数据，判断点击位置是否可能落在某个屏幕上窗口的标题栏带内。
// 窗口服务器查询不依赖目标应用程序是否响应；辅助功能命中测试则是对目标应用程序的同步进程间调用，
// 回调等待期间全系统的鼠标事件都在排队。
// 带高取窗口高度和 300 点中较小的一个，宁可多放过（返回 true，走完整判断），也不漏掉标题栏上的双击；
// 内容区的双击因此不再做辅助功能查询。
func pointMayLieInTitlebarBand(_ point: CGPoint) -> Bool {
    let windows = WindowListCache.shared.onScreenWindows()
    let maxTitlebarBand: CGFloat = 300
    for info in windows {
        guard let bounds = cgWindowBounds(info) else { continue }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0, bounds.contains(point) else { continue }
        if point.y <= bounds.minY + min(maxTitlebarBand, bounds.height) { return true }
    }
    return false
}

/// 标题栏命中测试最多等多久（秒）。双击、三击的判定在主线程上，而且钩子线程最多等 TapDecision.deadline；
/// 应用程序没有响应时这一次就要放弃，不能等满 axMessagingTimeout（I6）。
let titlebarHitTestTimeout: Float = 0.3

/// 点下面的元素。只问这个点上最前面那扇普通窗口所属的应用程序，最多等 titlebarHitTestTimeout；
/// 程序坞、菜单栏等系统层级不算：它们不接点击，问它们只会立即出错（CI 场景 A03）。
/// 前后顺序现查，不用缓存：应用程序问的是它自己的窗口，不管被谁挡着，问错了应用程序，标题栏上的双击就被当成
/// 别处的双击放行，系统把窗口放大（CI 场景 B16：刚展开的窗口到了前面，缓存里前面还是文本编辑）。
/// 点在 WindowShade 自己的窗口上、找不到窗口，或者应用程序很快就返回错误（它在响应，只是不支持这样问）时，
/// 照旧问系统级元素。
/// timedOut：等满时限还没有回答，说明应用程序没有响应。
func titlebarHitTest(at point: CGPoint) -> (error: AXError, element: AXUIElement?, timedOut: Bool) {
    let owner = ordinaryWindowOwner(at: point, in: WindowListCache.shared.onScreenWindowsNow())
    var element: AXUIElement?
    if let owner, owner != getpid() {
        let app = AXUIElementCreateApplication(owner)
        AXUIElementSetMessagingTimeout(app, titlebarHitTestTimeout)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element)
        if error == .success { return (error, element, false) }
        if error == .cannotComplete,
           CFAbsoluteTimeGetCurrent() - startedAt >= Double(titlebarHitTestTimeout) * 0.9 {
            return (error, nil, true)
        }
        element = nil
    }
    let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
    return (error, element, false)
}

/// 按下鼠标的钩子（主动钩子，能拦下事件），在自己的线程上运行：WindowShade 的主线程等某个响应慢的应用程序
/// 回答辅助功能查询时（实测几百毫秒），全系统的单击不必跟着排队。单击直接放行；只有双击、三击才问主线程
/// 要不要拦下（标题栏双击收起、三击执行系统的双击标题栏动作，本来就要问那个应用程序），而且最多等 TapDecision.deadline。
nonisolated(unsafe) var mouseDownTapPort: CFMachPort?

/// 拦下了一次按下，就把跟它配对的那次松开也拦下：macOS 26 起，系统在第二次松开时执行“双击标题栏缩放”，
/// 只吞按下的话窗口照样被放大，卷帘条截到的就是放大后的窗口。只在钩子线程上读写。
nonisolated(unsafe) private var swallowNextMouseUp = false

func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // 钩子超时被系统停用：立即重新启用。
    if type == .tapDisabledByTimeout {
        if let tap = mouseDownTapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // 输入过多导致的停用：马上重新启用会被系统反复停用，1.5 秒后再恢复。
    if type == .tapDisabledByUserInput {
        DispatchQueue.main.async { MainActor.assumeIsolated { appDelegate?.scheduleEventTapReenable(delay: 1.5) } }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseUp {
        guard swallowNextMouseUp else { return Unmanaged.passUnretained(event) }
        swallowNextMouseUp = false
        return nil
    }
    guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
    swallowNextMouseUp = false
    let clickState = event.getIntegerValueField(.mouseEventClickState)
    guard clickState >= 2 else { return Unmanaged.passUnretained(event) }   // 单击：不问主线程
    let location = event.location
    let decision = TapDecision()
    DispatchQueue.main.async {
        guard decision.begin() else { return }
        let swallow = MainActor.assumeIsolated { () -> Bool in
            guard let delegate = appDelegate else { return false }
            if clickState >= 3 {
                return delegate.handleTitleBarTripleClick(at: location, clickCount: clickState)
            }
            return delegate.handleTitleBarDoubleClick(at: location)   // 拦下，阻止系统“双击缩放”
        }
        decision.finish(swallow: swallow)
    }
    // 有固定时限（见 Core/TapDecision.swift）：超时就放行，不会一直等主线程。
    let swallow = decision.waitForSwallow()
    if decision.isAbandoned {
        // 写日志可能要等文件锁：不在钩子线程上写。
        DispatchQueue.global(qos: .utility).async { wlog("event-tap: main thread did not answer in time; click passed through") }
    }
    guard swallow else { return Unmanaged.passUnretained(event) }
    swallowNextMouseUp = true
    return nil
}

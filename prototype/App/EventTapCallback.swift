// 全局鼠标事件钩子（CGEventTap）的 C 回调与标题栏带预过滤。

import Cocoa

// MARK: - 全局鼠标事件钩子（CGEventTap）

// tap 回调内的廉价预过滤：只用 WindowServer 数据判断点击点是否可能落在某个
// 在屏窗口的标题栏带内。WindowServer 查询不依赖目标 app 是否响应；而 AX 命中
// 测试是到目标 app 的同步 IPC，回调阻塞期间全系统鼠标事件都在排队。
// 带高取 chromeHeight 的硬上限 300pt，宁可放过（返回 true 走原有完整路径），
// 不可错杀；因此命中标题栏的行为与过去完全一致，只是内容区双击不再付 AX 成本。
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
/// 应用程序卡住时这一次就要放弃，不能等满 axMessagingTimeout（I6）。
let titlebarHitTestTimeout: Float = 0.3

/// 点下面的元素。只问这个点上最前面那扇窗口所属的应用程序，最多等 titlebarHitTestTimeout；
/// 点在 WindowShade 自己的窗口上或找不到窗口时，照旧问系统级元素。
/// timedOut：等满了时限还没有回答，应用程序卡住了。很快就返回错误的应用程序在响应，只是不支持命中测试。
func titlebarHitTest(at point: CGPoint) -> (error: AXError, element: AXUIElement?, timedOut: Bool) {
    let owner = WindowListCache.shared.onScreenWindows().first { info in
        guard let bounds = cgWindowBounds(info), bounds.contains(point) else { return false }
        return ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
    }.flatMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
    let target: AXUIElement
    if let owner, owner != getpid() {
        target = AXUIElementCreateApplication(owner)
        AXUIElementSetMessagingTimeout(target, titlebarHitTestTimeout)
    } else {
        target = AXUIElementCreateSystemWide()
    }
    var element: AXUIElement?
    let startedAt = CFAbsoluteTimeGetCurrent()
    let error = AXUIElementCopyElementAtPosition(target, Float(point.x), Float(point.y), &element)
    let waited = CFAbsoluteTimeGetCurrent() - startedAt
    return (error, element, error == .cannotComplete && waited >= Double(titlebarHitTestTimeout) * 0.9)
}

/// 按下鼠标的钩子（主动钩子，能吞事件）。它跑在自己的线程上：WindowShade 的主线程在等某个慢吞吞的 App
/// 回答辅助功能查询时（实测几百毫秒），全系统的单击不再跟着排队。单击直接放行；只有双击、三击才问主线程
/// 要不要吞掉（标题栏双击收起、三击铺满本来就要问那个 App），而且最多等 TapDecision.deadline。
nonisolated(unsafe) var mouseDownTapPort: CFMachPort?

/// 吞掉了一次按下，就把跟它配对的那次松开也吞掉：macOS 26 起，系统在第二次松开时执行“双击标题栏缩放”，
/// 只吞按下的话窗口照样被放大，卷帘条截到的就是放大后的窗口。只在钩子线程上读写。
nonisolated(unsafe) private var swallowNextMouseUp = false

func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // 系统在高负载时会把 tap 关掉，需要重新启用
    if type == .tapDisabledByTimeout {
        if let tap = mouseDownTapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // 输入洪泛导致的禁用：立即重启用会和系统反复打架，退避后再恢复。
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
            return delegate.handleTitleBarDoubleClick(at: location)   // 吞掉，阻止系统「双击缩放」
        }
        decision.finish(swallow: swallow)
    }
    // 有硬时限（见 Core/TapDecision.swift）：过时放行，绝不无限等主线程。
    let swallow = decision.waitForSwallow()
    if decision.isAbandoned {
        // 写日志可能要等文件锁：不在钩子线程上写。
        DispatchQueue.global(qos: .utility).async { wlog("event-tap: main thread did not answer in time; click passed through") }
    }
    guard swallow else { return Unmanaged.passUnretained(event) }
    swallowNextMouseUp = true
    return nil
}

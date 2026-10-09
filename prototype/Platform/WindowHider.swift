// 移开原窗口（docs/design.md 第 5.4 节第 7 步）：按隐藏策略依次尝试各种方式，返回实际用了哪一种。
// 底层操作经由 WindowControl 协议：App 里是辅助功能、SkyLight 和窗口服务器的调用（WindowControlSystem），
// 测试里是模拟实现（tests/support/Fakes/FakeWindowControl.swift）。可以在任意线程执行；
// “SkyLight 在本机无效”的记录和窗口原来的透明度在锁里。只依赖 Foundation，测试直接编译。

import CoreGraphics
import Foundation

/// 对一个窗口的底层操作。全部是同步调用，调用方负责放在后台线程。
protocol WindowControl: Sendable {
    func position(_ window: WindowHandle) -> CGPoint?
    func setPosition(_ window: WindowHandle, _ point: CGPoint)
    func setMinimized(_ window: WindowHandle, _ minimized: Bool)
    func pressCloseButton(_ window: WindowHandle) -> Bool
    /// 用辅助功能隐藏整个应用程序；不行时再试 NSRunningApplication.hide()。返回用了哪一种，都不行返回 nil。
    func hideApp(pid: pid_t) -> String?
    /// 该应用程序在当前屏幕上可见、未最小化、不小于 40 点的窗口数，以及全部窗口数。
    func windowCounts(pid: pid_t, layout: ScreenLayout) -> (visible: Int, total: Int)
    var skyLightMoveAvailable: Bool { get }
    var skyLightAlphaAvailable: Bool { get }
    func skyLightMove(id: CGWindowID, to point: CGPoint) -> Bool
    func skyLightAlpha(id: CGWindowID) -> Float?
    func skyLightSetAlpha(id: CGWindowID, _ alpha: Float) -> Bool
    /// 窗口服务器记录的窗口范围（辅助功能坐标）；取不到时 nil。
    func windowServerBounds(id: CGWindowID) -> CGRect?
    func log(_ message: String)
}

/// 交给 WindowControl 的窗口：App 里装着 AXUIElement，测试里装着模拟窗口的编号。
struct WindowHandle: @unchecked Sendable {
    let element: AnyObject
}

/// 一次移开所需的全部输入。
struct HideRequest: Sendable {
    let window: WindowHandle
    let id: CGWindowID?
    let pid: pid_t
    let position: CGPoint
    let size: CGSize
    let policy: ShadePolicy
    /// 交出焦点之后，隐藏整个应用程序不会让系统切换桌面（见 FoldTransaction.handOffFocus）。
    let appHideSafe: Bool
    let layout: ScreenLayout
    /// 同一应用程序里已被 WindowShade 收起的其他窗口数。不为 0 时不隐藏整个应用程序：
    /// 之后展开其中任何一扇，应用程序都会重新显示，这一扇会被当成用户唤回而跟着展开（场景 A37）。
    var otherFoldedWindows = 0
    /// 交出焦点时当前桌面上没有可以接手的窗口（FocusHandoff 返回 .nowhere）。
    var noFocusHeir = false
}

/// 移到屏幕外时第一个试的位置（其余几个见 offscreenSpots）。
let offscreenParkingPoint = CGPoint(x: -32000, y: -32000)

final class WindowHider: @unchecked Sendable {
    private let control: WindowControl
    private let lock = NSLock()
    private var skyLightMoveIneffective: Bool
    private var skyLightAlphaIneffective: Bool
    private var alphaOriginals: [CGWindowID: Float] = [:]
    /// 第一次确认 SkyLight 无效时调用（App 里写进偏好，系统版本不变就不再试）。
    private let rememberIneffective: @Sendable (String) -> Void

    init(control: WindowControl, skyLightMoveIneffective: Bool = false, skyLightAlphaIneffective: Bool = false,
         rememberIneffective: @escaping @Sendable (String) -> Void = { _ in }) {
        self.control = control
        self.skyLightMoveIneffective = skyLightMoveIneffective
        self.skyLightAlphaIneffective = skyLightAlphaIneffective
        self.rememberIneffective = rememberIneffective
    }

    var knownSkyLightMoveIneffective: Bool { lock.withLock { skyLightMoveIneffective } }
    var knownSkyLightAlphaIneffective: Bool { lock.withLock { skyLightAlphaIneffective } }

    /// 用 SkyLight 设成透明的窗口原来的透明度；展开时按它恢复。
    func originalAlpha(id: CGWindowID) -> Float? { lock.withLock { alphaOriginals[id] } }
    /// 取出并删掉。
    func takeOriginalAlpha(id: CGWindowID) -> Float? { lock.withLock { alphaOriginals.removeValue(forKey: id) } }

    func hide(_ request: HideRequest) -> HideMethod {
        let pid = request.pid
        switch request.policy {
        case .closeQuickLookPreview:
            if control.pressCloseButton(request.window) {
                control.log("    quicklook → closed via AX close（pid=\(pid)）")
                return .quickLookClosed
            }
            control.log("    quicklook close rejected; fallback offscreen（pid=\(pid)）")
            return fallbackHide(request, allowAppHide: false)
        case .hiddenIfSingleWindowElseMinimized(let allowAppHide):
            return fallbackHide(request, allowAppHide: allowAppHide && request.appHideSafe)
        case .offscreenForLivePreview:
            for spot in offscreenSpots(request.position) {
                control.setPosition(request.window, spot)
                if let moved = control.position(request.window), !request.layout.isVisible(pos: moved, size: request.size) {
                    control.log("    live preview parking → offscreen（pid=\(pid), pos=(\(Int(moved.x)),\(Int(moved.y))))")
                    return .offscreen
                }
            }
            control.setPosition(request.window, request.position)
            control.log("    live preview parking failed; fallback to app-hide when single-window（pid=\(pid)）")
            return fallbackHide(request, allowAppHide: request.appHideSafe)
        case .offscreenThenFallback(let allowAppHide):
            if allowAppHide && request.appHideSafe && request.otherFoldedWindows == 0
                && control.windowCounts(pid: pid, layout: request.layout).visible <= 1 {
                control.log("    single-window app → prefer hide fallback（pid=\(pid)）")
                return fallbackHide(request, allowAppHide: true)
            }
            if let hide = offscreenHide(request) { return hide }
            // 被系统限制回可见区。不记成“这个应用程序移不出去”：能不能移出屏幕取决于窗口大小、
            // 位置和显示器布局，下次仍先试移到屏幕外——它比最小化更接近“收起”。
            let hide = fallbackHide(request, allowAppHide: allowAppHide && request.appHideSafe)
            control.log("    挪屏外被钳制 → \(hide)（pid=\(pid), allowAppHide=\(allowAppHide && request.appHideSafe)）")
            return hide
        }
    }

    /// 可安全整体隐藏时隐藏整个应用程序；当前桌面上没有窗口能接手焦点、原窗口又是应用程序唯一的窗口时直接最小化；
    /// 否则依次试 SkyLight 移到屏幕外、SkyLight 透明、停到屏幕角上，最后才最小化。
    /// 隐藏整个应用程序只在它没有其他可见窗口时使用：产品语义仍是“收起这一个窗口”。
    func fallbackHide(_ request: HideRequest, allowAppHide: Bool) -> HideMethod {
        let pid = request.pid
        let counts = control.windowCounts(pid: pid, layout: request.layout)
        if allowAppHide && counts.visible <= 1 && request.otherFoldedWindows > 0 {
            control.log("    fallback hidden skipped: \(request.otherFoldedWindows) other windows of this app are folded（pid=\(pid)）")
        }
        if allowAppHide && counts.visible <= 1 && request.otherFoldedWindows == 0 {
            if let how = control.hideApp(pid: pid) {
                control.log("    fallback → hidden via \(how)（pid=\(pid), currentWindows=\(counts.visible), windows=\(counts.total)）")
                return .hidden
            }
            control.log("    fallback hidden rejected（pid=\(pid), currentWindows=\(counts.visible), windows=\(counts.total)）")
        }
        // 当前桌面上没有窗口能接手焦点，而这是应用程序唯一的窗口：直接最小化。移到屏幕外、设成透明或停到角落时，
        // 应用程序仍在前台、窗口仍算“开着”，点程序坞图标、选“窗口”菜单都不会让它回来；最小化之后，
        // 这两种操作都会取消最小化，WindowShade 跟着展开（场景 B06-alone）。应用程序有别的窗口时不这样做：
        // 最小化当前窗口，系统会让同一应用程序的另一扇窗口接手，那扇窗口在别的桌面上时，系统会切换桌面。
        if request.noFocusHeir && counts.total <= 1 {
            control.setMinimized(request.window, true)
            control.log("    no window on this desktop takes focus → minimized（pid=\(pid), windows=\(counts.total)）")
            return .minimized
        }
        if let id = request.id, let hide = skyLightOffscreenHide(request, id: id) { return hide }
        if let id = request.id, let hide = skyLightAlphaHide(id: id, pid: pid) { return hide }
        if let hide = cornerParkingHide(request) { return hide }
        control.setMinimized(request.window, true)
        control.log("    fallback → minimized（pid=\(pid), allowAppHide=\(allowAppHide), currentWindows=\(counts.visible), windows=\(counts.total)）")
        return .minimized
    }

    private func offscreenSpots(_ pos: CGPoint) -> [CGPoint] {
        [offscreenParkingPoint, CGPoint(x: -12000, y: pos.y), CGPoint(x: pos.x, y: -12000), CGPoint(x: -12000, y: -12000)]
    }

    private func offscreenHide(_ request: HideRequest) -> HideMethod? {
        for spot in offscreenSpots(request.position) {
            control.setPosition(request.window, spot)
            guard let moved = control.position(request.window) else { continue }
            if !request.layout.isVisible(pos: moved, size: request.size) {
                control.log("    AX offscreen → parked（pid=\(request.pid), pos=(\(Int(moved.x)),\(Int(moved.y))), reason=shade）")
                return .offscreen
            }
            control.log("    AX offscreen clamped（pid=\(request.pid), target=(\(Int(spot.x)),\(Int(spot.y))), actual=(\(Int(moved.x)),\(Int(moved.y))), reason=shade）")
        }
        control.setPosition(request.window, request.position)
        return nil
    }

    private func isParkedOffscreen(id: CGWindowID, request: HideRequest) -> Bool {
        if let bounds = control.windowServerBounds(id: id) {
            let size = bounds.width > 0 && bounds.height > 0 ? bounds.size : request.size
            return !request.layout.isVisible(pos: bounds.origin, size: size)
        }
        guard let pos = control.position(request.window) else { return false }
        return !request.layout.isVisible(pos: pos, size: request.size)
    }

    private func skyLightOffscreenHide(_ request: HideRequest, id: CGWindowID) -> HideMethod? {
        guard !knownSkyLightMoveIneffective else { return nil }
        guard control.skyLightMoveAvailable else {
            control.log("    private SLS offscreen unavailable（pid=\(request.pid), reason=fallback）")
            return nil
        }
        var moved = false
        for spot in offscreenSpots(request.position) {
            guard control.skyLightMove(id: id, to: spot) else {
                control.log("    private SLS move failed id=\(id) target=(\(Int(spot.x)),\(Int(spot.y))) reason=fallback")
                continue
            }
            moved = true
            if isParkedOffscreen(id: id, request: request) {
                control.log("    private SLS offscreen → parked id=\(id) pid=\(request.pid) target=(\(Int(spot.x)),\(Int(spot.y))) reason=fallback")
                return .privateOffscreen
            }
        }
        if !isParkedOffscreen(id: id, request: request) {
            _ = control.skyLightMove(id: id, to: request.position)
        }
        control.log("    private SLS offscreen did not park id=\(id) pid=\(request.pid) reason=fallback")
        if moved {
            // 调用返回成功，窗口却没有移动：系统忽略了跨进程的改动（SIP），之后不再尝试。
            lock.withLock { skyLightMoveIneffective = true }
            rememberIneffective("offscreen")
            control.log("    private SLS offscreen 在本机无效（很可能是 SIP 限制），本会话不再尝试")
        }
        return nil
    }

    private func skyLightAlphaHide(id: CGWindowID, pid: pid_t) -> HideMethod? {
        // SIP 开启的系统上，跨进程的 SkyLight 窗口改动会被静默忽略：调用返回成功，
        // 回读却发现 alpha 没变。第一次确认无效之后就不再重试。
        guard !knownSkyLightAlphaIneffective else { return nil }
        guard control.skyLightAlphaAvailable else {
            control.log("    private SLS alpha unavailable（pid=\(pid), reason=fallback）")
            return nil
        }
        let original = control.skyLightAlpha(id: id) ?? 1
        guard control.skyLightSetAlpha(id: id, 0) else {
            control.log("    private SLS alpha failed id=\(id) pid=\(pid) reason=fallback")
            return nil
        }
        let current = control.skyLightAlpha(id: id) ?? 1
        guard current <= 0.05 else {
            _ = control.skyLightSetAlpha(id: id, original)
            control.log("    private SLS alpha did not apply id=\(id) pid=\(pid) current=\(String(format: "%.2f", current)) reason=fallback")
            lock.withLock { skyLightAlphaIneffective = true }
            rememberIneffective("alpha")
            control.log("    private SLS alpha 在本机无效（很可能是 SIP 限制），本会话不再尝试")
            return nil
        }
        lock.withLock { alphaOriginals[id] = max(0.05, min(original, 1.0)) }
        control.log("    private SLS alpha → hidden id=\(id) pid=\(pid) original=\(String(format: "%.2f", original)) reason=fallback")
        return .privateAlpha
    }

    /// 挪到所在屏幕的下角外面，只留一像素：没有最小化缩进 Dock 的动画，展开时挪回原位即可。
    private func cornerParkingHide(_ request: HideRequest) -> HideMethod? {
        guard let screen = request.layout.screen(containing: request.position, size: request.size) else { return nil }
        let others = request.layout.screens.filter { $0 != screen }
        for spot in cornerParkingSpots(screen: screen, otherScreens: others, windowSize: request.size) {
            control.setPosition(request.window, spot)
            guard let parked = control.position(request.window) else { continue }
            if !request.layout.isVisible(pos: parked, size: request.size) {
                control.log("    corner → parked（pid=\(request.pid), pos=(\(Int(parked.x)),\(Int(parked.y)))）")
                return .offscreen
            }
            control.log("    corner parking clamped（pid=\(request.pid), target=(\(Int(spot.x)),\(Int(spot.y))), actual=(\(Int(parked.x)),\(Int(parked.y)))）")
        }
        control.setPosition(request.window, request.position)
        return nil
    }
}

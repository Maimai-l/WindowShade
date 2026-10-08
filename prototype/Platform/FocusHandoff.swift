// 收起时把键盘焦点交给原窗口后方的窗口（docs/design.md 第 5.4 节第 8 步）。
//
// 对焦点所在的应用程序或窗口执行隐藏、最小化时，macOS 按全局最近使用顺序自行挑选继承者，不限当前桌面：
// 继承者在别的桌面就会切换桌面。所以由 WindowShade 先在当前桌面上选好继承者：
// 同一应用程序在当前桌面上的其他窗口（菜单栏不变）→ 当前桌面最上层的其他普通应用程序窗口 → 无处交接。
// 无处交接时隐藏整个应用程序不安全，调用方改用别的方式移开原窗口。
// 底层操作经由 FocusControl：App 里是辅助功能和窗口服务器的调用，测试里是模拟实现。只依赖 Foundation。

import CoreGraphics
import Foundation

struct OnScreenWindow: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

protocol FocusControl: Sendable {
    func windows(pid: pid_t) -> [WindowHandle]
    func isSameWindow(_ a: WindowHandle, _ b: WindowHandle) -> Bool
    func isMinimized(_ window: WindowHandle) -> Bool
    func windowNumber(_ window: WindowHandle) -> CGWindowID?
    func frame(_ window: WindowHandle) -> CGRect?
    /// 当前屏幕上的窗口，从最上层到最下层。
    func onScreenWindows() -> [OnScreenWindow]
    func isRegularApp(pid: pid_t) -> Bool
    func appName(pid: pid_t) -> String
    func activate(pid: pid_t)
    func focus(_ window: WindowHandle, pid: pid_t)
    func log(_ message: String)
}

enum FocusHandoffResult: Equatable, Sendable {
    /// 原窗口所属的应用程序本来就不在前台：隐藏它不会引起焦点转移。
    case notFrontmost
    case sameApp(heir: CGWindowID)
    case otherApp(pid: pid_t)
    /// 当前桌面上没有可以接收焦点的窗口。
    case nowhere

    /// 交出焦点之后，隐藏整个应用程序不会让系统切换桌面。
    var appHideSafe: Bool { self != .nowhere }
}

struct FocusHandoffRequest: Sendable {
    let window: WindowHandle
    let id: CGWindowID
    let pid: pid_t
    let frontmostPID: pid_t?
    let selfPID: pid_t
    /// WindowShade 自己的卷帘条：不能接收焦点。
    let overlayIDs: Set<CGWindowID>
}

struct FocusHandoff: Sendable {
    let control: FocusControl

    func handOff(_ request: FocusHandoffRequest) -> FocusHandoffResult {
        guard request.frontmostPID == request.pid || request.frontmostPID == request.selfPID else {
            return .notFrontmost
        }
        let onScreen = control.onScreenWindows()
        let onScreenIDs = Set(onScreen.map(\.id))

        for candidate in control.windows(pid: request.pid) {
            guard !control.isSameWindow(candidate, request.window),
                  !control.isMinimized(candidate),
                  let cid = control.windowNumber(candidate), cid != request.id,
                  onScreenIDs.contains(cid) else { continue }
            control.focus(candidate, pid: request.pid)
            control.log("focus: handoff strategy=same-app heir=\(cid) id=\(request.id)")
            return .sameApp(heir: cid)
        }

        for info in onScreen {
            guard info.pid != request.pid, info.pid != request.selfPID,
                  info.layer == 0, info.alpha > 0,
                  !request.overlayIDs.contains(info.id),
                  info.bounds.width > 1, info.bounds.height > 1,
                  control.isRegularApp(pid: info.pid) else { continue }
            control.activate(pid: info.pid)
            var best: (window: WindowHandle, distance: CGFloat)?
            for heir in control.windows(pid: info.pid) {
                guard let frame = control.frame(heir) else { continue }
                let distance = abs(frame.minX - info.bounds.minX) + abs(frame.minY - info.bounds.minY)
                    + abs(frame.width - info.bounds.width) + abs(frame.height - info.bounds.height)
                if distance <= 96, best == nil || distance < best!.distance { best = (heir, distance) }
            }
            if let heir = best?.window { control.focus(heir, pid: info.pid) }
            control.log("focus: handoff strategy=top-window heir=\(control.appName(pid: info.pid)) id=\(request.id)")
            return .otherApp(pid: info.pid)
        }

        // 当前桌面没有其他窗口：激活访达会被调度中心拉去它有窗口的桌面；
        // 不交接，由调用方改用最小化等不触发前台应用程序更替的方式。
        control.log("focus: handoff strategy=stay-minimize id=\(request.id)")
        return .nowhere
    }
}

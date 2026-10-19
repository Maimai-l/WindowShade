// 收起时把键盘焦点交给原窗口后方的窗口（docs/design.md 第 5.4 节第 8 步）。
//
// 对焦点所在的应用程序或窗口执行隐藏、最小化时，macOS 按全局最近使用顺序自己挑下一个接手焦点的窗口，
// 不限当前桌面：选中的窗口在别的桌面上，就会切换桌面。所以 WindowShade 先在当前桌面上选好接手的窗口：
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
    /// 前台应用程序的进程号；读不到时为 nil。
    func frontmostPID() -> pid_t?
    /// 让当前线程等 seconds 秒。只在后台队列上调用。
    func pause(_ seconds: Double)
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
    /// 已被 WindowShade 收起的窗口：停在屏幕角落时还露出 1 像素，算在屏幕上，但不能接收焦点
    /// （交给它，它成了当前窗口，应用程序下次被激活时系统把它拉回屏幕内；场景 A37）。
    var foldedIDs: Set<CGWindowID> = []
}

struct FocusHandoff: Sendable {
    let control: FocusControl

    /// 焦点交给别的应用程序后，最多等它多少秒到前台（heirWaitLimit），每隔多少秒看一次（heirWaitStep）。
    static let heirWaitLimit = 0.3
    static let heirWaitStep = 0.01

    /// waitForHeir：焦点交给别的应用程序后，等它到了前台再返回，最多等 heirWaitLimit 秒。激活要过一会儿才生效；
    /// 它还没到前台就隐藏原应用程序，系统会按最近使用顺序另挑一个应用程序，挑中的可能在别的桌面上，屏幕会跟着切过去。
    /// 依据：用户的 macOS 14.5 本机运行（4f1a815），见 docs/testing.md 第 5 节。
    /// 只有隐藏之前、在后台队列上交接的调用方传 true；隐藏之后才交接或在主线程上交接的不等。
    func handOff(_ request: FocusHandoffRequest, waitForHeir: Bool = false) -> FocusHandoffResult {
        guard request.frontmostPID == request.pid || request.frontmostPID == request.selfPID else {
            return .notFrontmost
        }
        let onScreen = control.onScreenWindows()
        let onScreenIDs = Set(onScreen.map(\.id))

        for candidate in control.windows(pid: request.pid) {
            guard !control.isSameWindow(candidate, request.window),
                  !control.isMinimized(candidate),
                  let cid = control.windowNumber(candidate), cid != request.id,
                  !request.foldedIDs.contains(cid), onScreenIDs.contains(cid) else { continue }
            // 截图时 WindowShade 为让原窗口画成非活跃态暂居前台：这时只设置焦点窗口，应用程序仍在后台，
            // 接手的窗口成不了当前窗口，键盘落到 WindowShade 上。所以还要把应用程序激活回来。
            // 先设焦点窗口再激活，理由同下面交给别的应用程序时。
            control.focus(candidate, pid: request.pid)
            if request.frontmostPID != request.pid { control.activate(pid: request.pid) }
            control.log("focus: handoff strategy=same-app heir=\(cid) id=\(request.id)")
            return .sameApp(heir: cid)
        }

        for info in onScreen {
            guard info.pid != request.pid, info.pid != request.selfPID,
                  info.layer == 0, info.alpha > 0,
                  !request.overlayIDs.contains(info.id),
                  info.bounds.width > 1, info.bounds.height > 1,
                  control.isRegularApp(pid: info.pid) else { continue }
            var best: (window: WindowHandle, distance: CGFloat)?
            for heir in control.windows(pid: info.pid) {
                guard let frame = control.frame(heir) else { continue }
                let distance = abs(frame.minX - info.bounds.minX) + abs(frame.minY - info.bounds.minY)
                    + abs(frame.width - info.bounds.width) + abs(frame.height - info.bounds.height)
                if distance <= 96, best == nil || distance < best!.distance { best = (heir, distance) }
            }
            // 先把这个桌面上的窗口设成它的焦点窗口，再激活：接手的应用程序在别的桌面上也有窗口时，先激活会让系统
            // 把那扇窗口带到前面，屏幕切过去（用户的测试机，macOS 14.5，8e9a4f1，场景 E11-trash、E12）。
            if let heir = best?.window { control.focus(heir, pid: info.pid) }
            control.activate(pid: info.pid)
            var wait = ""
            if waitForHeir {
                var waited = 0.0
                while control.frontmostPID() != info.pid, waited + Self.heirWaitStep <= Self.heirWaitLimit + 0.0001 {
                    control.pause(Self.heirWaitStep)
                    waited += Self.heirWaitStep
                }
                wait = " waitedMs=\(Int((waited * 1000).rounded())) inFront=\(control.frontmostPID() == info.pid)"
            }
            control.log("focus: handoff strategy=top-window heir=\(control.appName(pid: info.pid)) id=\(request.id)\(wait)")
            return .otherApp(pid: info.pid)
        }

        // 当前桌面没有其他窗口：激活访达会被调度中心拉去它有窗口的桌面；
        // 不交接，由调用方改用最小化等不触发前台应用程序更替的方式。
        control.log("focus: handoff strategy=stay-minimize id=\(request.id)")
        return .nowhere
    }
}

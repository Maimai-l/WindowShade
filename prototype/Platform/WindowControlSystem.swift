// WindowControl 的真实实现：辅助功能、SkyLight 和窗口服务器的调用。可以在任意线程执行。

import Cocoa

struct WindowControlSystem: WindowControl {
    private func element(_ window: WindowHandle) -> AXUIElement {
        // WindowHandle 在 App 里只装 AXUIElement（见 WindowHandle(ax:)）。
        unsafeDowncast(window.element, to: AXUIElement.self)
    }

    func position(_ window: WindowHandle) -> CGPoint? { axPosition(element(window)) }
    func setPosition(_ window: WindowHandle, _ point: CGPoint) { setAXPosition(element(window), point) }
    func setMinimized(_ window: WindowHandle, _ minimized: Bool) { setAXMinimized(element(window), minimized) }
    func pressCloseButton(_ window: WindowHandle) -> Bool { pressAXButton(element(window), kAXCloseButtonAttribute as String) }

    func hideApp(pid: pid_t) -> String? {
        if setAXAppHidden(pid: pid, true) { return "AX" }
        if NSRunningApplication(processIdentifier: pid)?.hide() == true { return "NSRunningApplication" }
        return nil
    }

    func windowCounts(pid: pid_t, layout: ScreenLayout) -> (visible: Int, total: Int) {
        let windows = appWindows(pid: pid)
        let visible = windows.filter { win in
            guard !axBoolAttribute(win, kAXMinimizedAttribute as String) else { return false }
            guard let size = axSize(win), size.width > 40, size.height > 40 else { return false }
            guard let pos = axPosition(win) else { return true }
            return layout.isVisible(pos: pos, size: size)
        }.count
        return (visible, windows.count)
    }

    var skyLightMoveAvailable: Bool { PrivateSLSWindowMover.shared.isAvailable }
    var skyLightAlphaAvailable: Bool { PrivateSLSWindowMover.shared.canSetAlpha }
    func skyLightMove(id: CGWindowID, to point: CGPoint) -> Bool { PrivateSLSWindowMover.shared.moveWindow(id: id, to: point) }
    func skyLightAlpha(id: CGWindowID) -> Float? {
        PrivateSLSWindowMover.shared.windowAlpha(id: id)
            ?? (cgWindowInfo(id)?[kCGWindowAlpha as String] as? NSNumber).map { Float($0.doubleValue) }
    }
    func skyLightSetAlpha(id: CGWindowID, _ alpha: Float) -> Bool { PrivateSLSWindowMover.shared.setAlpha(id: id, alpha: alpha) }
    func windowServerBounds(id: CGWindowID) -> CGRect? { cgWindowInfo(id).flatMap { cgWindowBounds($0) } }
    func log(_ message: String) { wlog(message) }
}

extension WindowHandle {
    init(ax element: AXUIElement) { self.init(element: element) }
}

/// FocusControl 的真实实现：辅助功能和窗口服务器的调用。可以在任意线程执行。
struct FocusControlSystem: FocusControl {
    private func element(_ window: WindowHandle) -> AXUIElement { unsafeDowncast(window.element, to: AXUIElement.self) }

    func windows(pid: pid_t) -> [WindowHandle] { appWindows(pid: pid).map { WindowHandle(ax: $0) } }
    func isSameWindow(_ a: WindowHandle, _ b: WindowHandle) -> Bool { CFEqual(element(a), element(b)) }
    func isMinimized(_ window: WindowHandle) -> Bool { axBoolAttribute(element(window), kAXMinimizedAttribute as String) }
    func windowNumber(_ window: WindowHandle) -> CGWindowID? { windowID(of: element(window)) }
    func frame(_ window: WindowHandle) -> CGRect? {
        guard let pos = axPosition(element(window)), let size = axSize(element(window)) else { return nil }
        return CGRect(origin: pos, size: size)
    }
    func onScreenWindows() -> [OnScreenWindow] {
        WindowListCache.shared.onScreenWindows().compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = cgWindowBounds(info) else { return nil }
            return OnScreenWindow(id: CGWindowID(number.uint32Value), pid: owner,
                                  layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                                  alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                  bounds: bounds)
        }
    }
    func isRegularApp(pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular }
    func appName(pid: pid_t) -> String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? String(pid) }
    func activate(pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
    func focus(_ window: WindowHandle, pid: pid_t) { focusAXWindow(element(window), pid: pid) }
    func log(_ message: String) { wlog(message) }
}

/// RestoreControl 的真实实现：辅助功能、SkyLight 和 NSRunningApplication 的调用。可以在任意线程执行。
struct RestoreControlSystem: RestoreControl {
    private func element(_ window: WindowHandle) -> AXUIElement { unsafeDowncast(window.element, to: AXUIElement.self) }

    func resolve(_ window: WindowHandle, id: CGWindowID, pid: pid_t) -> WindowHandle {
        // 存活即可信：不拿编号精确比对（windowID(of:) 对某些应用程序和窗口服务器的编号不一致）。
        if axPosition(element(window)) != nil { return window }
        guard let match = appWindows(pid: pid).first(where: { windowID(of: $0) == id }) else { return window }
        return WindowHandle(ax: match)
    }

    func unhideApp(pid: pid_t) {
        if NSRunningApplication(processIdentifier: pid)?.unhide() != true { _ = setAXAppHidden(pid: pid, false) }
    }

    func setMinimized(_ window: WindowHandle, _ minimized: Bool) { setAXMinimized(element(window), minimized) }
    func isMinimized(_ window: WindowHandle) -> Bool { axBoolAttribute(element(window), kAXMinimizedAttribute as String) }
    func setSize(_ window: WindowHandle, _ size: CGSize) -> Bool { setAXSize(element(window), size) == .success }
    func setPosition(_ window: WindowHandle, _ point: CGPoint) -> Bool {
        setAXPositionReturningError(element(window), point) == .success
    }
    func frame(_ window: WindowHandle) -> CGRect? {
        guard let pos = axPosition(element(window)), let size = axSize(element(window)) else { return nil }
        return CGRect(origin: pos, size: size)
    }
    func skyLightMove(id: CGWindowID, to point: CGPoint) -> Bool { PrivateSLSWindowMover.shared.moveWindow(id: id, to: point) }
    func skyLightSetAlpha(id: CGWindowID, _ alpha: Float) -> Bool { PrivateSLSWindowMover.shared.setAlpha(id: id, alpha: alpha) }
    func isFrontmost(pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    func activate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        app.activate(options: [])
    }
    func raise(_ window: WindowHandle) { raiseAXWindow(element(window)) }
    func focus(_ window: WindowHandle, pid: pid_t) { focusAXWindow(element(window), pid: pid) }
    func log(_ message: String) { wlog(message) }
}

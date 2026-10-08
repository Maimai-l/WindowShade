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

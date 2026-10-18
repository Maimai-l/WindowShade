// 卷帘条被带到别的桌面时，原窗口跟过去（需求 S6）。

import Cocoa

extension AppDelegate {
    /// 卷帘条留在 target 桌面，原窗口按收起方式跟过去（见 Domain/DesktopCarry.swift 的 carryMethod）。
    /// 返回 false 表示这种收起方式不跟过去，由调用方把卷帘条挪回原桌面。
    func carryFoldedWindow(id: CGWindowID, state: ShadeState, toSpace target: UInt64) -> Bool {
        let method = carryMethod(for: state.hide)
        guard method != .notSupported else {
            wlog("space: carry not supported id=\(id) hide=\(state.hide.rawValue); moving the strip back")
            return false
        }
        var updated = state
        updated.sourceSpaceID = target
        if case .minimize = method { updated.hide = .minimized }
        shaded[id] = updated
        pendingSpaceReturns.removeValue(forKey: id)
        updateShadeJournal(id: id, reason: "carried-to-space") { entry in
            entry["spaceID"] = Double(target)
            entry["hide"] = updated.hide.rawValue
        }
        wlog("space: carried strip id=\(id) from=\(state.sourceSpaceID.map(String.init) ?? "-") to=\(target) "
             + "hide=\(state.hide.rawValue)->\(updated.hide.rawValue)")
        guard case .minimize(let unhideFirst) = method else { return true }
        // 先改记录再动窗口：取消隐藏时会收到“应用程序已显示”的通知，这时记录里已是最小化，就不会把它当成用户唤回窗口而展开。
        // 辅助功能调用交给该应用程序的队列，主线程不等（R5）。
        let restorer = windowRestorer
        let window = WindowHandle(ax: state.element)
        let windowID = state.sourceWindowID
        let pid = state.pid
        restorer.run(pid: pid) {
            if unhideFirst { restorer.control.unhideApp(pid: pid) }
            let resolved = restorer.control.resolve(window, id: windowID, pid: pid)
            restorer.control.setMinimized(resolved, true)
            wlog("space: carried window minimized id=\(windowID) minimized=\(restorer.control.isMinimized(resolved))")
        }
        return true
    }
}

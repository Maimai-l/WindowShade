// 卷帘条被带到别的桌面时，原窗口跟过去（需求 S6）。

import Cocoa

extension AppDelegate {
    /// 卷帘条留在 target 桌面，原窗口用私有接口移过去，收起方式不变（见 Domain/DesktopCarry.swift 的 canCarry）。
    /// 返回 false 表示原窗口跟不过去，由调用方把卷帘条挪回原桌面。
    func carryFoldedWindow(id: CGWindowID, state: ShadeState, toSpace target: UInt64) -> Bool {
        guard canCarry(state.hide) else {
            wlog("space: carry not supported id=\(id) hide=\(state.hide.rawValue); moving the strip back")
            return false
        }
        guard let method = PrivateSLSWindowMover.shared.moveOtherAppWindow(id: state.sourceWindowID, toSpace: target) else {
            wlog("space: carry failed id=\(id) window=\(state.sourceWindowID) to=\(target) hide=\(state.hide.rawValue); "
                 + "the window could not be moved to that desktop; moving the strip back")
            return false
        }
        var updated = state
        updated.sourceSpaceID = target
        shaded[id] = updated
        pendingSpaceReturns.removeValue(forKey: id)
        updateShadeJournal(id: id, reason: "carried-to-space") { entry in entry["spaceID"] = Double(target) }
        wlog("space: carried strip id=\(id) from=\(state.sourceSpaceID.map(String.init) ?? "-") to=\(target) "
             + "hide=\(state.hide.rawValue) method=\(method)")
        return true
    }
}

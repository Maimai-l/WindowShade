// 卷帘条被带到别的桌面时，原窗口跟过去（需求 S6）。

import Cocoa

extension AppDelegate {
    /// 卷帘条留在 target 桌面，原窗口用私有接口移过去，收起方式不变（见 Domain/DesktopCarry.swift 的 carryDecision）。
    /// 返回 false 表示原窗口跟不过去，由调用方把卷帘条挪回原桌面；已隐藏的应用程序要移时先返回 true，移不过去时稍后由 undoCarry 挪回。
    func carryFoldedWindow(id: CGWindowID, state: ShadeState, toSpace target: UInt64) -> Bool {
        switch carryDecision(hide: state.hide, systemIntegrityEnabled: SystemIntegrity.isEnabled,
                             failedBefore: carryFailedHideMethods) {
        case .attempt:
            break
        case .skipUnsupported:
            wlog("space: carry not supported id=\(id) hide=\(state.hide.rawValue); moving the strip back")
            return false
        case .skipFailedBefore:
            wlog("space: carry skipped id=\(id) hide=\(state.hide.rawValue); this kind of folded window could not be moved earlier in this run")
            return false
        case .moveWhenUnfolding:
            // 切桌面时不取消隐藏应用程序：卷帘条留在新桌面，窗口展开时再移（见 carryDecision 和 WindowRestorer.restore）。
            recordCarry(id: id, state: state, toSpace: target, method: "when-unfolding")
            shaded[id]?.pendingSpaceID = target
            return true
        }
        let mover = PrivateSLSWindowMover.shared
        let windowID = state.sourceWindowID
        if state.hide == .hidden {
            // 应用程序隐藏后，查不到它的窗口在哪张桌面上，移了也核对不了（CI 场景 S6-carry，30acfcc）：
            // 先把窗口设成透明，再在后台临时取消隐藏应用程序，等查到窗口在哪张桌面后移过去、核对，
            // 然后重新隐藏应用程序，把窗口设回不透明。
            // 用户这时已经在新桌面上，看不到原桌面上的这番操作。
            recordCarry(id: id, state: state, toSpace: target, method: "pending")
            carryRevealHolds.insert(id)
            let restorer = windowRestorer
            let pid = state.pid
            let original = state.sourceSpaceID
            restorer.run(pid: pid) {
                _ = mover.setAlpha(id: windowID, alpha: 0)
                restorer.control.unhideApp(pid: pid)
                var shownOn: UInt64?
                for _ in 0..<20 {
                    shownOn = mover.windowSpace(id: windowID)
                    if shownOn != nil { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let method = mover.moveOtherAppWindow(id: windowID, toSpace: target)
                _ = setAXAppHidden(pid: pid, true)
                wlog("space: carried hidden window id=\(id) window=\(windowID) shownOn=\(shownOn.map(String.init) ?? "-") "
                     + "method=\(method ?? "none") now=\(mover.windowSpace(id: windowID).map(String.init) ?? "-")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.finishCarriedHide(id: id, pid: pid, windowID: windowID, moved: method != nil,
                                                original: original, attempt: 1)
                    }
                }
            }
            return true
        }
        guard let method = mover.moveOtherAppWindow(id: windowID, toSpace: target) else {
            wlog("space: carry failed id=\(id) window=\(windowID) to=\(target) hide=\(state.hide.rawValue) "
                 + "on=\(mover.windowSpace(id: windowID).map(String.init) ?? "-"); moving the strip back")
            rememberCarryFailed(state.hide)
            return false
        }
        recordCarry(id: id, state: state, toSpace: target, method: method)
        return true
    }

    /// 移完后应用程序要重新隐藏好，才把窗口设回不透明；从这以后，应用程序再显示就按用户唤回处理。
    /// 应用程序还没处理完取消隐藏时，发给它的隐藏请求可能不起作用（CI 场景 S6-carry，06529c3）。
    /// 这样窗口会留在新桌面上，被当成用户唤回，卷帘条就撤掉了。
    /// 这时每隔 0.4 秒再隐藏一次，最多再试 3 次；仍然没有隐藏，也把窗口设回不透明。
    private func finishCarriedHide(id: CGWindowID, pid: pid_t, windowID: CGWindowID, moved: Bool,
                                   original: UInt64?, attempt: Int) {
        let restorer = windowRestorer
        // 用户在这期间展开了窗口：不再隐藏应用程序，也不挪回卷帘条。依据：用户 macOS 15.2 的日志（869b8b0），展开后应用程序又隐藏了 3 次。
        let stillFolded = shaded[id] != nil
        if stillFolded, let app = runningApp(pid: pid), !app.isTerminated, !app.isHidden, attempt < 4 {
            wlog("space: app still shown after carrying id=\(id) attempt=\(attempt); hiding it again")
            restorer.run(pid: pid) { _ = setAXAppHidden(pid: pid, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishCarriedHide(id: id, pid: pid, windowID: windowID, moved: moved,
                                            original: original, attempt: attempt + 1)
                }
            }
            return
        }
        restorer.run(pid: pid) { _ = PrivateSLSWindowMover.shared.setAlpha(id: windowID, alpha: 1) }
        carryRevealHolds.remove(id)
        guard !moved else { return }
        rememberCarryFailed(.hidden)
        if stillFolded, let original { undoCarry(id: id, backTo: original) }
    }

    /// 记下这种收起方式的窗口没移过去：这次运行里不再试，别的收起方式照样试；不记进偏好（见 carryDecision）。
    private func rememberCarryFailed(_ hide: HideMethod) {
        carryFailedHideMethods.insert(hide)
    }

    private func recordCarry(id: CGWindowID, state: ShadeState, toSpace target: UInt64, method: String) {
        var updated = state
        updated.sourceSpaceID = target
        shaded[id] = updated
        pendingSpaceReturns.removeValue(forKey: id)
        updateShadeJournal(id: id, reason: "carried-to-space") { entry in entry["spaceID"] = Double(target) }
        wlog("space: carried strip id=\(id) from=\(state.sourceSpaceID.map(String.init) ?? "-") to=\(target) "
             + "hide=\(state.hide.rawValue) method=\(method)")
    }

    /// 原窗口没能移过去：卷帘条回到原窗口所在的桌面。
    private func undoCarry(id: CGWindowID, backTo original: UInt64) {
        guard var state = shaded[id] else { return }
        state.sourceSpaceID = original
        shaded[id] = state
        updateShadeJournal(id: id, reason: "carry-undone") { entry in entry["spaceID"] = Double(original) }
        if let overlayID = state.overlayID { _ = PrivateSLSWindowMover.shared.moveWindow(id: overlayID, toSpace: original) }
        wlog("space: carry undone id=\(id); the window could not be moved, the strip goes back to \(original)")
        _ = enforceOverlaySpaceInvariant(id: id, state: state, reason: "carry-undone")
    }
}

// 折叠出口与交通灯：展开恢复、清理、交通灯动作转发、QuickLook 特殊处理。
// 作为 AppDelegate 扩展实现。

import Cocoa

extension AppDelegate {
    func unshadeReturningElement(_ id: CGWindowID, playSound: Bool = true,
                                         pinAfterRestore: Bool = true,
                                         onVerified: ((Bool) -> Void)? = nil) -> AXUIElement? {
        guard shaded[id] != nil else { return nil }
        // 同 ShadeController.shade：展开开始就在后台把音频设备叫醒，音效不迟半秒。
        prewarmUnfoldSound()
        markShadeLifecycle(id: id, .restoring, reason: "unshade")
        transitionOperationState(id: id, to: .restoring, reason: "unshade")
        guard let state = shaded.removeValue(forKey: id) else { return nil }
        // 缩略图原地展开：整理（⌃⌘0）过的，按整理前的原位放，和飞回去的截图、看一眼的卡片落在同一处。
        // 要在下面清掉整理记录之前取。卷帘条照旧在它现在的位置展开。
        let thumbnailHome = state.appearanceMode == .thumbnail
            ? state.overlay.map { restoreReferenceFrame(id: id, overlay: $0) } : nil
        let interruptedWaiters = foldWaiters[id].map { Array($0.keys) } ?? []
        defer { MainActor.assumeIsolated { cancelFoldWaiters(id: id, tokens: interruptedWaiters) } }
        hideMenuHoverPreview(id: id)
        MainActor.assumeIsolated { glance.detach(id: id) }
        reconcileInvalidCounts.removeValue(forKey: id)
        pendingSpaceReturns.removeValue(forKey: id)
        hoverPreviewSuppressedUntil.removeValue(forKey: id)
        arrangedOverlayFrames.removeValue(forKey: id)
        accessibilityActionTargets.removeValue(forKey: id)
        if let overlayID = state.overlayID { overlayIDs.remove(overlayID) }
        removeObserver(state)                          // 先停掉监听，避免下面的恢复动作反过来触发自己
        // 折叠条可能被拖动过 → 窗口在折叠条「当前」位置展开（标题栏带着窗口走）
        let pos: CGPoint
        // 窗口是从屏幕外挪回来的：先让它回到原处，再撤卷帘条，中间不留空档。
        // 最小化、隐藏的窗口要等系统把它放出来，照旧先撤。
        let dismissAfterRestore = state.hide == .offscreen || state.hide == .privateOffscreen
        if let overlay = state.overlay {
            pos = axPosition(fromCocoaFrame: thumbnailHome ?? restoreReferenceFrame(id: id, overlay: overlay))
            if !dismissAfterRestore { dismissOverlay(overlay) }
        } else {
            pos = axPosition(state.element) ?? state.originalPosition
        }
        if state.hide == .quickLookClosed {
            clearShadeJournal(id: id) // This strategy intentionally closes the original window.
            onVerified?(false)
            if let url = state.quickLookReopenURL, reopenQuickLookPreview(url: url) {
                wlog("quicklook: reopened via qlmanage id=\(id) path=\(url.path)")
            } else {
                wlog("quicklook: reopen unavailable id=\(id)")
            }
            rebuildMenu()
            if playSound && !suppressUnshadeSounds {
                playUnfoldSound()
            }
            transitionOperationState(id: id, to: .normal, reason: "unshade-quicklook")
            return nil
        }
        if state.hide == .ownWindowOrderedOut {
            // WindowShade 自己的窗口：放回是主线程上的 AppKit 操作，不涉及其他应用程序。
            let restoredElement = restoreWindow(state, to: pos)
            bringRestoredWindowToFront(restoredElement, pid: state.pid, reason: "unshade id=\(id)")
            if dismissAfterRestore, let overlay = state.overlay { dismissOverlay(overlay) }
            if pinAfterRestore {
                pinRestoredWindow(state, to: pos, reason: "unshade id=\(id)")
            } else {
                cancelRestorePin(for: id)
            }
            verifyRestoredWindow(state, to: pos, completion: onVerified)
        } else {
            // 其他应用程序的窗口：辅助功能调用交给它自己的队列，主线程不等（R5）。
            // 从屏幕外移回的窗口，卷帘条留到窗口回来之后再撤。
            restoreInBackground(state, id: id, to: pos, dismissOverlayAfter: dismissAfterRestore,
                                pin: pinAfterRestore, reason: "unshade id=\(id)", onVerified: onVerified)
        }
        transitionOperationState(id: id, to: .normal, reason: "unshade")
        rebuildMenu()
        if playSound && !suppressUnshadeSounds {
            playUnfoldSound()
        }
        return state.element
    }
    @discardableResult
    func unshade(_ id: CGWindowID) -> Bool {
        MainThreadActivity.push("restore: 展开窗口")
        defer { MainThreadActivity.pop() }
        let memoScope = beginAppWindowsMemo()
        defer { endAppWindowsMemo(memoScope) }
        // 看一眼的卡片正盖在原处：由它来展开，卡片留到真窗口回来再撤。
        // 直接展开会先撤卡片，真窗口回来之前露出后面的窗口。
        if MainActor.assumeIsolated({ glance.isShown(id) }) {
            return MainActor.assumeIsolated { glance.expand(id) }
        }
        return unshadeReturningElement(id) != nil
    }
    func forceCleanup(_ id: CGWindowID, preserveRecovery: Bool = false) {
        restoreVerificationTokens.removeValue(forKey: id)
        guard shaded[id] != nil else { return }
        markShadeLifecycle(id: id, .cleaned, reason: "forceCleanup")
        guard let state = shaded.removeValue(forKey: id) else { return }
        let interruptedWaiters = foldWaiters[id].map { Array($0.keys) } ?? []
        defer { MainActor.assumeIsolated { cancelFoldWaiters(id: id, tokens: interruptedWaiters) } }
        transitionOperationState(id: id, to: .normal, reason: "forceCleanup")
        hideMenuHoverPreview(id: id)
        MainActor.assumeIsolated { glance.detach(id: id) }
        if !preserveRecovery { clearShadeJournal(id: id) }
        reconcileInvalidCounts.removeValue(forKey: id)
        _ = windowHider.takeOriginalAlpha(id: id)
        hoverPreviewSuppressedUntil.removeValue(forKey: id)
        arrangedOverlayFrames.removeValue(forKey: id)
        accessibilityActionTargets.removeValue(forKey: id)
        if let overlayID = state.overlayID { overlayIDs.remove(overlayID) }
        removeObserver(state)
        if let overlay = state.overlay { dismissOverlay(overlay) }
        rebuildMenu()
    }
    func removeProxyForAction(_ id: CGWindowID, state: ShadeState,
                                      stage: ShadeLifecycleStage, reason: String) {
        guard shaded[id]?.foldTransactionID == state.foldTransactionID else { return }
        let interruptedWaiters = foldWaiters[id].map { Array($0.keys) } ?? []
        defer { MainActor.assumeIsolated { cancelFoldWaiters(id: id, tokens: interruptedWaiters) } }
        markShadeLifecycle(id: id, stage, reason: reason)
        transitionOperationState(id: id, to: .normal, reason: "removeProxy")
        hideMenuHoverPreview(id: id)
        // 先移出收起记录，再撤看一眼：画面结束时，窗口若还算收起着，会把临时取消隐藏的应用程序藏回去，
        // 刚放回来、正要按它的关闭按钮的窗口就又不见了（CI 场景 C04-cancel：选“取消”后窗口不在屏幕上）。
        shaded.removeValue(forKey: id)
        MainActor.assumeIsolated { glance.detach(id: id) }
        clearShadeJournal(id: id)
        reconcileInvalidCounts.removeValue(forKey: id)
        arrangedOverlayFrames.removeValue(forKey: id)
        accessibilityActionTargets.removeValue(forKey: id)
        if let overlayID = state.overlayID { overlayIDs.remove(overlayID) }
        removeObserver(state)
        if let overlay = state.overlay { dismissOverlay(overlay) }
        rebuildMenu()
    }
    func removeProxyForForwardedAction(_ id: CGWindowID, state: ShadeState) {
        removeProxyForAction(id, state: state, stage: .forwarded, reason: "traffic-light-forward")
    }
    func quickLookProcessHint(pid: pid_t) -> Bool {
        let bundle = appBundleID(pid: pid).lowercased()
        let name = appDisplayName(pid: pid).lowercased()
        return bundle == "com.apple.finder" ||
            bundle.contains("quicklook") ||
            bundle.contains("qlmanage") ||
            name.contains("finder") ||
            name.contains("quicklook") ||
            name.contains("quick look") ||
            name.contains("qlmanage") ||
            name.contains("快速查看")
    }
    func windowLooksLikeQuickLookTarget(_ win: AXUIElement, pid: pid_t,
                                                expectedTitle: String) -> Bool {
        if proxyTrafficLightConfiguration(of: win, pid: pid).style == .quickLook {
            return true
        }
        let hasClose = axButtonFrame(win, kAXCloseButtonAttribute as String) != nil
        let hasMinimize = axButtonFrame(win, kAXMinimizeButtonAttribute as String) != nil
        let hasFullScreenish = axButtonFrame(win, kAXFullScreenButtonAttribute as String) != nil ||
            axButtonFrame(win, kAXZoomButtonAttribute as String) != nil ||
            isAXAttributeSettable(win, axFullScreenAttribute)
        guard hasClose, hasFullScreenish, !hasMinimize, firstToolbar(win) == nil else { return false }
        if quickLookProcessHint(pid: pid) { return true }

        let cleanExpected = cleanDisplayTitle(expectedTitle).lowercased()
        let cleanTitle = cleanDisplayTitle(axTitle(win)).lowercased()
        return !cleanExpected.isEmpty &&
            (cleanTitle == cleanExpected ||
             cleanTitle.contains(cleanExpected) ||
             cleanExpected.contains(cleanTitle))
    }
    func quickLookWindowCandidates(preferredPID: pid_t, title: String) -> [(pid: pid_t, win: AXUIElement)] {
        let cleanTitle = cleanDisplayTitle(title)
        var pids: [pid_t] = [preferredPID]
        for app in NSWorkspace.shared.runningApplications {
            if quickLookProcessHint(pid: app.processIdentifier) {
                pids.append(app.processIdentifier)
            }
        }
        let cgWindows = WindowListCache.shared.onScreenWindows()
        for info in cgWindows {
            let ownerName = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            let windowName = cleanDisplayTitle(cgWindowName(info)).lowercased()
            let titleHint = !cleanTitle.isEmpty && !windowName.isEmpty &&
                (windowName == cleanTitle.lowercased() ||
                 windowName.contains(cleanTitle.lowercased()) ||
                 cleanTitle.lowercased().contains(windowName))
            guard ownerName.contains("quicklook") ||
                    ownerName.contains("quick look") ||
                    ownerName.contains("qlmanage") ||
                    ownerName.contains("finder") ||
                    ownerName.contains("快速查看") ||
                    titleHint,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            pids.append(ownerPID.int32Value)
        }

        var seen = Set<Int32>()
        var candidates: [(pid: pid_t, win: AXUIElement, score: Int)] = []
        for pid in pids where seen.insert(pid).inserted {
            for win in appWindows(pid: pid) {
                guard windowLooksLikeQuickLookTarget(win, pid: pid, expectedTitle: title) else { continue }
                var score = pid == preferredPID ? 0 : 10
                if quickLookProcessHint(pid: pid) { score -= 6 }
                let candidateTitle = cleanDisplayTitle(axTitle(win))
                if !cleanTitle.isEmpty && !candidateTitle.isEmpty {
                    if candidateTitle == cleanTitle {
                        score -= 30
                    } else if candidateTitle.contains(cleanTitle) || cleanTitle.contains(candidateTitle) {
                        score -= 15
                    }
                }
                if let size = axSize(win), size.width > 40, size.height > 40 {
                    score -= 4
                }
                candidates.append((pid, win, score))
            }
        }

        return candidates.sorted { $0.score < $1.score }.map { ($0.pid, $0.win) }
    }
    func reopenQuickLookForProxyFullScreen(state: ShadeState, id: CGWindowID) -> Bool {
        if let url = state.quickLookReopenURL, reopenQuickLookPreview(url: url) {
            wlog("quicklook fullscreen: reopen via qlmanage id=\(id) path=\(url.path)")
            return true
        }
        wlog("quicklook fullscreen: reopen unavailable id=\(id)")
        return false
    }
    /// 只用辅助功能：先写 AXFullScreen，不行再按一次全屏或缩放按钮。
    func triggerQuickLookFullScreen(_ win: AXUIElement, pid: pid_t,
                                            id: CGWindowID, attempt: Int) -> Bool {
        if isAXAttributeSettable(win, axFullScreenAttribute),
           AXUIElementSetAttributeValue(win, axFullScreenAttribute as CFString, kCFBooleanTrue) == .success {
            wlog("quicklook fullscreen: AXFullScreen set id=\(id) pid=\(pid) attempt=\(attempt)")
            return true
        }
        for attr in [kAXFullScreenButtonAttribute as String, kAXZoomButtonAttribute as String] {
            if pressAXButton(win, attr) {
                wlog("quicklook fullscreen: AXPress attr=\(attr) id=\(id) pid=\(pid) attempt=\(attempt)")
                return true
            }
        }
        return false
    }
    func openQuickLookFullScreenFromProxy(state: ShadeState, id: CGWindowID) {
        let delays: [TimeInterval] = [0.08, 0.18, 0.32, 0.55, 0.85, 1.20]

        func attempt(_ index: Int) {
            guard index < delays.count else {
                wlog("quicklook fullscreen: unavailable; no QuickLook target id=\(id)")
                return
            }

            if let target = quickLookWindowCandidates(preferredPID: state.pid, title: state.title).first {
                runningApp(pid: target.pid)?.activate(options: [])
                raiseAXWindow(target.win)
                focusAXWindow(target.win, pid: target.pid)
                if triggerQuickLookFullScreen(target.win, pid: target.pid, id: id, attempt: index) {
                    return
                }
                wlog("quicklook fullscreen: target not ready id=\(id) attempt=\(index)")
            } else {
                wlog("quicklook fullscreen: waiting for reopened window id=\(id) attempt=\(index)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delays[index]) {
                attempt(index + 1)
            }
        }

        attempt(0)
    }
    func handleQuickLookTrafficLight(_ action: TrafficAction, id: CGWindowID, state: ShadeState) {
        switch action {
        case .close:
            removeProxyForAction(id, state: state, stage: .cleaned, reason: "quicklook-proxy-close")
            wlog("quicklook proxy: close removed proxy id=\(id)")
        case .fullScreen, .zoom:
            removeProxyForAction(id, state: state, stage: .restoring, reason: "quicklook-proxy-fullscreen")
            guard reopenQuickLookForProxyFullScreen(state: state, id: id) else { return }
            openQuickLookFullScreenFromProxy(state: state, id: id)
        case .minimize:
            removeProxyForAction(id, state: state, stage: .cleaned, reason: "quicklook-proxy-ignore-minimize")
            wlog("quicklook proxy: ignore minimize id=\(id)")
        }
    }
    func handleTrafficLight(_ action: TrafficAction, _ id: CGWindowID) {
        guard let state = shaded[id], let overlay = state.overlay else { return }
        if state.hide == .quickLookClosed {
            handleQuickLookTrafficLight(action, id: id, state: state)
            return
        }
        let f = restoreReferenceFrame(id: id, overlay: overlay)
        let pos = axPosition(fromCocoaFrame: f)
        removeProxyForForwardedAction(id, state: state)
        // 先让真窗口回到原处、可见可达，再按它自己的按钮；都在该应用程序的队列上（R5）。
        performForwardedTrafficAction(state: state, pos: pos, id: id, action: action)
    }
}

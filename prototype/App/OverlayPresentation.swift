// 卷帘条的显示与销毁、所属桌面的校正和跳走后的切回、外部唤回后的清理。
// 作为 AppDelegate 扩展实现。

import Cocoa

extension AppDelegate {
    var overlayLevel: NSWindow.Level {
        floatingOnTop ? .floating : .normal
    }

    func overlayLevel(for overlay: NSWindow) -> NSWindow.Level {
        guard !floatingOnTop, shaded.values.contains(where: { $0.overlay === overlay }) else {
            return overlayLevel
        }
        return .normal
    }

    /// 卷帘条的不透明度来自设置里的滑块（ShadeTranslucency）。没拖过滑块时沿用旧的“卷帘条半透明”开关：
    /// 开着时不透明度为 shadeTranslucentAlpha（0.82）。
    var overlayAlpha: CGFloat {
        let fraction = ShadeTranslucency.fraction()
        return fraction == ShadeTranslucency.legacyFraction ? shadeTranslucentAlpha : CGFloat(1 - fraction)
    }

    /// 某一条卷帘条应有的不透明度：缩略图窗口本身保持不透明，半透明由它的画面处理
    /// （指针停上去时变为不透明，打开“减少透明度”时一直不透明，见 Thumbnail.swift）。
    func overlayAlpha(for overlay: NSWindow) -> CGFloat {
        overlay is ShadeThumbnailWindow ? 1 : overlayAlpha
    }

    func shadedEntry(for overlay: NSWindow) -> (CGWindowID, ShadeState)? {
        shaded.first { $0.value.overlay === overlay }
    }

    func applyOverlayPresentation(_ overlay: NSWindow, bringForward: Bool) {
        if let (id, state) = shadedEntry(for: overlay),
           !enforceOverlaySpaceInvariant(id: id, state: state, reason: "apply-presentation") {
            return
        }
        overlay.level = overlayLevel(for: overlay)
        overlay.alphaValue = overlayAlpha(for: overlay)
        (overlay.contentView as? ShadeThumbnailView)?.refreshOpacity()
        if bringForward {
            overlay.orderFrontRegardless()
        }
    }

    func sourceSpaceIsActive(_ state: ShadeState) -> Bool {
        guard let sourceSpaceID = state.sourceSpaceID,
              let sourceDisplayID = state.sourceDisplayID,
              let activeSpaceID = PrivateSLSWindowMover.shared.currentSpace(displayID: sourceDisplayID) else {
            return true
        }
        return activeSpaceID == sourceSpaceID
    }

    func scheduleSourceSpaceReturnIfNeeded(id: CGWindowID, state: ShadeState) {
        guard hideMethodCanTriggerSpaceJump(state.hide),
              let displayID = state.sourceDisplayID,
              let sourceSpaceID = state.sourceSpaceID else { return }

        // 焦点交接（handOffFocus）负责预防，这里负责补救。
        // 检查必须比切换桌面的滑动动画（约 300 毫秒）快：密集检查，并用 SLSManagedDisplaySetCurrentSpace
        // 立即切回（没有滑动动画），这样只会闪一下，不会看到“跳走再滑回来”。每次检查只读一次窗口服务器，开销很小。
        // 只在收起后 0.8 秒内检查，之后的桌面变化多半是用户自己切换的（收起后主动去别的桌面），不能拉回。
        pendingSpaceReturns[id] = PendingSpaceReturn(displayID: displayID,
                                                     sourceSpaceID: sourceSpaceID,
                                                     deadline: Date().addingTimeInterval(0.8))
        wlog("space: scheduled return guard id=\(id) sid=\(sourceSpaceID)")

        for delay in [0.05, 0.1, 0.15, 0.22, 0.3, 0.42, 0.55] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restorePendingSourceSpaceIfNeeded(id: id, reason: "post-shade-\(String(format: "%.2f", delay))")
            }
        }
    }

    func restorePendingSourceSpacesIfNeeded(reason: String) {
        for id in Array(pendingSpaceReturns.keys) {
            restorePendingSourceSpaceIfNeeded(id: id, reason: reason)
        }
    }

    func restorePendingSourceSpaceIfNeeded(id: CGWindowID, reason: String) {
        guard let request = pendingSpaceReturns[id] else { return }
        guard Date() <= request.deadline,
              let state = shaded[id],
              state.lifecycleStage == .folded,
              hideMethodCanTriggerSpaceJump(state.hide) else {
            if let activeSpaceID = PrivateSLSWindowMover.shared.currentSpace(displayID: request.displayID),
               activeSpaceID != request.sourceSpaceID {
                wlog("space: return guard expired id=\(id) active=\(activeSpaceID) source=\(request.sourceSpaceID) reason=\(reason)")
            }
            pendingSpaceReturns.removeValue(forKey: id)
            return
        }

        let mover = PrivateSLSWindowMover.shared
        guard let activeSpaceID = mover.currentSpace(displayID: request.displayID) else {
            wlog("space: return guard cannot read active space id=\(id) sid=\(request.sourceSpaceID) reason=\(reason)")
            return
        }
        guard activeSpaceID != request.sourceSpaceID else { return }

        if mover.setCurrentSpace(displayID: request.displayID, sid: request.sourceSpaceID) {
            // 走到这里的只有隐藏应用程序和最小化两种方式（见 hideMethodCanTriggerSpaceJump）。
            // 隐藏应用程序只在焦点已交出、或应用程序本来就不在前台时才用，这时切换桌面说明预防没有生效，
            // 要对照前面焦点交接的日志（same-app 或 top-window 方式）查原因。
            // 最小化是其他方式都不行时的最后一招，系统会自己挑下一扇窗口接收焦点（见 FocusHandoff 的说明），
            // 可能切换桌面，在这里切回是预期行为。
            wlog("space: return guard fired sid=\(request.sourceSpaceID) from=\(activeSpaceID) id=\(id) reason=\(reason)")
            // 切回之后马上校正卷帘条所在的桌面和显示状态。
            if let state = shaded[id] {
                _ = enforceOverlaySpaceInvariant(id: id, state: state, reason: "space-return-guard")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.refreshOverlayPresentation(bringForward: false)
            }
        } else {
            wlog("space: return failed id=\(id) from=\(activeSpaceID) to=\(request.sourceSpaceID) reason=\(reason)")
        }
    }

    func hideMethodCanTriggerSpaceJump(_ hide: HideMethod) -> Bool {
        switch hide {
        case .hidden, .minimized:
            return true
        case .none, .offscreen, .privateOffscreen, .privateAlpha, .ownWindowOrderedOut, .quickLookClosed:
            return false
        }
    }

    @discardableResult
    func enforceOverlaySpaceInvariant(id: CGWindowID,
                                              state: ShadeState,
                                              reason: String) -> Bool {
        guard let overlay = state.overlay,
              let overlayID = state.overlayID,
              let sourceSpaceID = state.sourceSpaceID else { return true }

        let mover = PrivateSLSWindowMover.shared
        let overlaySpaceID = mover.windowSpace(id: overlayID)
        if overlaySpaceID == nil {
            let active = sourceSpaceIsActive(state)
            if active {
                if !overlay.isVisible {
                    overlay.alphaValue = 0
                    overlay.orderFrontRegardless()
                    revealPreparedOverlay(overlay)
                }
                wlog("space: overlay space unresolved but source active id=\(overlayID) source=\(id) sid=\(sourceSpaceID) reason=\(reason)")
                return true
            }
            overlay.orderOut(nil)
            wlog("space: overlay hidden while source inactive and overlay space unresolved id=\(overlayID) source=\(id) sid=\(sourceSpaceID) reason=\(reason)")
            return false
        }

        if overlaySpaceID == sourceSpaceID {
            let active = sourceSpaceIsActive(state)
            if active, !overlay.isVisible {
                overlay.alphaValue = 0
                overlay.orderFrontRegardless()
                if mover.windowSpace(id: overlayID) != sourceSpaceID {
                    _ = mover.moveWindow(id: overlayID, toSpace: sourceSpaceID)
                }
                revealPreparedOverlay(overlay)
                wlog("space: overlay restored on source space id=\(overlayID) source=\(id) reason=\(reason)")
            } else if !active, cgWindowIsCurrentlyOnScreen(overlayID) {
                overlay.orderOut(nil)
                wlog("space: overlay hidden off source active space id=\(overlayID) source=\(id) sid=\(sourceSpaceID) reason=\(reason)")
            }
            return active
        }

        if mover.moveWindow(id: overlayID, toSpace: sourceSpaceID) {
            wlog("space: corrected overlay id=\(overlayID) source=\(id) from=\(overlaySpaceID.map(String.init) ?? "-") to=\(sourceSpaceID) reason=\(reason)")
            return sourceSpaceIsActive(state)
        }

        overlay.orderOut(nil)
        wlog("space: invariant hid overlay id=\(overlayID) source=\(id) overlaySpace=\(overlaySpaceID.map(String.init) ?? "-") expected=\(sourceSpaceID) reason=\(reason)")
        return false
    }

    /// 原窗口已被唤回（程序坞、Command-Tab 等）时撤掉卷帘条；窗口不在原处时按展开流程放回（见 settleRevealedSource）。
    /// 原窗口的位置在该应用程序的队列上读（R5），读完回到主线程；这期间这扇窗又重新收起过，就不按旧结果处理。
    func cleanupProxyIfSourceWindowVisible(id: CGWindowID, state: ShadeState, reason: String) {
        guard state.hide != .quickLookClosed, !pendingVisibilityChecks.contains(id) else { return }
        pendingVisibilityChecks.insert(id)
        let window = WindowHandle(ax: state.element)
        let transaction = state.foldTransactionID
        let restorer = windowRestorer
        restorer.run(pid: state.pid, { restorer.control.frame(window) }, then: { [weak self] frame in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingVisibilityChecks.remove(id)
                guard let frame, let current = self.shaded[id], current.foldTransactionID == transaction,
                      self.sourceWindowLooksUserVisible(state: current, pos: frame.origin, size: frame.size) else { return }
                self.settleRevealedSource(id: id, state: current, at: frame.origin, reason: reason)
            }
        })
    }

    func prepareOverlayWindowForSpaceAssignment(_ overlay: NSWindow) {
        overlay.level = overlayLevel
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
    }

    /// 收起时焦点交给后面的应用程序，系统会把它的窗口提到最前，盖住刚显示的卷帘条，
    /// 直到前台切换的通知到达才把卷帘条放回上面（访达约 0.2 秒，看起来像整扇窗口消失了）。
    /// 交接期间卷帘条临时提高一层，交接完成后回到平常的层级，仍在最上面。
    func holdOverlayAboveFocusHandoff(_ overlay: NSWindow) {
        guard overlay.level < .floating else { return }
        overlay.level = .floating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak overlay] in
            guard let self, let overlay, overlay.isVisible, overlay.level == .floating,
                  self.shadedEntry(for: overlay) != nil else { return }
            overlay.level = self.overlayLevel(for: overlay)
            overlay.orderFrontRegardless()
        }
    }

    /// fade 为 false 时直接显示：窗口已经藏好，卷帘条又正好盖在原来的标题栏上；
    /// 再淡入的话，那 0.12 秒里会露出后面的桌面。
    /// 直接显示时立即绘制并提交给窗口服务器，否则要等这一轮主线程结束才显示到屏幕上，
    /// 而原窗口由别的应用程序自己移走、很快就消失，中间会空一下（访达约 0.2 秒）。
    func revealPreparedOverlay(_ overlay: NSWindow, fade: Bool = true) {
        // 缩略图第一次显示：截图从窗口原处缩小到缩略图，动画结束前缩略图本身不显示。
        playThumbnailEntranceIfNeeded(overlay)
        let alpha = overlayAlpha(for: overlay)
        guard fade else {
            overlay.displayIfNeeded()
            overlay.alphaValue = alpha
            CATransaction.flush()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = alpha
        }
    }

    func dismissOverlay(_ overlay: NSWindow) {
        let windowNumber = overlay.windowNumber
        overlay.ignoresMouseEvents = true
        overlay.alphaValue = 0
        overlay.orderOut(nil)
        if let proxy = overlay as? NativeProxyOverlayWindow {
            proxy.closeProgrammatically()
        } else if let strip = overlay as? OverlayWindow {
            ShadeStripPool.shared.recycle(strip)
        } else {
            overlay.close()
        }
        wlog("overlay: dismissed window=\(windowNumber)")
    }

    func refreshOverlayPresentation(bringForward: Bool = false) {
        for (id, state) in Array(shaded) {
            cleanupProxyIfSourceWindowVisible(id: id, state: state, reason: "refresh-presentation")
            if let overlay = state.overlay {
                guard enforceOverlaySpaceInvariant(id: id, state: state, reason: "refresh-presentation") else {
                    continue
                }
                applyOverlayPresentation(overlay, bringForward: bringForward)
            }
        }
    }

    nonisolated func visibleFrame(for frame: NSRect) -> NSRect {
        (screenForCocoaFrame(frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame)
    }

    nonisolated func visibleFrame(for frame: NSRect, preferredDisplayID: CGDirectDisplayID?) -> NSRect {
        screenForDisplayID(preferredDisplayID)?.visibleFrame ?? visibleFrame(for: frame)
    }

    nonisolated func clampedFrame(_ frame: NSRect, margin: CGFloat = 8,
                              preferredDisplayID: CGDirectDisplayID? = nil) -> NSRect {
        var visible = visibleFrame(for: frame, preferredDisplayID: preferredDisplayID).insetBy(dx: margin, dy: margin)
        if visible.width <= 1 || visible.height <= 1 {
            visible = visibleFrame(for: frame, preferredDisplayID: preferredDisplayID)
        }

        var result = frame
        if result.width <= visible.width {
            result.origin.x = min(max(result.origin.x, visible.minX), visible.maxX - result.width)
        } else {
            result.origin.x = visible.minX
        }
        if result.height <= visible.height {
            result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
        } else {
            result.origin.y = visible.minY
        }
        return result
    }
}

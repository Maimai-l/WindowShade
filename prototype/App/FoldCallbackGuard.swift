import Cocoa
import ApplicationServices

extension AppDelegate {
    func foldCallbackStamp(id: CGWindowID, state: ShadeState) -> FoldCallbackStamp {
        FoldCallbackStamp(window: id, pid: state.pid,
            transaction: state.foldTransactionID, hide: state.hide.rawValue,
            presentation: foldPresentationID, capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    func foldWaiterDeliveryStamp(id: CGWindowID, transaction: UUID) -> FoldCallbackStamp? {
        guard let state = shaded[id], state.foldTransactionID == transaction,
              state.lifecycleStage == .folded else { return nil }
        return foldCallbackStamp(id: id, state: state)
    }

    /// 每过一次异步或读取边界都重新核对，用来丢掉过期的结果；它不能证明外部窗口的改动是原子的。
    func foldCallbackIsCurrent(_ expected: FoldCallbackStamp,
                               maximumAge: TimeInterval = 2) -> Bool {
        guard let state = shaded[expected.window], state.sourceWindowID == expected.window,
              state.lifecycleStage == .folded else { return false }
        let current = foldCallbackStamp(id: expected.window, state: state)
        return expected.accepts(current: current, now: ProcessInfo.processInfo.systemUptime,
            maximumAge: maximumAge)
    }

    func observeFoldHide(_ hide: HideMethod, win: AXUIElement, pid: pid_t,
                         id: CGWindowID) -> FoldVerifier.Observation {
        if hide == .ownWindowOrderedOut {
            guard pid == getpid(), let local = ownWindow(id: id) else { return .unknown }
            return local.isVisible ? .visible : .hidden
        }
        // 快速查看窗口是有意关掉的：用 .optionIncludingWindow 查这扇窗口，查不到才算已隐藏；
        // 只是不在屏幕上的窗口列表里，不能证明它被关掉或最小化了。
        if hide == .quickLookClosed {
            guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            else { return .unknown }
            return list.isEmpty ? .hidden : .unknown
        }
        guard hide != .none, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              windowID(of: win) == id else { return .unknown }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(win, &actualPID) == .success, actualPID == pid else { return .unknown }
        switch hide {
        case .offscreen, .privateOffscreen:
            guard let pos = axPosition(win), let size = axSize(win),
                  pos.x.isFinite, pos.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return .unknown }
            return windowIsVisible(pos: pos, size: size) ? .visible : .hidden
        case .hidden: return app.isHidden ? .hidden : .visible
        case .minimized:
            guard let value = axObservedBoolAttribute(win, kAXMinimizedAttribute as String) else { return .unknown }
            return value ? .hidden : .visible
        case .privateAlpha:
            guard let alpha = PrivateSLSWindowMover.shared.windowAlpha(id: id),
                  alpha.isFinite, (0...1).contains(alpha) else { return .unknown }
            return alpha <= 0.05 ? .hidden : .visible
        case .none, .ownWindowOrderedOut, .quickLookClosed: return .unknown
        }
    }

    /// 结果未知时：不算成功，也不改用第二种隐藏方式重试，保留已有的恢复记录。
    /// 卷帘条留作手动恢复的入口，不当作窗口已藏好的证据。
    func retainUnconfirmedFold(id: CGWindowID, state: ShadeState) {
        guard shaded[id]?.foldTransactionID == state.foldTransactionID else { return }
        settleFoldWaiters(id: id, transaction: state.foldTransactionID, success: false)
        if let overlay = state.overlay,
           enforceOverlaySpaceInvariant(id: id, state: state, reason: "hide-unconfirmed") {
            overlay.contentView?.toolTip = "这个窗口可能没有收起，双击展开"
            revealPreparedOverlay(overlay)
        }
        quietNotice("这个窗口可能没有收起，双击展开", log: "shade: observation unknown id=\(id); recovery retained")
    }

    /// AX 观察器装在主 run loop 上，C 回调会核对这一点；
    /// 跨过排队边界的只有 Sendable 的路由、戳记和字符串。
    func receiveFoldAXNotification(routeID: UInt, notification: String) {
        guard let route = foldObserverRoutes[routeID], let state = shaded[route.window],
              state.foldTransactionID == route.transaction, state.pid == route.pid else { return }
        let stamp = foldCallbackStamp(id: route.window, state: state)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.foldObserverRoutes[routeID] == route,
                  self.foldCallbackIsCurrent(stamp) else { return }
            self.handleAXNotification(route.window, notification, expected: stamp)
        }
    }
}

func axObservedBoolAttribute(_ win: AXUIElement, _ attribute: String) -> Bool? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, attribute as CFString, &raw) == .success else { return nil }
    return observedAXBoolean(raw)
}

/// 同 AppDelegate.observeFoldHide，但可以在任意线程执行：可见与否按传进来的屏幕快照判断，
/// 不处理 WindowShade 自己的窗口（调用方已在主线程处理）。
func observeHiddenWindow(_ hide: HideMethod, win: AXUIElement, pid: pid_t, id: CGWindowID,
                         layout: ScreenLayout) -> FoldVerifier.Observation {
    if hide == .quickLookClosed {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        else { return .unknown }
        return list.isEmpty ? .hidden : .unknown
    }
    guard hide != .none, hide != .ownWindowOrderedOut,
          let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          windowID(of: win) == id else { return .unknown }
    var actualPID: pid_t = 0
    guard AXUIElementGetPid(win, &actualPID) == .success, actualPID == pid else { return .unknown }
    switch hide {
    case .offscreen, .privateOffscreen:
        guard let pos = axPosition(win), let size = axSize(win),
              pos.x.isFinite, pos.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .unknown }
        return layout.isVisible(pos: pos, size: size) ? .visible : .hidden
    case .hidden: return app.isHidden ? .hidden : .visible
    case .minimized:
        guard let value = axObservedBoolAttribute(win, kAXMinimizedAttribute as String) else { return .unknown }
        return value ? .hidden : .visible
    case .privateAlpha:
        guard let alpha = PrivateSLSWindowMover.shared.windowAlpha(id: id),
              alpha.isFinite, (0...1).contains(alpha) else { return .unknown }
        return alpha <= 0.05 ? .hidden : .visible
    case .none, .ownWindowOrderedOut, .quickLookClosed: return .unknown
    }
}

// 折叠事务：真实窗口隐藏/恢复、焦点交接、折叠验证与回滚、
// 交通灯转发、AX 观察器与会话生命周期通知。作为 AppDelegate 扩展实现。

import Cocoa

extension AppDelegate {
    func parkFocusForInactiveCapture() {
        if focusParkingWindow == nil {
            let w = OverlayWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.managed]
            focusParkingWindow = w
        }
        NSApp.activate()
        focusParkingWindow?.makeKeyAndOrderFront(nil)
    }

    func releaseFocusParking(reactivate pid: pid_t?) {
        focusParkingWindow?.orderOut(nil)
        if let pid = pid { activateApp(pid: pid) }
    }

    // MARK: 折叠事务：焦点交接
    //
    // 病灶：对焦点所在的 app/窗口执行 app-hide/minimize 时，macOS 自行挑选焦点
    // 继承人，其"下一个 app"逻辑遵循全局最近使用顺序、不限当前 Space——继承人在
    // 别的 Space 就跳 Space，继承人是同 app 其他窗口就"激活兄弟窗口"。而隐藏
    // 非前台 app/窗口没有任何焦点级联。所以隐藏之前由我们显式把焦点交给当前
    // Space 上的继承人：同 app 同 Space 其他窗口（菜单栏不变）→ 当前 Space
    // 最顶层其他 regular app 窗口（与系统自身最小化行为一致）→ Finder。
    // 不会隐藏整个 app 的藏法没有这个级联，改在藏好之后再交接（见 shade 里的说明）。
    // 返回值 = app-hide 是否安全（会不会触发系统的前台 app 重新选举）。
    // 隐藏整个 app 时，若它是前台 app，macOS 按全局最近使用顺序选举继任者，
    // 继任者的窗口在别的 Space 就会跳过去——这个选举我们无法干预。
    // 只有当焦点已交接到当前 Space 的其他窗口（或目标 app 本就不在前台）时，
    // app-hide 才不会触发选举。
    @discardableResult
    func handOffFocus(win: AXUIElement, pid: pid_t, id: CGWindowID) -> Bool {
        // 交接后撤掉截图期的焦点停靠（成功路径此前从不释放）。
        defer { focusParkingWindow?.orderOut(nil) }
        return FocusHandoff(control: FocusControlSystem()).handOff(focusHandoffRequest(win: win, pid: pid, id: id)).appHideSafe
    }

    /// 只在主线程调用：取当前的前台应用程序和卷帘条窗口号。
    func focusHandoffRequest(win: AXUIElement, pid: pid_t, id: CGWindowID) -> FocusHandoffRequest {
        FocusHandoffRequest(window: WindowHandle(ax: win), id: id, pid: pid,
                            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                            selfPID: ProcessInfo.processInfo.processIdentifier,
                            overlayIDs: overlayIDs)
    }

    // Compatibility Bool now reports only a positive observation, never an AX read failure.
    func hideTookEffect(_ hide: HideMethod, win: AXUIElement, pid: pid_t,
                       id: CGWindowID, size: CGSize) -> Bool {
        observeFoldHide(hide, win: win, pid: pid, id: id) == .hidden
    }

    func scheduleFoldVerification(id: CGWindowID) {
        guard let installed = shaded[id] else { return }
        let expected = foldCallbackStamp(id: id, state: installed)
        FoldVerifier(
            schedule: { delay, action in runOnMainQueue(after: delay, action) },
            isCurrent: { [weak self] in
                guard let self else { return false }
                let current = self.foldCallbackIsCurrent(expected)
                if !current { wlog("shade: hide verification dropped as stale id=\(id)") }
                return current
            },
            observation: { [weak self] in
                guard let self, self.foldCallbackIsCurrent(expected), let state = self.shaded[id] else { return .unknown }
                return self.observeFoldHide(state.hide, win: state.element, pid: state.pid, id: id)
            },
            salvage: { [weak self] in
                guard let self, self.foldCallbackIsCurrent(expected), let state = self.shaded[id],
                      state.hide == .minimized, windowID(of: state.element) == id else { return false }
                var pid: pid_t = 0
                guard AXUIElementGetPid(state.element, &pid) == .success, pid == state.pid,
                      self.foldCallbackIsCurrent(expected) else { return false }
                // Retry only the SAME strategy. Crossing from hidden/offscreen/alpha to
                // minimized would need a restore record for both attempted mutations.
                setAXMinimized(state.element, true)
                return true
            },
            salvagedObservation: { [weak self] in
                guard let self, self.foldCallbackIsCurrent(expected), let state = self.shaded[id] else { return .unknown }
                return self.observeFoldHide(.minimized, win: state.element, pid: state.pid, id: id)
            },
            result: { [weak self] result in
                guard let self, self.foldCallbackIsCurrent(expected), let state = self.shaded[id] else { return }
                wlog("shade: hide verification id=\(id) hide=\(state.hide) result=\(result)")
                switch result {
                case .hidden:
                    self.revealOverlayAfterVerification(id: id, state: state)
                case .unknown:
                    self.retainUnconfirmedFold(id: id, state: state)
                case .visible:
                    self.rollbackFoldTransaction(id: id, expectedTransaction: expected.transaction)
                }
            }
        ).start()
    }

    func revealOverlayAfterVerification(id: CGWindowID, state: ShadeState) {
        guard shaded[id]?.foldTransactionID == state.foldTransactionID else { return }
        if let overlay = state.overlay,
           enforceOverlaySpaceInvariant(id: id, state: state, reason: "hide-verified") {
            overlay.contentView?.toolTip = nil
            revealPreparedOverlay(overlay)
        }
        // The exact transaction settles even when its proxy is on another Space.
        settleFoldWaiters(id: id, transaction: state.foldTransactionID, success: true)
    }

    // 回滚折叠事务：按已尝试的隐藏方式逐项逆操作（此前的回滚漏了这步，
    // 曾把实际已 app-hide 的 Safari 留在隐藏态、无卷帘条），再恢复几何、
    // 撤 overlay/状态/journal。
    func rollbackFoldTransaction(id: CGWindowID, expectedTransaction: UUID? = nil) {
        if let expectedTransaction, shaded[id]?.foldTransactionID != expectedTransaction { return }
        guard let state = shaded[id] else { return }
        if let expectedTransaction, state.foldTransactionID != expectedTransaction { return }
        switch state.hide {
        case .hidden:
            if NSRunningApplication(processIdentifier: state.pid)?.unhide() != true {
                _ = setAXAppHidden(pid: state.pid, false)
            }
        case .minimized:
            setAXMinimized(resolvedWindowElement(for: state), false)
        case .privateAlpha:
            let alpha = windowHider.takeOriginalAlpha(id: id) ?? 1
            _ = PrivateSLSWindowMover.shared.setAlpha(id: id, alpha: alpha)
        case .none, .offscreen, .privateOffscreen, .ownWindowOrderedOut, .quickLookClosed:
            break
        }
        _ = applyRestoredGeometry(state, to: state.originalPosition, label: "rollback", reason: "restore")
        forceCleanup(id, preserveRecovery: true)
        verifyRestoredWindow(state, to: state.originalPosition, completion: nil)
        quietNotice("这个窗口暂时收不起来",
                    log: "shade: transaction rolled back id=\(id) app=\(state.appName)")
    }

    func activateApp(pid: pid_t) {
        guard let app = runningApp(pid: pid) else { return }
        app.unhide()
        app.activate(options: [])
    }

    func bringRestoredWindowToFront(_ win: AXUIElement, pid: pid_t, reason: String) {
        let id=windowID(of:win),token=UUID()
        if let id { restoreFocusTokens[id]=token }
        func attempt(_ label: String) {
            if let id { guard restoreFocusTokens[id] == token,shaded[id] == nil,!shadeOperationIDs.contains(id) else { return } }
            // 只在 app 尚未前台时 activate：250ms 内连发 activate 会反复重启
            // 菜单栏的交叉淡入，赶上时机就把两套菜单叠印留在屏幕上（系统级
            // 渲染残影，实测截图 2026-07）。激活已生效的重试只做 AX raise/focus
            // （不触碰菜单栏）；unhide 保留（.hidden 恢复路径依赖，且幂等）。
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                activateApp(pid: pid)
            } else {
                runningApp(pid: pid)?.unhide()
            }
            raiseAXWindow(win)
            focusAXWindow(win, pid: pid)
            wlog("front: \(reason) \(label)")
        }

        attempt("immediate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { attempt("after-80ms") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attempt("after-250ms") }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { [weak self] in
            if let id,self?.restoreFocusTokens[id] == token { self?.restoreFocusTokens.removeValue(forKey:id) }
        }
    }

    func prepareForwardedTrafficAction(_ win: AXUIElement, pid: pid_t, reason: String) {
        activateApp(pid: pid)
        raiseAXWindow(win)
        focusAXWindow(win, pid: pid)
        wlog("front: \(reason) immediate-only")
    }

    func restoredWindowIsGeometryReady(_ win: AXUIElement) -> Bool {
        guard let pos = axPosition(win), let size = axSize(win) else { return false }
        return pos.x.isFinite && pos.y.isFinite && size.width > 1 && size.height > 1
    }

    func buttonIsReady(_ win: AXUIElement, _ attr: String) -> Bool {
        guard let button = axButtonElement(win, attr),
              let pos = axPosition(button),
              let size = axSize(button),
              size.width > 1,
              size.height > 1,
              pos.x.isFinite,
              pos.y.isFinite else { return false }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &ref) == .success,
           let value = ref {
            return cfBooleanValue(value) ?? true
        }
        return true
    }

    func forwardedTrafficActionSucceeded(state: ShadeState, id: CGWindowID,
                                                 win: AXUIElement,
                                                 action: TrafficAction) -> Bool {
        switch action {
        case .minimize:
            return axBoolAttribute(win, kAXMinimizedAttribute as String)
        case .close:
            guard runningApp(pid: state.pid) != nil else { return true }
            let windows = appWindows(pid: state.pid)
            guard !windows.isEmpty else { return true }
            let sameWindowExists = windows.contains { window in
                if let currentID = windowID(of: window), currentID == id { return true }
                let expectedTitle = cleanDisplayTitle(state.title)
                return !expectedTitle.isEmpty && cleanDisplayTitle(axTitle(window)) == expectedTitle
            }
            guard sameWindowExists else { return true }
            guard let pos = axPosition(win), let size = axSize(win) else { return true }
            return !windowIsVisible(pos: pos, size: size)
        case .zoom, .fullScreen:
            return true
        }
    }

    func performForwardedTrafficAction(state: ShadeState, pos: CGPoint,
                                               id: CGWindowID, action: TrafficAction) {
        let attrs: [String]
        switch action {
        case .close:
            attrs = [kAXCloseButtonAttribute as String]
        case .minimize:
            attrs = [kAXMinimizeButtonAttribute as String]
        case .zoom:
            attrs = [kAXFullScreenButtonAttribute as String, kAXZoomButtonAttribute as String]
        case .fullScreen:
            attrs = [kAXFullScreenButtonAttribute as String]
        }

        func retryOrFallback(_ index: Int, note: String) {
            if action == .minimize, index >= forwardedTrafficRetryDelays.count - 1 {
                let win = resolvedWindowElement(for: state)
                setAXMinimized(win, true)
                wlog("traffic: minimize fallback AXMinimized id=\(id) note=\(note)")
                return
            }
            if action == .zoom, index >= forwardedTrafficRetryDelays.count - 1 {
                pressFullScreenShortcut()
                wlog("traffic: zoom fallback ctrl-cmd-f id=\(id) note=\(note)")
                return
            }
            if action == .fullScreen, index >= forwardedTrafficRetryDelays.count - 1 {
                pressFullScreenShortcut()
                wlog("traffic: fullscreen fallback ctrl-cmd-f id=\(id) note=\(note)")
                return
            }
            if action == .close, index >= forwardedTrafficRetryDelays.count - 1 {
                wlog("traffic: close failed id=\(id) note=\(note)")
                return
            }
            schedule(index + 1, note: note)
        }

        func verifyAfterAXPress(_ win: AXUIElement, index: Int, attr: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                let latest = self.resolvedWindowElement(for: state)
                if self.forwardedTrafficActionSucceeded(state: state, id: id,
                                                        win: latest, action: action) {
                    wlog("traffic: \(action) AXPress verified id=\(id) attr=\(attr) attempt=\(index)")
                    return
                }
                retryOrFallback(index, note: "axpress-no-effect")
            }
        }

        func verifyAfterPointerClick(_ win: AXUIElement, index: Int, attr: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                let latest = self.resolvedWindowElement(for: state)
                if self.forwardedTrafficActionSucceeded(state: state, id: id,
                                                        win: latest, action: action) {
                    wlog("traffic: \(action) pointer-click verified id=\(id) attr=\(attr) attempt=\(index)")
                    return
                }
                if pressAXButton(latest, attr) {
                    wlog("traffic: \(action) AXPress fallback id=\(id) attr=\(attr) attempt=\(index)")
                    verifyAfterAXPress(latest, index: index, attr: attr)
                    return
                }
                retryOrFallback(index, note: "click-no-effect")
            }
        }

        func attempt(_ index: Int) {
            let win = applyRestoredGeometry(state, to: pos,
                                            label: "traffic-\(index)",
                                            reason: "traffic \(action) id=\(id)")
            prepareForwardedTrafficAction(win, pid: state.pid,
                                          reason: "traffic-\(action) id=\(id) attempt=\(index)")
            guard restoredWindowIsGeometryReady(win) else {
                schedule(index + 1, note: "geometry-not-ready")
                return
            }

            if let attr = attrs.first(where: { buttonIsReady(win, $0) }) {
                // Forward as a real pointer click at the real traffic-light
                // center. Nonstandard apps such as WeChat may ignore AXPress
                // here, but they still honor the native mouse path.
                if clickAXButton(win, attr) {
                    wlog("traffic: \(action) pointer-click forwarded id=\(id) attr=\(attr) attempt=\(index)")
                    if action == .zoom || action == .fullScreen { return }
                    verifyAfterPointerClick(win, index: index, attr: attr)
                    return
                }
                if pressAXButton(win, attr) {
                    wlog("traffic: \(action) AXPress forwarded id=\(id) attr=\(attr) attempt=\(index)")
                    verifyAfterAXPress(win, index: index, attr: attr)
                    return
                }
            }

            retryOrFallback(index, note: "button-not-ready")
        }

        func schedule(_ index: Int, note: String) {
            guard index < forwardedTrafficRetryDelays.count else {
                wlog("traffic: \(action) failed id=\(id) note=\(note)")
                return
            }
            let delay = forwardedTrafficRetryDelays[index]
            wlog("traffic: \(action) retry id=\(id) attempt=\(index) delay=\(String(format: "%.2f", delay)) note=\(note)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                attempt(index)
            }
        }

        attempt(0)
    }

    func showRealWindowManagementPopover(_ id: CGWindowID) {
        guard let state = shaded[id], let overlay = state.overlay else { return }
        guard state.hide != .quickLookClosed else {
            wlog("proxy wm: skip QuickLook proxy id=\(id)")
            return
        }
        let pos = axPosition(fromCocoaFrame: restoreReferenceFrame(id: id, overlay: overlay))
        removeProxyForForwardedAction(id, state: state)
        let immediate = restoreWindow(state, to: pos)
        prepareForwardedTrafficAction(immediate, pid: state.pid,
                                      reason: "wm-popover id=\(id) immediate")

        let delays: [TimeInterval] = [0.05, 0.12, 0.22, 0.38, 0.60]
        func attempt(_ index: Int) {
            let win = applyRestoredGeometry(state, to: pos,
                                            label: "wm-\(index)",
                                            reason: "wm-popover id=\(id)")
            prepareForwardedTrafficAction(win, pid: state.pid,
                                          reason: "wm-popover id=\(id) attempt=\(index)")
            let attrs = [kAXFullScreenButtonAttribute as String, kAXZoomButtonAttribute as String]
            if let attr = attrs.first(where: { buttonIsReady(win, $0) }),
               hoverAXButtonForWindowManagement(win, attr) {
                wlog("proxy wm: forwarded hover to real green button id=\(id) attr=\(attr) attempt=\(index)")
                return
            }
            if index + 1 < delays.count {
                wlog("proxy wm: retry hover id=\(id) attempt=\(index + 1)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delays[index + 1]) {
                    attempt(index + 1)
                }
            } else {
                wlog("proxy wm: cannot find real green button id=\(id)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delays[0]) {
            attempt(0)
        }
    }


    // MARK: 展开

    func windowIsParkedOffscreen(id: CGWindowID, win: AXUIElement, size: CGSize) -> Bool {
        if let cgVisible = cgWindowIsVisible(id: id, fallbackSize: size) {
            return !cgVisible
        }
        guard let pos = axPosition(win) else { return false }
        return !windowIsVisible(pos: pos, size: size)
    }

    func ownWindow(id: CGWindowID?) -> NSWindow? {
        guard let id else { return nil }
        return NSApp.windows.first { window in
            cgWindowID(for: window) == id
        }
    }

    func orderOutOwnWindowIfNeeded(id: CGWindowID?, pid: pid_t, reason: String) -> HideMethod? {
        guard pid == getpid(), let window = ownWindow(id: id) else { return nil }
        window.orderOut(nil)
        guard !window.isVisible else {
            wlog("    own window orderOut failed id=\(id ?? 0) reason=\(reason)")
            return nil
        }
        wlog("    own window → orderedOut id=\(id ?? 0) reason=\(reason)")
        return .ownWindowOrderedOut
    }

    /// 移开原窗口。WindowShade 自己的窗口在主线程 orderOut；其他应用程序的窗口交给
    /// WindowHider（Platform/WindowHider.swift）在后台队列上做，做完在主线程调用 completion。
    /// delay：开始移开之前等多久（卷帘条刚亮出来时等两帧，让它先上屏）。
    func hideWindowInBackground(_ win: AXUIElement, pid: pid_t, originalPosition pos: CGPoint,
                                size: CGSize, policy: ShadePolicy, appHideSafe: Bool,
                                delay: TimeInterval = 0, handOffFocusAfter: Bool = false,
                                completion: @escaping (HideMethod) -> Void) {
        let id = windowID(of: win)
        if let hide = orderOutOwnWindowIfNeeded(id: id, pid: pid, reason: "shade") {
            if handOffFocusAfter, let id { _ = handOffFocus(win: win, pid: pid, id: id) }
            completion(hide)
            return
        }
        let request = HideRequest(window: WindowHandle(ax: win), id: id, pid: pid, position: pos, size: size,
                                  policy: policy, appHideSafe: appHideSafe, layout: .current())
        // 窗口藏好之后键盘别再落到它身上：交出焦点和移开放在同一个后台任务里，主线程不等。
        let focusRequest = handOffFocusAfter ? id.map { focusHandoffRequest(win: win, pid: pid, id: $0) } : nil
        let hider = windowHider
        let finish = HandOff(completion)
        windowHideQueue.asyncAfter(deadline: .now() + delay) {
            let hide = hider.hide(request)
            if let focusRequest { _ = FocusHandoff(control: FocusControlSystem()).handOff(focusRequest) }
            DispatchQueue.main.async { finish.value(hide) }
        }
    }

    func safeRestorePosition(for state: ShadeState, desired pos: CGPoint) -> CGPoint {
        guard !windowIsVisible(pos: pos, size: state.originalSize) else { return pos }
        let frame = cocoaFrame(fromAXPosition: pos, size: state.originalSize)
        let clamped = clampedFrame(frame, margin: 16, preferredDisplayID: state.sourceDisplayID)
        return axPosition(fromCocoaFrame: clamped)
    }

    // trustFallback：调用方已经在别处确认过这个元素可用（标题栏双击时刚读过它的
    // 位置和尺寸），这里直接用，一次 IPC 都不发。
    //
    // 这里曾经再做一次存活探测，代价被严重低估：单个 AX 属性读只有在目标 App
    // 空闲时才是 0.1ms，而级联折叠时它正忙着隐藏自己，实测一次 axPosition 要
    // 19ms，20 个窗口就是 375ms。而且这次探测是多余的——预热阶段已经验证过。
    // 元素万一在预热之后失效，shade() 开头的 axPosition/axSize 会读不到而干净地
    // 中止这一个窗口的折叠，不会造成错误状态。
    //
    // 不做 id 比对：传进来的 id 来自 windowID(of:)，那个函数优先用几何+标题匹配，
    // 和 _AXUIElementGetWindow 对某些 App 给出的值并不一致，比对会系统性失配，
    // 结果每个窗口先付一次失败比对再付一次完整枚举。
    func refreshedWindowElement(id: CGWindowID, fallback: AXUIElement,
                                trustFallback: Bool = false) -> AXUIElement {
        if trustFallback { return fallback }
        if let info=cgWindowInfo(id),let pid=(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
           let current=appWindows(pid:pid).first(where:{windowID(of:$0) == id}) { return current }
        return fallback
    }

    func resolvedWindowElement(for state: ShadeState) -> AXUIElement {
        // 存活即可信。这里同样不能拿 id 做精确比对：state.sourceWindowID 来自
        // windowID(of:)，那是几何+标题匹配的结果，和 _AXUIElementGetWindow 对某些
        // App 并不一致，比对会系统性失配，于是每次几何校正都先付一次失败比对再付
        // 一次整 App 枚举。而这里本来就不需要精确校验：元素死了写入会失败，
        // applyRestoredGeometry 会重新解析后重写。
        if axPosition(state.element) != nil { return state.element }

        let windows = appWindows(pid: state.pid)
        guard !windows.isEmpty else { return state.element }

        if let match = windows.first(where: { windowID(of: $0) == state.sourceWindowID }) {
            return match
        }
        // A surviving sibling (even the sole remaining window) is not the source.
        // Keep the original element on failure; AX then fails safely instead of moving another window.
        return state.element
    }

    // verify=false 时跳过回读。回读的两次 AX 往返只用来拼日志里的 actual=（不参与
    // 任何判断），而重试阶梯的中间几档每个窗口都要付一次——批量恢复 15 个窗口时
    // 就是上百次纯日志用途的 IPC。首档与末档仍然回读，"App 自己把窗口挪回去了"
    // 这类问题照样看得见；AX 报错时无条件回读。
    // element 非空时直接复用上一档解析好的元素：同一个窗口在阶梯的四档之间不会
    // 变，而重新解析要么是一次整 App 枚举、要么是四次 AX 读。元素真的失效了
    // （App 在 unhide 后重建了 AX 元素，正是这条阶梯存在的理由）写入会失败，
    // 那时再解析一次重写，结果与每档都重新解析一致。
    @discardableResult
    func applyRestoredGeometry(_ state: ShadeState, to pos: CGPoint,
                                       label: String, reason: String,
                                       verify: Bool = true,
                                       element: AXUIElement? = nil) -> AXUIElement {
        var win = element ?? resolvedWindowElement(for: state)
        let safePos = safeRestorePosition(for: state, desired: pos)
        var sizeErr = setAXSize(win, state.originalSize)
        var posErr = setAXPositionReturningError(win, safePos)
        if element != nil, sizeErr != .success || posErr != .success {
            win = resolvedWindowElement(for: state)
            sizeErr = setAXSize(win, state.originalSize)
            posErr = setAXPositionReturningError(win, safePos)
        }
        let failed = sizeErr != .success || posErr != .success
        let actual: String
        if verify || failed {
            let actualPos = axPosition(win)
            let actualSize = axSize(win)
            actual = actualPos.flatMap { p in
                actualSize.map { s in " actual=(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))" }
            } ?? " actual=<unavailable>"
        } else {
            actual = ""
        }
        wlog("geometry: \(reason) \(label) target=(\(Int(safePos.x)),\(Int(safePos.y)) \(Int(state.originalSize.width))x\(Int(state.originalSize.height))) err=(size:\(sizeErr),pos:\(posErr))\(actual)")
        if safePos != pos {
            wlog("restore: clamped invisible target app=\(state.appName) pos=(\(Int(safePos.x)),\(Int(safePos.y)))")
        }
        return win
    }

    // 按隐藏方式把真窗口恢复可见，并放到指定位置
    @discardableResult
    func restoreWindow(_ state: ShadeState, to pos: CGPoint) -> AXUIElement {
        switch state.hide {
        case .none:      break
        case .offscreen: break
        case .privateOffscreen:
            if PrivateSLSWindowMover.shared.moveWindow(id: state.sourceWindowID, to: pos) {
                wlog("restore: private SLS move back id=\(state.sourceWindowID) target=(\(Int(pos.x)),\(Int(pos.y)))")
            } else {
                wlog("restore: private SLS move back unavailable id=\(state.sourceWindowID)")
            }
        case .privateAlpha:
            let alpha = windowHider.takeOriginalAlpha(id: state.sourceWindowID) ?? 1
            if PrivateSLSWindowMover.shared.setAlpha(id: state.sourceWindowID, alpha: alpha) {
                wlog("restore: private SLS alpha back id=\(state.sourceWindowID) alpha=\(String(format: "%.2f", alpha))")
            } else {
                wlog("restore: private SLS alpha restore unavailable id=\(state.sourceWindowID)")
            }
        case .hidden:
            if NSRunningApplication(processIdentifier: state.pid)?.unhide() != true {
                _ = setAXAppHidden(pid: state.pid, false)
            }
        case .minimized:
            // hide/minimize 周期后原 AX 元素可能失效（Safari 常见），先重新解析，
            // 否则解除的是无效元素或错误窗口，表现为"恢复失败/几何漂移"。
            setAXMinimized(resolvedWindowElement(for: state), false)
        case .ownWindowOrderedOut:
            if let window = ownWindow(id: state.sourceWindowID) {
                let safePos = safeRestorePosition(for: state, desired: pos)
                window.setFrame(cocoaFrame(fromAXPosition: safePos, size: state.originalSize), display: true)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                wlog("restore: own window ordered front id=\(state.sourceWindowID) target=(\(Int(safePos.x)),\(Int(safePos.y)))")
            } else {
                wlog("restore: own window unavailable id=\(state.sourceWindowID)")
            }
        case .quickLookClosed: break
        }
        return applyRestoredGeometry(state, to: pos, label: "immediate", reason: "restore")
    }

    func cancelRestorePin(for id: CGWindowID) {
        restorePinTokens[id] = UUID()
    }

    func pinRestoredWindow(_ state: ShadeState, to pos: CGPoint, reason: String) {
        let id = state.sourceWindowID
        let token = UUID()
        restorePinTokens[id] = token

        // 前几次尝试只校正几何，最后一次才 raise+focus：旧实现每次尝试都重新
        // 激活/聚焦，restoreAll 批量展开时会造成焦点连环跳（每次 3~4 次 focus）。
        var resolvedElement: AXUIElement?
        func attempt(_ label: String, focus: Bool, verify: Bool = true) {
            guard restorePinTokens[id] == token else { return }
            let win = marking("restore: 几何校正") {
                applyRestoredGeometry(state, to: pos, label: label, reason: reason,
                                      verify: verify, element: resolvedElement)
            }
            resolvedElement = win
            if focus {
                raiseAXWindow(win)
                focusAXWindow(win, pid: state.pid)
            }
        }

        // Safari 等 app 从 unhide/unminimize 自恢复窗口帧可晚于 550ms（"大窗口
        // 恢复成小窗口"的窗口期），只对这两种 hide 方式追加一次晚校验。
        let needsLatePin = state.hide == .hidden || state.hide == .minimized
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { attempt("after-80ms", focus: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            attempt("after-250ms", focus: false, verify: false)
        }
        if needsLatePin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                attempt("after-550ms", focus: false, verify: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.10) {
                // 这时还原动画早已走完：窗口又是最小化的，是人（或 App）刚把它收回去了，不再拉出来、不抢焦点。
                if let win = resolvedElement, axBoolAttribute(win, kAXMinimizedAttribute as String) {
                    self.restorePinTokens[id] = UUID()
                    wlog("restore: id=\(id) minimized again after restore; late pin skipped")
                    return
                }
                attempt("after-1100ms", focus: true)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { attempt("after-550ms", focus: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsLatePin ? 1.25 : 0.70)) { [weak self] in
            if self?.restorePinTokens[id] == token {
                self?.restorePinTokens.removeValue(forKey: id)
            }
        }
    }

    func resizeShadedWindowFromProxy(_ id: CGWindowID, proxyFrame: NSRect) {
        guard var state = shaded[id], state.appearanceMode == .proxyTitleBar else { return }
        guard (state.overlay as? NativeProxyOverlayWindow)?.allowsHorizontalResize != false else { return }
        if let overlay = state.overlay as? NativeProxyOverlayWindow,
           abs(proxyFrame.height - overlay.fixedTitlebarHeight) > 0.5 {
            var corrected = proxyFrame
            corrected.origin.y += proxyFrame.height - overlay.fixedTitlebarHeight
            corrected.size.height = overlay.fixedTitlebarHeight
            overlay.setFrame(corrected, display: true)
        }
        let oldSize = state.originalSize
        guard oldSize.width > 1, oldSize.height > 1 else { return }
        let minWidth = (state.overlay as? NativeProxyOverlayWindow)?.minimumReadableWidth ?? 260
        let newWidth = max(minWidth, proxyFrame.width)
        let aspect = oldSize.height / oldSize.width
        let newHeight = max(proxyTitleBarHeight, newWidth * aspect)
        let newSize = CGSize(width: newWidth, height: newHeight)
        if abs(newSize.width - oldSize.width) < 0.5 && abs(newSize.height - oldSize.height) < 0.5 {
            return
        }
        state.originalSize = newSize
        shaded[id] = state
        arrangedOverlayFrames.removeValue(forKey: id)
        syncRestoreJournal(id: id, fromOverlayFrame: state.overlay?.frame ?? proxyFrame, restoredSize: newSize)
        wlog("resize: proxy id=\(id) width=\(Int(newWidth)) restoredSize=(\(Int(newSize.width))x\(Int(newSize.height)))")
    }

    // 监听窗口被外部唤回：app 显示(⌘Tab 取消隐藏) / 取消最小化(点 Dock)。
    // app activated 只说明应用拿到焦点，不代表真实窗口已经回到用户可见位置；不能据此展开。
    func makeRevealObserver(pid: pid_t, win: AXUIElement, id: CGWindowID, transaction: UUID) -> AXObserver? {
        guard shaded[id]?.foldTransactionID == transaction, foldObserverSerial < UInt(Int.max) else { return nil }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axWindowCallback, &observer) == .success, let obs = observer else { return nil }
        foldObserverSerial += 1
        let serial = foldObserverSerial
        let route = FoldObserverRoute(window: id, pid: pid, transaction: transaction)
        foldObserverRoutes[serial] = route
        let app = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(bitPattern: serial)
        let results = [
            AXObserverAddNotification(obs, app, kAXApplicationShownNotification as CFString, refcon),
            AXObserverAddNotification(obs, win, kAXWindowDeminiaturizedNotification as CFString, refcon),
            AXObserverAddNotification(obs, win, kAXUIElementDestroyedNotification as CFString, refcon)
        ]
        guard results.contains(.success), shaded[id]?.foldTransactionID == transaction else {
            foldObserverRoutes.removeValue(forKey: serial)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        return obs
    }

    func removeObserver(_ state: ShadeState) {
        // Withdraw routes before removing a source. Old queued notifications remain harmless.
        for (serial, route) in foldObserverRoutes where route.transaction == state.foldTransactionID {
            foldObserverRoutes.removeValue(forKey: serial)
        }
        if let obs = state.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }

    func handleAXNotification(_ id: CGWindowID, _ notification: String, expected: FoldCallbackStamp) {
        guard foldCallbackIsCurrent(expected), let state = shaded[id] else { return }
        if notification == (kAXUIElementDestroyedNotification as String) {
            if state.hide == .quickLookClosed {
                wlog("quicklook: ignore expected destroyed notification id=\(id)")
                return
            }
            // A delayed destruction notification is a hint, not permission to act on
            // a reused ID. Require a successful full-membership query with no result.
            guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                  windows.isEmpty, foldCallbackIsCurrent(expected) else { return }
            forceCleanup(id)
            return
        }
        if notification == (kAXWindowDeminiaturizedNotification as String) {
            if state.hide == .minimized {
                guard windowID(of: state.element) == id,
                      axObservedBoolAttribute(state.element, kAXMinimizedAttribute as String) == false,
                      foldCallbackIsCurrent(expected) else { return }
                unshade(id)
            }
        } else if notification == (kAXApplicationShownNotification as String) {
            if MainActor.assumeIsolated({ glance.holdsReveal(id) }) {
                wlog("ignore app reveal caused by glance id=\(id) app=\(state.appName)")
                return
            }
            if Date() < state.ignoreAppRevealUntil {
                wlog("ignore early app reveal notification=\(notification) id=\(id) app=\(state.appName)")
                return
            }
            if state.hide == .hidden {
                guard let app = runningApp(pid: state.pid), !app.isTerminated, !app.isHidden,
                      windowID(of: state.element) == id, foldCallbackIsCurrent(expected) else { return }
                unshade(id)
            }
        } else {
            wlog("ignore reveal notification=\(notification) id=\(id) app=\(state.appName)")
        }
    }

    @objc func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for id in shaded.filter({ $0.value.pid == app.processIdentifier }).map(\.key) {
            forceCleanup(id)
        }
    }

    @objc func frontmostApplicationChanged(_ note: Notification) {
        // 卡顿归因：这几条系统回调以前不在任何标记里，出了长卡顿只能看到「未标记」。
        MainThreadActivity.push("system: 前台应用变化")
        defer { MainThreadActivity.pop() }
        hideMenuHoverPreview()
        MainActor.assumeIsolated {
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app {
                glance.takeOverUnhiddenSessions(for: app.processIdentifier) { id in
                    _ = self.unshade(id)
                }
            }
            // 点卷帘条会让 WindowShade 自己到前台：那是在卷帘条上操作（比如双击展开），不收看一眼，
            // 否则第一下点击就把卡片收走，第二下展开前那几帧原处是空的。
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                glance.cancelAll(reason: "frontmost-app")
            }
        }
        refreshOverlayPresentation()
    }









    @objc func screenParametersChanged(_ note: Notification) {
        MainThreadActivity.push("system: 屏幕参数变化")
        defer { MainThreadActivity.pop() }
        // 菜单栏时隐时现、Dock 高度差一点也会发这条通知（接 Studio Display 的 Mac 上每隔几秒
        // 一次）。只有显示器本身变了才作废进行中的收起、找回屏幕外的窗口；可用区域变化不算：
        // 收起时把窗口最小化，Dock 多一个图标就可能缩放、改变可用区域，若因此作废，卷帘条就再也等不到显示。
        let layout = DisplayLayout.current()
        let displaysChanged = layout != lastDisplayLayout
        lastDisplayLayout = layout
        if displaysChanged {
            foldPresentationID = UUID()
            wlog("screen: displays changed count=\(layout.screens.count)")
        }
        for (id, state) in shaded {
            guard let overlay = state.overlay else { continue }
            let oldFrame = overlay.frame
            guard !overlayIsReachable(oldFrame) else { continue }
            let newFrame = clampedFrame(oldFrame, margin: 8, preferredDisplayID: state.sourceDisplayID)
            if !framesAlmostEqual(oldFrame, newFrame) {
                overlay.setFrame(newFrame, display: true)
                if arrangedOverlayFrames[id] == nil {
                    syncRestoreJournal(id: id, fromOverlayFrame: newFrame)
                }
                wlog("screen: clamped overlay id=\(id) frame=(\(Int(newFrame.minX)),\(Int(newFrame.minY)) \(Int(newFrame.width))x\(Int(newFrame.height)))")
            }
        }
        if displaysChanged, shaded.isEmpty {
            rescueOffscreenWindows(silent: true)
        }
    }

    @objc func activeSpaceChanged(_ note: Notification) {
        foldPresentationID = UUID()
        MainThreadActivity.push("system: 切换桌面")
        defer { MainThreadActivity.pop() }
        restorePendingSourceSpacesIfNeeded(reason: "active-space-changed")
        hideMenuHoverPreview()
        MainActor.assumeIsolated {
            glance.cancelAll(reason: "space-changed")
        }
        menuPreviewHoverID = nil
        menuPreviewAnchor = nil
        // 重操作（逐窗口 AX/WindowServer 查询 + overlay space enforce）合并防抖：
        // 连续切 Space / 切换动画期间的通知风暴只结算一次。
        spaceRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.spaceRefreshWorkItem = nil
            self.refreshOverlayPresentation(bringForward: false)
            wlog("space: active space changed; overlays enforced in assigned spaces")
        }
        spaceRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

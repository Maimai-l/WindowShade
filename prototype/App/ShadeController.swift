// 收起入口：解析聚焦窗口、制定收起计划、截图和主 shade 事务。
// 作为 AppDelegate 扩展实现；隐藏/恢复/验证见 FoldTransaction。

import Cocoa
import ScreenCaptureKit

extension AppDelegate {
    func retargetToActiveSpaceWindow(pid: pid_t) -> (AXUIElement, CGWindowID)? {
        let onScreen = WindowListCache.shared.onScreenWindows()
        // 屏幕上的窗口列表从前往后排：取这个应用程序第一个不透明的第 0 层窗口（不含卷帘条）。
        guard let candidate = onScreen.first(where: { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == pid,
                  ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = cgWindowBounds(info), bounds.width > 1, bounds.height > 1,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  !overlayIDs.contains(CGWindowID(number.uint32Value)) else { return false }
            return true
        }),
        let number = candidate[kCGWindowNumber as String] as? NSNumber,
        let bounds = cgWindowBounds(candidate) else { return nil }

        var best: (win: AXUIElement, delta: CGFloat)?
        for win in appWindows(pid: pid) {
            guard let pos = axPosition(win), let size = axSize(win) else { continue }
            let delta = frameDistance(CGRect(origin: pos, size: size), bounds)
            if delta <= 96, best == nil || delta < best!.delta {
                best = (win, delta)
            }
        }
        guard let found = best?.win else { return nil }
        return (found, CGWindowID(number.uint32Value))
    }
    func toggle() {
        guard ensureAccessibility() else {
            showPermissionOnboardingIfNeeded(force: true)
            quietNotice("要先允许辅助功能", log: "toggle: 无辅助功能权限")
            return
        }
        if let shadedID = currentShadedOverlayID() {
            wlog("toggle: current shaded overlay id=\(shadedID) → unshade")
            unshade(shadedID)
            return
        }
        guard let focusedWin = focusedWindow(), let focusedID = windowID(of: focusedWin) else {
            quietNotice("没有可以收起的窗口", log: "toggle: 取不到聚焦窗口/windowID")
            return
        }
        var win = focusedWin
        var id = focusedID
        if isDesktopWidgetWindow(id: id) {
            quietNotice("桌面小组件不能收起", log: "toggle: reject desktop widget id=\(id)")
            return
        }
        // 聚焦窗口不在当前桌面（已收起的除外：它们的原窗口本来就不在屏幕上，要走下面的 unshade 分支）时，
        // 改为收起这个应用程序在当前桌面的最前面一扇窗口；一扇都没有就不收起，
        // 避免“收起当前窗口”收起了另一个桌面上的窗口。
        if shaded[id] == nil, !cgWindowIsCurrentlyOnScreen(id) {
            var focusedPid: pid_t = 0
            AXUIElementGetPid(win, &focusedPid)
            if let (retargetWin, retargetID) = retargetToActiveSpaceWindow(pid: focusedPid) {
                wlog("toggle: focused window id=\(id) off active space → retarget id=\(retargetID)")
                win = retargetWin
                id = retargetID
            } else {
                quietNotice("这个桌面没有可以收起的窗口",
                            log: "toggle: focused id=\(id) off active space; no on-space window")
                return
            }
        }
        wlog("toggle: app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") id=\(id) alreadyShaded=\(shaded[id] != nil)")
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        if isStickies(pid: pid) {
            // 便笺自己会收起（双击它的标题栏）。WindowShade 不替它合成双击，也不收它的窗口。
            wlog("toggle: skip Stickies id=\(id)")
            return
        }

        if shaded[id] != nil {
            unshade(id)
        } else {
            shade(win, id)
        }
    }
    /// 读好窗口信息交给 FoldPlanner（Domain/FoldPlanner.swift）决定收不收、怎么收。
    func makeShadePlan(pos: CGPoint, size: CGSize,
                               pid: pid_t, profile: WindowChromeProfile,
                               options: ShadeInvocationOptions,
                               fullScreen: Bool, minimized: Bool, hasSheet: Bool,
                               appHasModalDialog: Bool, quickLookReopenable: Bool) -> ShadePlan? {
        let visible = windowIsVisible(pos: pos, size: size)
        let facts = FoldFacts(visibleOnActiveSpace: visible,
                              fullScreen: fullScreen,
                              minimized: minimized,
                              hasSheet: hasSheet,
                              appHasModalDialog: appHasModalDialog,
                              isQuickLook: profile.isQuickLook,
                              quickLookReopenable: quickLookReopenable,
                              adobeKind: profile.adobeProfile.kind,
                              adobeCanShade: profile.adobeProfile.canShade,
                              adobeReason: profile.adobeProfile.reason)
        var screenCaptureKitAvailable = false
        if #available(macOS 14.0, *) { screenCaptureKitAvailable = true }
        let settings = FoldSettings(appearance: appearanceMode,
                                    forcedAppearance: options.forcedAppearanceMode,
                                    screenRecordingGranted: hasScreenRecordingPermission(),
                                    screenCaptureKitAvailable: screenCaptureKitAvailable)
        switch FoldPlanner.decide(facts: facts, profile: appProfile(for: pid), settings: settings) {
        case .reject(let reason):
            wlog("plan: reject \(reason) pid=\(pid)")
            return nil
        case .fold(let plan):
            return plan
        }
    }
    func resolvedSourceSpaceID(windowID id: CGWindowID,
                                       sourceDisplayID: CGDirectDisplayID?,
                                       profile: WindowChromeProfile) -> UInt64? {
        let mover = PrivateSLSWindowMover.shared
        if profile.isQuickLook,
           let sourceDisplayID,
           let activeSpaceID = mover.currentSpace(displayID: sourceDisplayID) {
            return activeSpaceID
        }
        return mover.windowSpace(id: id)
            ?? sourceDisplayID.flatMap { mover.currentSpace(displayID: $0) }
    }
    func shade(_ win: AXUIElement, _ id: CGWindowID,
                       options: ShadeInvocationOptions? = nil,
                       preparedImage: CGImage? = nil, trustElement: Bool = false,
                       preparedProfile: WindowChromeProfile? = nil,
                       recordedPosition: CGPoint? = nil) {
        let completionTokens = foldWaiters[id].map { Array($0.keys) } ?? []
        let admissionPresentation = foldPresentationID
        func admissionCurrent() -> Bool { foldPresentationID == admissionPresentation }
        func completeFold(success: Bool, transaction: UUID? = nil) {
            if success {
                guard let transaction, shaded[id]?.foldTransactionID == transaction else { return }
                let ownedTokens = completionTokens.filter { foldWaiterTransactions[$0] == transaction }
                settleFoldWaiters(id: id, tokens: ownedTokens, success: true)
            } else {
                settleFoldWaiters(id: id, tokens: completionTokens, success: false)
            }
        }
        guard admissionCurrent() else { completeFold(success: false); return }
        // 收起没有分阶段汇总：这里记下起点，安装阶段慢时补记一行 `perf: fold install …`，
        // 以便看出主线程上哪一段最费时。
        let foldStartedAt = CFAbsoluteTimeGetCurrent()
        // 收起前先记下各段耗时的全局累计，结束时相减，就是这一次收起各段的耗时。
        let foldPhaseBaseline = foldPhaseTotals
        // 音频设备闲置后，第一次播放要在调用线程上花 250–500 毫秒启动设备（见 ShadeSoundPlayer）；
        // 收起一开始就在后台提前启动，真正播放音效时设备已经启动。
        prewarmFoldSound()
        let win: AXUIElement = {
            let memoScope = beginAppWindowsMemo()
            defer { endAppWindowsMemo(memoScope) }
            return foldPhase("元素刷新") {
                refreshedWindowElement(id: id, fallback: win, trustFallback: trustElement)
            }
        }()
        // 状态机防护：收起中、已收起、展开中的窗口再次触发收起一律忽略，
        // 避免状态损坏（与 shadeOperationIDs 在途去重互为冗余）。
        let operationState = currentOperationState(id)
        guard !shadeOperationIDs.contains(id),
              operationState != .capturing,
              operationState != .folded,
              operationState != .restoring else {
            wlog("shade: ignore in-flight id=\(id) state=\(operationState.rawValue)")
            return
        }
        shadeOperationIDs.insert(id)
        cancelRestorePin(for: id)
        restoreFocusTokens.removeValue(forKey: id)
        transitionOperationState(id: id, to: .capturing, reason: "shade")
        // AXUIElementGetPid 只读元素本身，不跨进程。
        let pid: pid_t = {
            var value: pid_t = 0
            AXUIElementGetPid(win, &value)
            return value
        }()
        AppIconCache.shared.prepare(pid: pid)
        let localChromeHeight = ChromeProfileCache.localChromeHeight(id: id, pid: pid)
        let options = options ?? defaultShadeOptions

        // 读完窗口之后的部分：回到主线程执行。
        func proceed(_ readout: FoldWindowReadout?) {
        MainThreadActivity.push("fold: 折叠窗口")
        defer { MainThreadActivity.pop() }
        var handedToAsyncCapture = false
        // installOverlay 接手之后，收起的成败由它（和它交给后台的移开原窗口）决定：
        // 外面的中止处理不再把还在“截图中”的状态改成失败。
        var installOwnsFold = false
        defer {
            if !handedToAsyncCapture && !installOwnsFold {
                shadeOperationIDs.remove(id)
                // 没有转给异步截图就返回，表示这次收起中止：状态从 capturing 改为 failed。
                if currentOperationState(id) == .capturing {
                    transitionOperationState(id: id, to: .failed, reason: "shade-abort")
                    completeFold(success: false)
                } else if currentOperationState(id) != .folded {
                    completeFold(success: false)
                }
                // 装好不等于验证过：成功通知由隐藏验证或原生调整大小成功之后发出。
            }
        }
        guard admissionCurrent() else { return }
        guard let readout else {
            quietNotice("没能收起这个窗口", log: "shade: 取不到 pos/size")
            return
        }
        let pos = readout.pos
        let size = readout.size
        guard readout.isWindow else {
            quietNotice("这个窗口不能收起", log: "shade: reject non-window role=\(readout.role ?? "?") id=\(id)")
            return
        }
        let bundleID = appBundleID(pid: pid)
        let appName = appDisplayName(pid: pid)
        let title = readout.title
        if UserDefaults.standard.bool(forKey: shadeDebugWindowDumpDefaultsKey) {
            dumpWindow(win)
        }
        let profile = readout.profile
        // guard 的条件里不能写尾随闭包，先算好再解包。
        let shadePlan = foldPhase("折叠计划") {
            makeShadePlan(pos: pos, size: size, pid: pid, profile: profile, options: options,
                          fullScreen: readout.fullScreen, minimized: readout.minimized, hasSheet: readout.hasSheet,
                          appHasModalDialog: readout.appHasModalDialog,
                          quickLookReopenable: readout.quickLookReopenURL != nil)
        }
        guard let plan = shadePlan else {
            quietNotice("这个窗口不能收起", log: "shade: plan rejected app=\(appName) id=\(id)")
            return
        }
        let policy = plan.policy
        let mode = plan.mode
        let quickLookReopenURL = readout.quickLookReopenURL
        let sourceDisplayID = displayID(for: screenForAXWindow(pos: pos, size: size))
        let sourceSpaceID = foldPhase("源 Space 解析") {
            resolvedSourceSpaceID(windowID: id, sourceDisplayID: sourceDisplayID, profile: profile)
        }
        let sourceSpaceMode = profile.isQuickLook ? "active-display" : "window"
        wlog(">>> shade id=\(id) app=\(appName) bundle=\(bundleID) mode=\(mode.rawValue) plan=\(plan.reason) policy=\(policy) sourceDisplay=\(sourceDisplayID.map { String($0) } ?? "-") sourceSpace=\(sourceSpaceID.map { String($0) } ?? "-") sourceSpaceMode=\(sourceSpaceMode) hasToolbar=\(profile.hasToolbar) adobe=\(profile.adobeProfile.kind.rawValue):\(profile.adobeProfile.reason) standardTitleBarOnly=\(profile.standardTitleBarOnly) toolbarlessStandard=\(profile.toolbarlessStandardTitleBar) preciseChrome=\(profile.preciseChrome) contentBelowTitleBar=\(profile.hasContentBelowTitleBar) axBarH=\(Int(profile.axBarHeight)) hitBarH=\(Int(profile.hitBarHeight))")

        // 单独统计整个安装阶段：它和已知各项（隐藏窗口、建卷帘条、写入磁盘……）的差额，
        // 直接说明剩下的时间花在安装阶段之内还是之外。
        func installOverlay(_ overlay: NSWindow, mode: ShadeAppearanceMode, previewImage: NSImage?) {
            if !admissionCurrent() {
                shadeOperationIDs.remove(id); dismissOverlay(overlay)
                transitionOperationState(id: id, to: .failed, reason: "presentation-changed")
                completeFold(success: false); return
            }
            installOwnsFold = true
            let installStartedAt = CFAbsoluteTimeGetCurrent()
            defer {
                let installMilliseconds = (CFAbsoluteTimeGetCurrent() - installStartedAt) * 1000
                foldPhaseTotals["▸安装阶段合计", default: 0] += installMilliseconds / 1000
                // 慢的时候记一行：这一段全在主线程上，测出耗时才知道该优化哪里。
                if installMilliseconds >= 150 {
                    let totalMilliseconds = (CFAbsoluteTimeGetCurrent() - foldStartedAt) * 1000
                    let phases = foldPhaseTotals
                        .map { (name: $0.key, seconds: $0.value - (foldPhaseBaseline[$0.key] ?? 0)) }
                        .filter { $0.seconds > 0.005 }
                        .sorted { $0.seconds > $1.seconds }
                        .map { "\($0.name) \(Int($0.seconds * 1000))ms" }
                        .joined(separator: " · ")
                    wlog("perf: fold install id=\(id) install=\(Int(installMilliseconds))ms total=\(Int(totalMilliseconds))ms mode=\(mode) phases: \(phases)")
                }
            }
            shadeOperationIDs.remove(id)
            foldPhase("辅助功能配置") {
                configureShadedAccessibility(for: overlay, id: id, appName: appName, title: title)
            }
            // 收起事务的顺序：可能隐藏整个应用程序时，先把焦点交给当前桌面上的下一扇窗口，再隐藏原窗口。
            // 隐藏前台应用程序时，macOS 会自己挑下一扇窗口接收焦点，可能切换桌面，或激活同一应用程序的其他窗口；
            // 当前桌面上没有窗口能接手焦点时，隐藏应用程序不安全：应用程序只有这一扇窗口时直接最小化（WindowHider.fallbackHide），否则用下面的办法。
            // 不会隐藏整个应用程序时（移到屏幕外、设成透明或停到角落，都不行时才最小化），先藏再交接：
            // 先交接的话，下一扇窗口会先盖到这扇窗上面，等它藏好才露出卷帘条。
            // 其中最小化同样会让系统自己挑下一扇窗口、可能切换桌面，由 scheduleSourceSpaceReturnIfNeeded 切回
            // （hideMethodCanTriggerSpaceJump 只包括隐藏应用程序和最小化）。
            // 窗口数在后台读窗口时已经数好（readout.visibleWindowCount）；交出焦点放到后台做，主线程不等。
            let mayHideApp = policy.mayHideApp && readout.visibleWindowCount <= 1
            func continueInstall(appHideSafe: Bool, noFocusHeir: Bool = false) {
            // 崩溃一致性：先把恢复意图写入磁盘，再做任何可能让窗口长时间看不见的动作。
            // 进程在 hideWindowInBackground 中途被结束时，下次启动仍能按这条记录找回窗口；
            // 隐藏验证通过后，recordShadeJournal 把同一条记录改为已收起（或按最终的隐藏方式清掉）。
            let intentWritten = foldPhase("恢复意图落盘") {
                recordShadeRecoveryIntent(id: id, pid: pid, bundleID: bundleID,
                                          appName: appName, title: title,
                                          originalPosition: pos, originalSize: size,
                                          sourceDisplayID: sourceDisplayID,
                                          sourceSpaceID: sourceSpaceID)
            }
            guard intentWritten else {
                dismissOverlay(overlay)
                transitionOperationState(id: id, to: .failed, reason: "recovery-intent-write-failed")
                completeFold(success: false)
                quietNotice("没能收起这个窗口", log: "shade: refusing hide without durable intent id=\(id)")
                return
            }
            // 隐藏前再核对一次：窗口仍属于这个应用程序、窗口号没变、这次收起仍然有效。
            var finalPID: pid_t = 0
            if AXUIElementGetPid(win, &finalPID) != .success || finalPID != pid || windowID(of: win) != id || !admissionCurrent() {
                dismissOverlay(overlay); transitionOperationState(id: id, to: .failed, reason: "changed-before-hide")
                completeFold(success: false); return
            }
            /// 卷帘条记进自己的窗口表，并挪到原窗口所在的桌面。挪桌面会让窗口短暂消失，
            /// 所以要在它亮出来之前做；先亮出来的那条在这里做过一次，后面不再重复。
            func assignOverlaySpace() -> CGWindowID? {
                let oid = foldPhase("卷帘条窗口号") { cgWindowID(for: overlay) }
                guard let oid else { return nil }
                overlayIDs.insert(oid)
                // 安装阶段里最后一段没有计时的：跨桌面移动和它的几何回退。
                let spaceMoveStartedAt = CFAbsoluteTimeGetCurrent()
                defer {
                    foldPhaseTotals["跨 Space 移动", default: 0] +=
                        CFAbsoluteTimeGetCurrent() - spaceMoveStartedAt
                }
                if let sourceSpaceID {
                    if PrivateSLSWindowMover.shared.moveWindow(id: oid, toSpace: sourceSpaceID) {
                        wlog("space: overlay assigned id=\(oid) source=\(id) sid=\(sourceSpaceID)")
                    } else if PrivateSLSWindowMover.shared.reassociateWindowByGeometry(id: oid) {
                        wlog("space: overlay reassociated by geometry id=\(oid) source=\(id)")
                    } else {
                        wlog("space: overlay assignment unavailable id=\(oid) source=\(id)")
                    }
                } else if PrivateSLSWindowMover.shared.reassociateWindowByGeometry(id: oid) {
                    wlog("space: overlay reassociated by geometry id=\(oid) source=\(id) sid=-")
                }
                return oid
            }
            // 先把卷帘条亮在原来的标题栏上，再挪走或隐藏窗口：卷帘条就是这条标题栏的截图、摆在同一处，
            // 盖上去看不出变化，窗口消失那一刻也没有空档。隐藏整个应用程序时也这样做：隐藏是否生效要到 0.15 秒后
            // 第一次复查才知道，要是等到那时再亮卷帘条，标题栏的位置会空一段（2026-10-10 本机文本编辑录像：11 帧）。
            // 没藏成时回滚会撤掉卷帘条。
            let revealedBeforeHide = mode == .nativeScreenshot
            var earlyOverlayID: CGWindowID?
            if revealedBeforeHide {
                foldPhase("卷帘条 Space 归属") { prepareOverlayWindowForSpaceAssignment(overlay) }
                if !mayHideApp { holdOverlayAboveFocusHandoff(overlay) }
                earlyOverlayID = assignOverlaySpace()
                foldPhase("显示卷帘条") { revealPreparedOverlay(overlay, fade: false) }
            }
            // 移开原窗口是对另一个进程的辅助功能写操作：在后台做，主线程不等对方响应。
            // 卷帘条先亮出来时，提交之后窗口服务器下一帧才画出来：等两帧再挪走或隐藏窗口，窗口消失那一刻卷帘条已经在屏上。
            let hideStartedAt = CFAbsoluteTimeGetCurrent()
            hideWindowInBackground(win, pid: pid, originalPosition: pos, size: size,
                                   policy: policy, appHideSafe: appHideSafe,
                                   delay: revealedBeforeHide ? 2.0 / 60 : 0,
                                   handOffFocusAfter: !mayHideApp, noFocusHeir: noFocusHeir) { [self] hide, observation in
            foldPhaseTotals["后台移开、交接与验证", default: 0] += CFAbsoluteTimeGetCurrent() - hideStartedAt
            // 交接已在后台做完：撤掉截图期的焦点停靠。
            if !mayHideApp { focusParkingWindow?.orderOut(nil) }
            // 最小化和隐藏应用程序的状态要过一会儿才读得到（最小化动画进行中 kAXMinimized 还没变，
            // NSRunningApplication.isHidden 更新滞后），后台那次检查可能读到“还没藏好”。
            // 简化标题栏和缩略图模式下：读到已藏好就立即显示卷帘条；否则交给 scheduleFoldVerification 在 0.15 秒、0.45 秒后再查，
            // 查到藏好才显示，仍然失败就补救或回滚。
            let hideVerifiedNow = observation == .hidden
            foldPhase("日志落盘") {
                recordShadeJournal(id: id, win: win, hide: hide, pid: pid, bundleID: bundleID,
                                   appName: appName, title: title,
                                   originalPosition: pos, originalSize: size,
                                   mode: mode, policy: policy, planReason: plan.reason,
                                   stage: .folded,
                                   sourceDisplayID: sourceDisplayID,
                                   sourceSpaceID: sourceSpaceID)
            }
            if !revealedBeforeHide {
                foldPhase("卷帘条 Space 归属") { prepareOverlayWindowForSpaceAssignment(overlay) }
            }
            let oid = revealedBeforeHide ? earlyOverlayID : assignOverlaySpace()
            // 观察者只用来发现窗口被外部唤回：Command-Tab 取消隐藏、点程序坞恢复、窗口被关闭。
            // 这些在刚收起的那一刻不会发生，而注册观察者要对目标应用程序做四次同步调用
            // （AXObserverCreate 和三次 AXObserverAddNotification），那个应用程序此刻正忙着隐藏自己
            // （实测 18 扇窗口共 1363 毫秒，占整次收起的 32%）。所以推迟到下一轮运行循环再注册，不占收起的关键路径。
            let wantsObserver = !(hide == .quickLookClosed || hide == .ownWindowOrderedOut)
            let observer: AXObserver? = nil
            let state = ShadeState(element: win, sourceWindowID: id,
                                   originalPosition: recordedPosition ?? pos, originalSize: size,
                                   sourceDisplayID: sourceDisplayID,
                                   sourceSpaceID: sourceSpaceID,
                                   overlay: overlay,
                                   overlayID: oid, hide: hide, pid: pid, bundleID: bundleID,
                                   appName: appName, title: title, appearanceMode: mode,
                                   lifecycleStage: .folded,
                                   previewImage: previewImage ?? preparedImage.map { NSImage(cgImage: $0, size: size) },
                                   quickLookReopenURL: quickLookReopenURL,
                                   ignoreAppRevealUntil: Date().addingTimeInterval(1.0),
                                   observer: observer)
            shaded[id] = state
            // 闭包只拿事务编号，不拿整个 state：Swift 6.0 把交给主队列的闭包当作把 state 送出去，
            // 之后再用 state 就报数据竞争（macOS 14 上能装的最高版本是 Swift 6.0.3）。
            let transactionID = state.foldTransactionID
            MainActor.assumeIsolated {
                bindFoldWaiters(id: id, tokens: completionTokens, transaction: transactionID)
            }
            MainActor.assumeIsolated {
                glance.attach(id: id, overlay: overlay)
            }
            foldPhase("状态机转换") {
                transitionOperationState(id: id, to: .folded, reason: "install")
            }
            if wantsObserver {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // 期间被展开、或已经注册过，就不再注册：否则会留下一个没人
                    // 移除的 runloop source。
                    guard let current = self.shaded[id], current.observer == nil,
                          current.foldTransactionID == transactionID, CFEqual(current.element, win) else { return }
                    guard let registered = foldPhase("观察者注册", {
                        self.makeRevealObserver(pid: pid, win: win, id: id, transaction: transactionID)
                    }) else { return }
                    self.shaded[id]?.observer = registered
                }
            }
            // 这两段要用 state，不放进 foldPhase 的闭包（见 foldPhaseRecord）。
            let returnStarted = CFAbsoluteTimeGetCurrent()
            scheduleSourceSpaceReturnIfNeeded(id: id, state: state)
            foldPhaseRecord("Space 回归调度", since: returnStarted)
            if hideVerifiedNow, shaded[id]?.foldTransactionID == state.foldTransactionID, admissionCurrent() {
                let invariantStarted = CFAbsoluteTimeGetCurrent()
                let spaceInvariantHeld = enforceOverlaySpaceInvariant(id: id, state: state, reason: "install")
                foldPhaseRecord("Space 不变量", since: invariantStarted)
                if spaceInvariantHeld {
                    foldPhase("显示卷帘条") { revealPreparedOverlay(overlay, fade: mode == .thumbnail) }
                }
                // 即使用户已经切到别的桌面，隐藏也已经生效。
                completeFold(success: true, transaction: state.foldTransactionID)
            } else {
                wlog("shade: hide not yet verified; deferring overlay reveal id=\(id) hide=\(hide)")
                if admissionCurrent() { scheduleFoldVerification(id: id) }
                else {
                    MainActor.assumeIsolated {
                        settleFoldWaiters(id: id, transaction: transactionID, success: false)
                    }
                }
            }
            hoverPreviewSuppressedUntil[id] = Date().addingTimeInterval(0.7)
            if options.rebuildMenuAfterInstall {
                rebuildMenu()
            }
            if options.emitFoldFeedback {
                playFoldSound()
            }
            }
            }
            guard mayHideApp else {
                continueInstall(appHideSafe: false)
                return
            }
            let focusRequest = focusHandoffRequest(win: win, pid: pid, id: id)
            let handOffStartedAt = CFAbsoluteTimeGetCurrent()
            let resume = HandOff { (safe: Bool, nowhere: Bool) in
                foldPhaseTotals["焦点交接（后台）", default: 0] += CFAbsoluteTimeGetCurrent() - handOffStartedAt
                // 交接后撤掉截图期的焦点停靠。
                self.focusParkingWindow?.orderOut(nil)
                continueInstall(appHideSafe: safe, noFocusHeir: nowhere)
            }
            windowHideQueue.async {
                let result = FocusHandoff(control: FocusControlSystem()).handOff(focusRequest)
                DispatchQueue.main.async { resume.value(result.appHideSafe, result == .nowhere) }
            }
        }

        if mode == .proxyTitleBar {
            let barH = min(proxyTitleBarHeight, min(size.height, 300))
            let canProxyResize = allowsProxyHorizontalResize(win, pid: pid)
            let windowManagementCapability = realWindowManagementCapability(win)
            guard #available(macOS 14.0, *) else {
                let overlay = makeProxyOverlay(axPos: pos, width: size.width, height: barH,
                                               pid: pid, appName: appName, title: title, id: id,
                                               canResize: canProxyResize,
                                               windowManagement: windowManagementCapability,
                                               trafficLights: profile.trafficLights)
                wlog("    proxy finalBarH=\(Int(barH)) canResize=\(canProxyResize) windowManagement=\(windowManagementCapability) preview=-")
                installOverlay(overlay, mode: mode, previewImage: nil)
                return
            }
            let quickPreview = preparedImage.map { NSImage(cgImage: $0, size: size) }
                ?? quickWindowPreviewImage(id: id, logicalSize: size)
            if quickPreview != nil || !options.capturePreview {
                // 旧接口的截图已经成功，或者这次收起本来就不需要预览：两种情况都马上装上卷帘条，不等。
                let overlay = foldPhase("建 overlay") {
                    makeProxyOverlay(axPos: pos, width: size.width, height: barH,
                                                   pid: pid, appName: appName, title: title, id: id,
                                                   canResize: canProxyResize,
                                                   windowManagement: windowManagementCapability,
                                                   trafficLights: profile.trafficLights)
                }
                wlog("    proxy immediate finalBarH=\(Int(barH)) canResize=\(canProxyResize) windowManagement=\(windowManagementCapability) preview=\(quickPreview == nil ? "-" : "quick") capture=\(options.capturePreview)")
                installOverlay(overlay, mode: mode, previewImage: quickPreview)
                return
            }
            // 旧接口的截图失败、这次收起又需要预览：在隐藏原窗口之前先用 ScreenCaptureKit 截一次（有超时）。
            // 窗口隐藏后就不在可截图的列表里，再补截几乎一定失败，这条卷帘条就一直没有预览，
            // 菜单里的预览也补不回来。这个分支很少走到，多花一点时间是值得的。
            handedToAsyncCapture = true
            Task { @MainActor in
                defer {
                    self.shadeOperationIDs.remove(id)
                    if !installOwnsFold, self.currentOperationState(id) == .capturing {
                        self.transitionOperationState(id: id, to: .failed, reason: "shade-capture-abort")
                        completeFold(success: false)
                    }
                }
                let capturedImage = await self.captureWindowWithTimeout(id: id, axPos: pos, size: size,
                                                                         maxPixelSize: hoverPreviewMaxPixelSize,
                                                                         timeoutNanoseconds: shadeCaptureTimeoutNanoseconds)
                let overlay = makeProxyOverlay(axPos: pos, width: size.width, height: barH,
                                               pid: pid, appName: appName, title: title, id: id,
                                               canResize: canProxyResize,
                                               windowManagement: windowManagementCapability,
                                               trafficLights: profile.trafficLights)
                wlog("    proxy pre-hide-capture finalBarH=\(Int(barH)) canResize=\(canProxyResize) windowManagement=\(windowManagementCapability) preview=\(capturedImage == nil ? "-" : "sck")")
                installOverlay(overlay, mode: mode,
                               previewImage: capturedImage.map { NSImage(cgImage: $0, size: size) })
            }
            return
        }

        guard #available(macOS 14.0, *) else {
            quietNotice("需要 macOS 14 或更高版本", log: "shade: ScreenCaptureKit unavailable on this macOS")
            return
        }
        handedToAsyncCapture = true
        let captureTaskQueuedAt = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            let captureTaskStartedAt = CFAbsoluteTimeGetCurrent()
            defer {
                self.shadeOperationIDs.remove(id)
                if !installOwnsFold, self.currentOperationState(id) == .capturing {
                    self.transitionOperationState(id: id, to: .failed, reason: "shade-capture-abort")
                    completeFold(success: false)
                }
            }
            let shouldParkFocus = preparedImage == nil && !profile.isQuickLook
            if shouldParkFocus {
                parkFocusForInactiveCapture()
                try? await Task.sleep(nanoseconds: 35_000_000)       // 等窗口服务器把整条工具栏重画成非活跃样式
            }
            let captureStartedAt = CFAbsoluteTimeGetCurrent()
            var capturedImage: CGImage?
            var capturePath = "prepared"
            var captureAttempts: [String] = []
            if let preparedImage { capturedImage = preparedImage }
            else {
                // 快速截图（实测几十毫秒）优先；ScreenCaptureKit 单张截图在收起途中要 200–700ms。
                // 刚把焦点停开、窗口正重画成非活跃态时，快速截图会拿到一张全透明的图：
                // 等一下再截，不要马上退到 ScreenCaptureKit。
                // 每一次快速截图的耗时都记下来（“-empty”是拿到了全透明的图）：第一次收起偶尔要 0.6–1.7 秒，
                // 要分清是哪一次慢。
                capturePath = "fast"
                var attempt = await timedFastWindowCapture(id)
                capturedImage = attempt.image
                captureAttempts.append(attempt.label)
                var retries = 0
                while capturedImage == nil, retries < 3, FastCapture.isAvailable, hasScreenRecordingPermission() {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    retries += 1
                    attempt = await timedFastWindowCapture(id)
                    capturedImage = attempt.image
                    captureAttempts.append(attempt.label)
                    capturePath = "fast-retry\(retries)"
                }
                if capturedImage == nil {
                    capturePath = "sck"
                    capturedImage = await captureWindowWithTimeout(id: id, axPos: pos, size: size,
                        timeoutNanoseconds: shadeCaptureTimeoutNanoseconds)
                }
            }
            guard let full = capturedImage else {
                if shouldParkFocus {
                    releaseFocusParking(reactivate: nil)
                }
                let barH = min(proxyTitleBarHeight, min(size.height, 300))
                let canProxyResize = allowsProxyHorizontalResize(win, pid: pid)
                let windowManagementCapability = realWindowManagementCapability(win)
                let overlay = makeProxyOverlay(axPos: pos, width: size.width, height: barH,
                                               pid: pid, appName: appName, title: title, id: id,
                                               canResize: canProxyResize,
                                               windowManagement: windowManagementCapability,
                                               trafficLights: profile.trafficLights)
                wlog("shade: screenshot timeout/fail → proxy fallback id=\(id) app=\(appName)")
                installOverlay(overlay, mode: .proxyTitleBar, previewImage: nil)
                return
            }
            if shouldParkFocus {
                releaseFocusParking(reactivate: nil)
            }
            if mode == .thumbnail {
                // 缩略图：抹掉录屏胶囊（悬停预览、看一眼也用这张），再在后台缩成缩略图用的小图。
                let thumbnailSize = ThumbnailLayout.size(for: size)
                let pixelScale = screenForAXWindow(pos: pos, size: size)?.backingScaleFactor ?? 2
                let (snapshot, picture) = await withCheckedContinuation {
                    (continuation: CheckedContinuation<(CGImage, CGImage?), Never>) in
                    pixelAnalysisQueue.async { [full, size] in
                        let scale = CGFloat(full.width) / max(1, size.width)
                        let cleaned = CaptureIndicatorRemoval.removingIndicator(from: full, scale: scale) ?? full
                        continuation.resume(returning: (cleaned, downsampledThumbnailPicture(
                            cleaned, size: thumbnailSize, scale: pixelScale)))
                    }
                }
                let overlay = makeThumbnailOverlay(picture: picture ?? snapshot, snapshot: snapshot,
                                                   axPos: pos, windowSize: size, pid: pid,
                                                   appName: appName, title: title, id: id)
                wlog("    thumbnail size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)) capture=\(full.width)x\(full.height)")
                installOverlay(overlay, mode: .thumbnail, previewImage: NSImage(cgImage: snapshot, size: size))
                return
            }
            // 裁出顶部标题栏条：标题栏高度判定、健康检查、圆角镜像都是纯像素计算（4K Retina 全宽可达数 MB），
            // 放到后台队列执行，避免在主线程上分配大缓冲、逐像素扫描。
            // 红绿灯点击区也在这里一起算（见下文），只有建卷帘条窗口留在主线程。
            // 截图时系统往往已经在这扇窗的红绿灯处画上了录屏胶囊（捕获本身触发的）。
            // 先把它抹回标题栏底色，卷帘条与悬停预览都用清理后的图；没有胶囊时原样不动。
            let capturedAt = CFAbsoluteTimeGetCurrent()
            // 红绿灯点击区和“能不能全屏”都要问目标应用程序。对方忙时一次辅助功能读取约 19 毫秒
            // （见 docs/performance.md 第一节），七八次就是上百毫秒，在主线程上做会拖慢收起的安装和菜单重建。
            // 它们读的是同一扇窗、同一时刻，结果不变，所以一并放在这条后台任务里算
            // （辅助功能接口可以从任何线程调用，项目里其他地方也这样用）。
            // 主线程仍要等结果，但等待期间运行循环照常运转，停住的只是这段等待。
            let (preparation, stripSource, indicatorRemoved, buttonRects, windowManagementCapability) =
                await withCheckedContinuation {
                (continuation: CheckedContinuation<(NativeStripPreparation, CGImage, Bool,
                                                    [(CGRect, TrafficAction)], WindowManagementCapability), Never>) in
                pixelAnalysisQueue.async { [full, size, profile, pid, win, pos] in
                    let scale = CGFloat(full.width) / max(1, size.width)
                    let cleaned = CaptureIndicatorRemoval.removingIndicator(from: full, scale: scale)
                    let image = cleaned ?? full
                    let preparation = prepareNativeStrip(full: image, logicalSize: size,
                                                         profile: profile, pid: pid)
                    // 最终高度确定后再换算命中区。
                    let buttonRects = trafficLightRects(
                        trafficLightRects(win, winTopLeft: pos, barH: preparation.barH),
                        normalizedFor: profile.trafficLights
                    )
                    continuation.resume(returning: (preparation, image, cleaned != nil,
                                                    buttonRects, realWindowManagementCapability(win)))
                }
            }
            if indicatorRemoved {
                wlog("    capture indicator removed from strip id=\(id)")
            }
            let ms = { (a: CFAbsoluteTime, b: CFAbsoluteTime) in Int((b - a) * 1000) }
            wlog("    fold-capture timing id=\(id) queued=\(ms(captureTaskQueuedAt, captureTaskStartedAt))ms park=\(ms(captureTaskStartedAt, captureStartedAt))ms capture=\(ms(captureStartedAt, capturedAt))ms path=\(capturePath) attempts=\(captureAttempts.joined(separator: ",")) prepare=\(ms(capturedAt, CFAbsoluteTimeGetCurrent()))ms")
            let barH = preparation.barH
            wlog("    capture full=\(full.width)x\(full.height) scale=\(preparation.scale) fixedBarH=\(preparation.fixedBarH.map { String(format: "%.1f", $0) } ?? "-") visualBarH=\(preparation.visualBarH.map { String(Int($0)) } ?? "-") fallbackBarH=\(Int(preparation.fallbackBarH)) standardBarH=\(String(format: "%.1f", preparation.standardBarH)) finalBarH=\(String(format: "%.1f", barH)) buttons=\(buttonRects.count) windowManagement=\(windowManagementCapability) cropPxH=\(max(1, Int(ceil(barH * preparation.scale)))) boundary=\(preparation.boundary)")
            guard let strip = preparation.strip else {
                activateApp(pid: pid)
                quietNotice("没能收起这个窗口", log: "shade: 裁剪失败")
                return
            }
            if preparation.brokenHealth.0 {
                let proxyBarH = min(proxyTitleBarHeight, min(size.height, 300))
                let canProxyResize = allowsProxyHorizontalResize(win, pid: pid)
                let overlay = makeProxyOverlay(axPos: pos, width: size.width, height: proxyBarH,
                                               pid: pid, appName: appName, title: title, id: id,
                                               canResize: canProxyResize,
                                               windowManagement: windowManagementCapability,
                                               trafficLights: profile.trafficLights)
                let preview = NSImage(cgImage: stripSource, size: size)
                wlog("    native strip invalid → proxy fallback id=\(id) app=\(appName) reason=\(preparation.brokenHealth.1)")
                installOverlay(overlay, mode: .proxyTitleBar, previewImage: preview)
                return
            }

            let overlay = makeScreenshotOverlay(image: strip, axPos: pos, width: size.width, height: barH,
                                                buttons: buttonRects, id: id,
                                                windowManagement: windowManagementCapability,
                                                trafficLights: profile.trafficLights)
            let preview = NSImage(cgImage: stripSource, size: size)
            installOverlay(overlay, mode: mode, previewImage: preview)
        }
        }

        let readStartedAt = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            let readout = await readWindowForFoldInBackground(HandOff((win: win, preparedProfile: preparedProfile)),
                                                              id: id, pid: pid, layout: ScreenLayout.current(),
                                                              localChromeHeight: localChromeHeight).value
            foldPhaseTotals["后台读取窗口", default: 0] += CFAbsoluteTimeGetCurrent() - readStartedAt
            proceed(readout)
        }
    }
    func captureWindow(id: CGWindowID, axPos: CGPoint, size: CGSize,
                               maxPixelSize: CGSize? = nil) async -> CGImage? {
        guard let content = await ShareableContentCache.shared.content(requiring: id),
              let scWindow = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        // 画面长宽比必须取自窗口自身：调用方传来的 AX 尺寸可能是上一轮读到的，
        // 也可能正好落在窗口动画（收起、展开、移动）中间。按它配置
        // SCStreamConfiguration 会把窗口内容拉伸到那个尺寸，预览图就会变形。
        let windowSize = scWindow.frame.size
        let pointSize = (windowSize.width > 1 && windowSize.height > 1) ? windowSize : size
        let scale = backingScaleForAXWindow(pos: axPos, size: pointSize)
        var pixelWidth = max(1, Int(ceil(pointSize.width * scale)))
        var pixelHeight = max(1, Int(ceil(pointSize.height * scale)))
        if let maxPixelSize {
            let outputScale = min(maxPixelSize.width / CGFloat(pixelWidth),
                                  maxPixelSize.height / CGFloat(pixelHeight),
                                  1)
            pixelWidth = max(1, Int(ceil(CGFloat(pixelWidth) * outputScale)))
            pixelHeight = max(1, Int(ceil(CGFloat(pixelHeight) * outputScale)))
        }
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        // 裁剪坐标相对于窗口外框；包含 ScreenCaptureKit 加的边框时，内容会在请求的像素尺寸里被缩小、内缩。
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                       configuration: config) else {
            return nil
        }
        // 这扇窗若正被某条流捕获（例如看一眼的实时画面），截图里会带着录屏胶囊：
        // 在后台抹掉（检测不到时直接返回原图，几乎不花时间）。
        // 悬停预览，以及收起时旧接口截图或快速截图失败后的补截，都走这里。
        let pixelScale = CGFloat(image.width) / max(1, pointSize.width)
        return await Task.detached(priority: .userInitiated) {
            CaptureIndicatorRemoval.removingIndicator(from: image, scale: pixelScale) ?? image
        }.value
    }
    /// 同 fastWindowCapture，另外返回这一次的耗时（毫秒），全透明的图记为“-empty”。
    func timedFastWindowCapture(_ id: CGWindowID) async -> (image: CGImage?, label: String) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let image = await fastWindowCapture(id)
        return (image, "\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))\(image == nil ? "-empty" : "")")
    }

    /// 收起用的快速整窗截图，放到后台线程做，不占主线程。
    func fastWindowCapture(_ id: CGWindowID) async -> CGImage? {
        guard hasScreenRecordingPermission() else { return nil }
        return await withCheckedContinuation { continuation in
            pixelAnalysisQueue.async { continuation.resume(returning: FastCapture.window(id)) }
        }
    }

    func captureWindowWithTimeout(id: CGWindowID, axPos: CGPoint, size: CGSize,
                                          maxPixelSize: CGSize? = nil,
                                          timeoutNanoseconds: UInt64) async -> CGImage? {
        // 收起时用的截图缓存，只保留 500 毫秒：快速连续收起同一扇窗口时复用，不必再用 ScreenCaptureKit 截一次。
        // 悬停预览的按需截图不走这里。缓存键区分截图种类和请求的像素档位，预览小图和完整 Retina 截图不会混用。
        let variant: WindowSnapshotVariant = maxPixelSize == nil ? .nativeChrome : .preview
        let key = WindowSnapshotKey(windowID: id, variant: variant, maxPixelSize: maxPixelSize)
        if let cached = WindowSnapshotCache.shared.cachedImage(key: key) {
            return cached
        }

        // 同一扇窗口、同一种截图的重复请求，直接等已经在进行的那一次，不另起任务；
        // 超时由那个共享任务管理（所有调用方用同一个 shadeCaptureTimeoutNanoseconds）。
        if let existing = WindowSnapshotCache.shared.inFlightTask(for: key) {
            return await existing.value
        }

        // 先建槽，再建任务：任务完成时按槽的身份清理进行中登记表，不会误删后来的同键任务。
        // 任务对槽是弱引用：登记失败（已有同键任务在进行）时槽没有被缓存持有，任务结束时的清理什么也不做。
        let slot = WindowSnapshotInFlightSlot(key: key)
        let task: Task<CGImage?, Never> = Task { [weak self, weak slot] in
            defer {
                slot?.markCompleted()
            }
            guard let self else { return nil }
            return await self.raceCaptureWithTimeout(id: id, axPos: axPos, size: size,
                                                     maxPixelSize: maxPixelSize,
                                                     timeoutNanoseconds: timeoutNanoseconds,
                                                     key: key)
        }
        slot.task = task
        if !WindowSnapshotCache.shared.registerInFlight(slot: slot) {
            // 创建任务期间已有同 key 任务被发布：改用对方的。
            if let existing = WindowSnapshotCache.shared.inFlightTask(for: key) {
                return await existing.value
            }
            return await task.value
        }
        let image = await task.value
        // 任务已完成的槽在等待结束后按身份清理（幂等，误删不了后到的同 key 任务）。
        WindowSnapshotCache.shared.completeInFlight(slot)
        return image
    }

    // 一次截图的内部竞速：超时先到就取消截图任务；截图先完成就取消超时任务。被取消或已过期的截图不写回缓存。
    // continuation 只允许恢复一次（SingleResumeGuard），两个竞速任务不会重复恢复。
    private func raceCaptureWithTimeout(id: CGWindowID, axPos: CGPoint, size: CGSize,
                                        maxPixelSize: CGSize?, timeoutNanoseconds: UInt64,
                                        key: WindowSnapshotKey) async -> CGImage? {
        let resumeGuard = SingleResumeGuard()
        let image: CGImage? = await withCheckedContinuation { continuation in
            let captureTask: Task<CGImage?, Never> = Task { [weak self] in
                guard let self else { return nil }
                let image = await self.captureWindow(id: id, axPos: axPos, size: size,
                                                     maxPixelSize: maxPixelSize)
                // 被取消或超时的截图不写回缓存，以免晚到的结果混进 500 毫秒的缓存期。
                guard !Task.isCancelled else { return nil }
                if let image {
                    WindowSnapshotCache.shared.store(image: image, key: key)
                }
                return image
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                if await resumeGuard.tryResume() {
                    captureTask.cancel()
                    continuation.resume(returning: nil)
                }
            }
            Task {
                let image = await captureTask.value
                timeoutTask.cancel()
                if await resumeGuard.tryResume() {
                    continuation.resume(returning: image)
                }
            }
        }
        return image
    }
}

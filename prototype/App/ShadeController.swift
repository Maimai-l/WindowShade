// 折叠入口：聚焦窗口解析、折叠计划、截图与主 shade 事务。
// 作为 AppDelegate 扩展实现；隐藏/恢复/验证见 FoldTransaction。

import Cocoa
import ScreenCaptureKit

extension AppDelegate {
    func retargetToActiveSpaceWindow(pid: pid_t) -> (AXUIElement, CGWindowID)? {
        let onScreen = WindowListCache.shared.onScreenWindows()
        // 在屏列表自前向后有序：取该 app 第一个不透明的 layer-0 窗口（排除我们的卷帘条）。
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
            quietNotice("需要权限", log: "toggle: 无辅助功能权限")
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
        // 聚焦窗口不在当前 Space（已折叠的除外——它们的真实窗口本来就不在屏上，
        // 要走下面的 unshade 分支）：改折该 app 在当前 Space 的最前窗口；
        // 一个都没有就不折叠，避免"折叠当前窗口跑到另一个 Space"。
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
                               appHasModalDialog: Bool) -> ShadePlan? {
        let visible = windowIsVisible(pos: pos, size: size)
        let facts = FoldFacts(visibleOnActiveSpace: visible,
                              fullScreen: fullScreen,
                              minimized: minimized,
                              hasSheet: hasSheet,
                              appHasModalDialog: appHasModalDialog,
                              isQuickLook: profile.isQuickLook,
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
        // 折叠没有阶段汇总：这里记一个起点，安装阶段慢的时候补一行
        // `perf: fold install …`（2026-10-01：折叠期间 0.5–1.5s 的主线程卡顿只能靠猜哪一段贵）。
        let foldStartedAt = CFAbsoluteTimeGetCurrent()
        // 各段耗时的全局累计在折叠前先拍一张，结束做差就是「这一次」的分段——一次折叠就能定位。
        let foldPhaseBaseline = foldPhaseTotals
        // 音频设备闲下来后，第一次播放要在调用线程上花 250–500ms 把设备拉起来（见 ShadeSoundPlayer）。
        // 折叠开始就先在后台预热，等真正播音效时它是热的。
        prewarmFoldSound()
        let win: AXUIElement = {
            let memoScope = beginAppWindowsMemo()
            defer { endAppWindowsMemo(memoScope) }
            return foldPhase("元素刷新") {
                refreshedWindowElement(id: id, fallback: win, trustFallback: trustElement)
            }
        }()
        // 状态机防护：折叠中/已折叠/展开中的窗口再次触发折叠一律忽略，
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
                // 未转入 async capture 就返回 = 本次折叠中止：capturing -> failed。
                if currentOperationState(id) == .capturing {
                    transitionOperationState(id: id, to: .failed, reason: "shade-abort")
                    completeFold(success: false)
                } else if currentOperationState(id) != .folded {
                    completeFold(success: false)
                }
                // Installed does not mean verified. The hide verification or
                // successful native resize owns the success notification.
            }
        }
        guard admissionCurrent() else { return }
        guard let readout else {
            quietNotice("无法读取窗口", log: "shade: 取不到 pos/size")
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
                          appHasModalDialog: readout.appHasModalDialog)
        }
        guard let plan = shadePlan else {
            quietNotice("这个窗口不能收起", log: "shade: plan rejected app=\(appName) id=\(id)")
            return
        }
        let policy = plan.policy
        let mode = plan.mode
        let quickLookReopenURL = readout.quickLookReopenURL
        if profile.isQuickLook, quickLookReopenURL == nil {
            wlog("quicklook: no direct reopen URL; will use Finder Space fallback")
        }
        let sourceDisplayID = displayID(for: screenForAXWindow(pos: pos, size: size))
        let sourceSpaceID = foldPhase("源 Space 解析") {
            resolvedSourceSpaceID(windowID: id, sourceDisplayID: sourceDisplayID, profile: profile)
        }
        let sourceSpaceMode = profile.isQuickLook ? "active-display" : "window"
        wlog(">>> shade id=\(id) app=\(appName) bundle=\(bundleID) mode=\(mode.rawValue) plan=\(plan.reason) policy=\(policy) sourceDisplay=\(sourceDisplayID.map { String($0) } ?? "-") sourceSpace=\(sourceSpaceID.map { String($0) } ?? "-") sourceSpaceMode=\(sourceSpaceMode) hasToolbar=\(profile.hasToolbar) adobe=\(profile.adobeProfile.kind.rawValue):\(profile.adobeProfile.reason) standardTitleBarOnly=\(profile.standardTitleBarOnly) toolbarlessStandard=\(profile.toolbarlessStandardTitleBar) preciseChrome=\(profile.preciseChrome) contentBelowTitleBar=\(profile.hasContentBelowTitleBar) axBarH=\(Int(profile.axBarHeight)) hitBarH=\(Int(profile.hitBarHeight))")

        // 整体包住安装阶段：它与已知子项（隐藏窗口/建 overlay/落盘…）的差额
        // 直接指出剩下的时间是在安装之内还是之外，比继续逐个猜要快。
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
                // 慢的时候留一行：这一段全在主线程上，量出来才知道该改哪儿。
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
            // 折叠事务序：可能隐藏整个 App 时，先把焦点交给当前 Space 的继承人，再隐藏真实窗口。
            // 隐藏前台 App 会触发 macOS 的焦点级联（跳 Space / 激活兄弟窗口的病灶）；
            // 无处交接（当前 Space 只有这一个窗口）时 app-hide 不安全，改走别的办法。
            // 不会隐藏整个 App 时（挪到屏幕外、停到角上、最小化）没有级联，先藏再交接：
            // 先交接的话，继承人的窗口会先盖到这扇窗上面，等它藏好才露出卷帘条。
            // 窗口数在后台读窗口时已经数好（readout.visibleWindowCount）；交出焦点放到后台做，主线程不等。
            let mayHideApp = policy.mayHideApp && readout.visibleWindowCount <= 1
            func continueInstall(appHideSafe: Bool) {
            // crash consistency：先把 durable recovery intent 落盘，再执行任何
            // 可能让窗口长期不可见的动作。若进程在 hideWindow 中途被杀，重启后
            // rescue 仍能按 intent 找回窗口；隐藏成功验证后由 recordShadeJournal
            // 把同一条 entry 更新为 folded（或按最终隐藏方式清掉）。
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
                quietNotice("恢复记录存不下来，窗口没有收起", log: "shade: refusing hide without durable intent id=\(id)")
                return
            }
            // 恢复记录必须先于隐藏写下（崩溃一致性），这里手工计时、不套 foldPhase 的闭包写法，
            // 让这条顺序在源码里一眼可见。
            var finalPID: pid_t = 0
            if AXUIElementGetPid(win, &finalPID) != .success || finalPID != pid || windowID(of: win) != id || !admissionCurrent() {
                dismissOverlay(overlay); transitionOperationState(id: id, to: .failed, reason: "changed-before-hide")
                completeFold(success: false); return
            }
            /// 卷帘条记进自己的窗口表，并挪到源窗口所在的桌面。挪桌面会让窗口短暂消失，
            /// 所以要在它亮出来之前做；先亮出来的那条在这里做过一次，后面不再重复。
            func assignOverlaySpace() -> CGWindowID? {
                let oid = foldPhase("卷帘条窗口号") { cgWindowID(for: overlay) }
                guard let oid else { return nil }
                overlayIDs.insert(oid)
                // 安装阶段里最后一块没打点的：跨 Space 移动与它的几何回退。
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
            // 不会隐藏整个 App 时（窗口会被挪走，而不是等系统的动画），先把卷帘条亮在原来的标题栏上
            // 再挪窗口：卷帘条就是这条标题栏的截图、摆在同一处，盖上去看不出变化，挪走那一刻也没有空档。
            let revealedBeforeHide = !(mayHideApp && appHideSafe) && mode == .nativeScreenshot
            var earlyOverlayID: CGWindowID?
            if revealedBeforeHide {
                foldPhase("卷帘条 Space 归属") { prepareOverlayWindowForSpaceAssignment(overlay) }
                if !mayHideApp { holdOverlayAboveFocusHandoff(overlay) }
                earlyOverlayID = assignOverlaySpace()
                foldPhase("显示卷帘条") { revealPreparedOverlay(overlay, fade: false) }
            }
            // 移开原窗口是对另一个进程的辅助功能写操作：在后台做，主线程不等对方响应。
            // 卷帘条先亮出来时，提交之后窗口服务器下一帧才画出来：等两帧再挪窗口，挪走那一刻卷帘条已经在屏上。
            let hideStartedAt = CFAbsoluteTimeGetCurrent()
            hideWindowInBackground(win, pid: pid, originalPosition: pos, size: size,
                                   policy: policy, appHideSafe: appHideSafe,
                                   delay: revealedBeforeHide ? 2.0 / 60 : 0,
                                   handOffFocusAfter: !mayHideApp) { [self] hide, observation in
            foldPhaseTotals["后台移开、交接与验证", default: 0] += CFAbsoluteTimeGetCurrent() - hideStartedAt
            // 交接已在后台做完：撤掉截图期的焦点停靠。
            if !mayHideApp { focusParkingWindow?.orderOut(nil) }
            // minimize / app-hide 的状态读回是异步的（最小化动画进行中 kAXMinimized
            // 尚未翻转、NSRunningApplication.isHidden 缓存滞后），立即验证会产生假阴性。
            // 立即通过 → 立即 reveal；否则延迟验证（+0.15/+0.45s），通过后才 reveal，
            // 两次仍失败才补救/回滚。见 scheduleFoldVerification。
            // 与上面的 hideWindow 同理，手工计时不做包装。
            // 验证已在后台和移开一起做完。
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
            // 观察者只用来发现「窗口被外部唤回」：⌘Tab 取消隐藏、点 Dock 恢复、
            // 窗口被关闭。这些在刚折叠完的那一瞬间都不可能发生，而注册它是
            // AXObserverCreate + 3 次 AXObserverAddNotification 共四次同步 IPC，
            // 发给的正是刚被要求隐藏自己、此刻最忙的那个 App——实测 18 个窗口
            // 1363ms，占整次折叠的 32%。推迟到下一轮 runloop 注册，从关键路径上拿掉。
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
            MainActor.assumeIsolated {
                bindFoldWaiters(id: id, tokens: completionTokens, transaction: state.foldTransactionID)
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
                          current.foldTransactionID == state.foldTransactionID, CFEqual(current.element, win) else { return }
                    guard let registered = foldPhase("观察者注册", {
                        self.makeRevealObserver(pid: pid, win: win, id: id, transaction: state.foldTransactionID)
                    }) else { return }
                    self.shaded[id]?.observer = registered
                }
            }
            foldPhase("Space 回归调度") { scheduleSourceSpaceReturnIfNeeded(id: id, state: state) }
            if hideVerifiedNow, shaded[id]?.foldTransactionID == state.foldTransactionID, admissionCurrent() {
                let spaceInvariantHeld = foldPhase("Space 不变量") {
                    enforceOverlaySpaceInvariant(id: id, state: state, reason: "install")
                }
                if spaceInvariantHeld {
                    foldPhase("显示卷帘条") { revealPreparedOverlay(overlay, fade: mode == .thumbnail) }
                }
                // Hiding is committed even if the user switched away from its Space.
                completeFold(success: true, transaction: state.foldTransactionID)
            } else {
                wlog("shade: hide not yet verified; deferring overlay reveal id=\(id) hide=\(hide)")
                if admissionCurrent() { scheduleFoldVerification(id: id) }
                else {
                    MainActor.assumeIsolated {
                        settleFoldWaiters(id: id, transaction: state.foldTransactionID, success: false)
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
            let resume = HandOff { (safe: Bool) in
                foldPhaseTotals["焦点交接（后台）", default: 0] += CFAbsoluteTimeGetCurrent() - handOffStartedAt
                // 交接后撤掉截图期的焦点停靠。
                self.focusParkingWindow?.orderOut(nil)
                continueInstall(appHideSafe: safe)
            }
            windowHideQueue.async {
                let safe = FocusHandoff(control: FocusControlSystem()).handOff(focusRequest).appHideSafe
                DispatchQueue.main.async { resume.value(safe) }
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
                // legacy 快照已经成功，或者这次折叠本来就不需要预览——
                // 两种情况都同步立刻装上，不引入任何延迟。
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
            // legacy 快照失败，且这次折叠需要预览：在真实窗口被隐藏前先补一次有超时
            // 的 ScreenCaptureKit 截图，而不是像以前那样先装后台再异步补——隐藏之后
            // 窗口就不在可截图列表里了，补拍几乎必然也失败，这条折叠条就永久没有
            // 预览了（菜单悬停的懒截图重试也会失败）。宁可在这
            // 个本来就少见的失败分支上多花一点点时间，也不要用「先装后补」制造一堵
            // 永远撞不过去的墙。
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
            quietNotice("系统版本不支持", log: "shade: ScreenCaptureKit unavailable on this macOS")
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
                try? await Task.sleep(nanoseconds: 35_000_000)       // 等 WindowServer 把整条 toolbar 重绘成非活跃态
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
            // 裁出顶部标题栏条：chrome 高度判定、健康检查、圆角镜像都是纯 CPU
            // 像素计算（4K Retina 全宽可达数 MB），挪到后台队列执行，避免在
            // MainActor 上分配大缓冲并逐像素扫描。AX 命中区和 AppKit 覆盖层
            // 仍留在主线程。
            // 截图时系统往往已经在这扇窗的红绿灯处画上了录屏胶囊（捕获本身触发的）。
            // 先把它抹回标题栏底色，卷帘条与悬停预览都用清理后的图；没有胶囊时原样不动。
            let capturedAt = CFAbsoluteTimeGetCurrent()
            // 红绿灯命中区与「能不能全屏」原来在这段 await 之后、主线程上问目标 App；
            // 对方忙的时候一次 AX 读约 19ms（见 docs/performance.md 第一节），七八次就是上百毫秒，
            // 而这正卡着折叠的安装与菜单重建。它们读的是同一扇窗、同一时刻，值不变，所以一并放进
            // 这条后台任务里算（AX 可以从任意线程调用，项目里其它地方也这么做）。主线程仍然要等结果，
            // 但等待期间 runloop 是活的——被冻住的是这段等待，不是整个 App。
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
        // 也可能正好落在窗口动画（折叠/展开/移动）中间。按它配置
        // SCStreamConfiguration 会把窗口内容拉伸到那个尺寸，缩略图就成了变形图。
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
        // Crop coordinates are relative to the window frame. Including SCK
        // framing scales/insets that content inside the requested pixel size.
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                       configuration: config) else {
            return nil
        }
        // 这扇窗若正被某条流捕获（置顶、实时预览、收起动画），截图里带着录屏胶囊：
        // 在后台抹掉（检测不到时原图返回，几乎零成本）。缩略图与卷帘条都走这里。
        let pixelScale = CGFloat(image.width) / max(1, pointSize.width)
        return await Task.detached(priority: .userInitiated) {
            CaptureIndicatorRemoval.removingIndicator(from: image, scale: pixelScale) ?? image
        }.value
    }
    /// 同上，另外返回这一次的耗时（毫秒），全透明的图记为“-empty”。
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
        // 折叠路径的 500ms 短 TTL 截图缓存：快速连续折叠同一窗口时复用，
        // 避免重复 ScreenCaptureKit capture。悬停预览的懒截图不走这里。
        // key 区分 capture variant 与请求像素档位，预览小图与完整 Retina
        // 截图不会互相串用。
        let variant: WindowSnapshotVariant = maxPixelSize == nil ? .nativeChrome : .preview
        let key = WindowSnapshotKey(windowID: id, variant: variant, maxPixelSize: maxPixelSize)
        if let cached = WindowSnapshotCache.shared.cachedImage(key: key) {
            return cached
        }

        // 同一窗口、同一 variant 的重复请求 join 已在途的 capture，不再堆积
        // 新的重复截图任务；超时由共享任务内部管理（所有调用方用同一个
        // shadeCaptureTimeoutNanoseconds）。
        if let existing = WindowSnapshotCache.shared.inFlightTask(for: key) {
            return await existing.value
        }

        // 槽先建、任务后建：任务完成时按槽身份清理在途注册表，不会误删
        // 后到的同 key 任务。任务弱持有槽：若发布失败（已有同 key 在途），
        // 槽未被缓存持有，任务结束时清理自动 no-op。
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

    // 单次 capture 的内部竞速：timeout 获胜 → 取消 capture task；capture 完成 →
    // 取消 timeout task。被取消或过期的 capture 不写回缓存。continuation 仍然
    // 只允许 resume 一次（SingleResumeGuard），两个赛跑的 Task 不会双 resume。
    private func raceCaptureWithTimeout(id: CGWindowID, axPos: CGPoint, size: CGSize,
                                        maxPixelSize: CGSize?, timeoutNanoseconds: UInt64,
                                        key: WindowSnapshotKey) async -> CGImage? {
        let resumeGuard = SingleResumeGuard()
        let image: CGImage? = await withCheckedContinuation { continuation in
            let captureTask: Task<CGImage?, Never> = Task { [weak self] in
                guard let self else { return nil }
                let image = await self.captureWindow(id: id, axPos: axPos, size: size,
                                                     maxPixelSize: maxPixelSize)
                // 被取消/超时过期的 capture 不写回缓存，避免晚到的结果污染 TTL 窗口。
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

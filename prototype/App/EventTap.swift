// 全局快捷键与鼠标钩子：注册全局快捷键，处理标题栏双击、三击，钩子被停用后延迟重新启用。
// 作为 AppDelegate 扩展实现。

import Cocoa
import Carbon.HIToolbox

/// titlebarContains 最近一次没命中的原因（窗口编号、位置大小、标题栏高度），只给未命中的日志用；
/// 这些值它已经读过，记下来不多花一次辅助功能查询。
@MainActor var titlebarMissDetail = ""

/// 设置里正在录制快捷键，WindowShade 自己的全局快捷键已经注销（见 pauseGlobalShortcutsForRecording），录完要注册回来。
@MainActor private var globalShortcutsPausedForRecording = false

extension AppDelegate {
    func registerHotKey() {
        installHotKeyHandler()
        // 新安装还是升级，启动第一步已经判断并存下（见 GlobalShortcuts.swift 的 InstallHistory），这里只读出来写一行日志。
        // 新安装不预设 ⌃⌘ 组合，升级的沿用原来的组合。
        let history = GlobalShortcutSettings.history
        wlog("hotkey: install history=\(history) factory ⌃⌘ shortcuts \(history.hadFactoryShortcuts ? "kept" : "off")")
        registerGlobalShortcuts()
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            if let event,
               GetEventParameter(event,
                                 EventParamName(kEventParamDirectObject),
                                 EventParamType(typeEventHotKeyID),
                                 nil,
                                 MemoryLayout<EventHotKeyID>.size,
                                 nil,
                                 &id) == noErr {
                DispatchQueue.main.async { appDelegate?.handleHotKey(id: id.id) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    /// 按当前设置（重新）注册全部全局快捷键。设置页改键后也走这里。
    /// 被其他应用占用的组合提示一次，并且不再显示在菜单里（按了没反应比没有更糟）。
    func registerGlobalShortcuts() {
        globalShortcutsPausedForRecording = false
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        var failed: [UInt32: (name: String, status: OSStatus)] = [:]
        func register(_ hotKey: HotKey, id: UInt32, name: String) {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x57534844), id: id) // 'WSHD'
            let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                             hkID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs[id] = ref
            } else {
                failed[id] = (name, status)
            }
        }
        for shortcut in GlobalShortcut.allCases {
            guard let hotKey = GlobalShortcutSettings.hotKey(for: shortcut) else { continue }
            register(hotKey, id: shortcut.hotKeyID,
                     name: HotKey.displayName(for: hotKey))
        }
        if GlobalShortcutSettings.numberedExpandEnabled {
            for (index, keyCode) in GlobalShortcutSettings.numberedKeyCodes.enumerated() {
                let hotKey = HotKey(keyCode: keyCode, modifiers: GlobalShortcutSettings.numberedModifiers)
                register(hotKey, id: UInt32(101 + index), name: HotKey.displayName(for: hotKey))
            }
        }
        unavailableHotKeyIDs = Set(failed.keys)
        if !failed.isEmpty {
            func names(_ group: [UInt32: (name: String, status: OSStatus)]) -> String {
                let numbered = group.keys.filter { $0 >= 101 }
                var names = group.filter { $0.key < 101 }.sorted { $0.key < $1.key }.map(\.value.name)
                names += numbered.count == 9
                    ? [GlobalShortcutSettings.numberedDisplayName]
                    : numbered.sorted().compactMap { group[$0]?.name }
                return names.joined(separator: "、")
            }
            // 同一个组合在本应用里注册第二次会得到 eventHotKeyExistsErr：占着它的是我们自己的另一个快捷键，不是别的应用。
            let duplicated = failed.filter { $0.value.status == OSStatus(eventHotKeyExistsErr) }
            let taken = failed.filter { $0.value.status != OSStatus(eventHotKeyExistsErr) }
            var parts: [String] = []
            if !taken.isEmpty { parts.append("已被使用：\(names(taken))") }
            if !duplicated.isEmpty { parts.append("快捷键冲突：\(names(duplicated))") }
            quietNotice(parts.joined(separator: "；"),
                        log: "hotkey: registration failed "
                            + failed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.status)" }
                                .joined(separator: ","))
        }
    }

    /// 设置里开始录制快捷键：先注销 WindowShade 自己的全局快捷键。按下 WindowShade 注册的全局快捷键时，按键在送到任何窗口之前就被系统截下，交给 WindowShade 执行，
    /// WindowShade 自己的设置窗口也一样：不注销的话，录一个已经在用的组合（例如 ⌃⌘C）时执行的是那个动作，
    /// 组合录不进去，也提示不了“已用于：……”。
    func pauseGlobalShortcutsForRecording() {
        guard !globalShortcutsPausedForRecording else { return }
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        globalShortcutsPausedForRecording = true
        wlog("hotkey: paused while a shortcut is being recorded")
    }

    /// 录制结束：注销的全局快捷键注册回来。录到新组合时 setShortcut 已经重新注册过，这里不再注册一遍。
    func resumeGlobalShortcutsAfterRecording() {
        guard globalShortcutsPausedForRecording else { return }
        registerGlobalShortcuts()
    }

    /// 菜单项上要不要显示这个快捷键：设置里开着，而且注册没失败。
    func menuHotKey(for shortcut: GlobalShortcut) -> HotKey? {
        guard !unavailableHotKeyIDs.contains(shortcut.hotKeyID) else { return nil }
        return GlobalShortcutSettings.hotKey(for: shortcut)
    }

    func isNumberedShortcutActive(index: Int) -> Bool {
        GlobalShortcutSettings.numberedExpandEnabled
            && !unavailableHotKeyIDs.contains(UInt32(101 + index))
    }

    func handleHotKey(id: UInt32) {
        if id == 1 {
            toggle()
            return
        }
        if id == 2 {
            arrangeShadedWindows()
            return
        }
        guard id >= 101, id <= 109 else { return }
        expandShadedWindow(atMenuIndex: Int(id - 101))
    }
    func expandShadedWindow(atMenuIndex index: Int) {
        let entries = sortedShadedEntries()
        guard entries.indices.contains(index) else {
            quietNotice("没有第 \(index + 1) 个已收起的窗口", log: "hotkey: no shaded window at index=\(index)")
            return
        }
        unshade(entries[index].0)
    }
    func scheduleEventTapReenable(delay: TimeInterval) {
        eventTapReenableWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.eventTapReenableWorkItem = nil
            if let tap = self?.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        eventTapReenableWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// 卷帘条自己的双击处理（展开它对应的窗口）：带红绿灯的卷帘条（原标题栏和图标和标题）记在 NativeProxyOverlayWindow 上，
    /// 没有红绿灯的原标题栏卷帘条记在 TitleStripView 上。
    func stripDoubleClickAction(_ strip: NSWindow?) -> (() -> Void)? {
        guard let strip else { return nil }
        if let proxy = strip as? NativeProxyOverlayWindow, let action = proxy.onDoubleClick { return action }
        if let view = strip.contentView as? TitleStripView { return view.onDoubleClick }
        return strip.contentView?.subviews.lazy.compactMap { ($0 as? TitleStripView)?.onDoubleClick }.first
    }
    func handleTitleBarDoubleClick(at point: CGPoint) -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if elapsedMilliseconds >= 50 {
                wlog("slow: titlebar-double-click took \(elapsedMilliseconds)ms")
            }
        }
        guard titlebarDoubleClickEnabled else { return false }
        guard AXIsProcessTrusted() else { return false }
        // 收起还没做完、窗口还没登记为已收起时，在原标题栏上再双击：等收起做完再展开这扇窗口（场景 A36）。
        // 收起做到一半时，窗口先离开 shadeOperationIDs（installOverlay 接手），等藏好才登记进 shaded；
        // 这段时间状态还是“截图中”，也算没做完（03134a8 上 A36：这段约 160 毫秒里的双击收起了后面的访达）。
        let inFlight = Set(foldingTitleBands.keys.filter { id in
            shaded[id] == nil && (shadeOperationIDs.contains(id) || currentOperationState(id) == .capturing)
        })
        foldingTitleBands = foldingTitleBands.filter { inFlight.contains($0.key) }
        if let folding = foldingWindow(at: point, bands: foldingTitleBands, inFlight: inFlight) {
            wlog("titlebar-double-click: on a window still folding; unfolding it when the fold is done id=\(folding)")
            unfoldWhenFolded.insert(folding)
            return true
        }
        // 刚收起、卷帘条还在等“已藏好”的确认时是透明的，不接点击：这时在原处双击，是要展开刚收起的这扇，
        // 不能让双击穿过去，把后面的窗口收起（场景 A36；A05 的诊断里收起了访达）。
        let cocoaPoint = cocoaMousePoint(fromAXPoint: point)
        if let pending = shaded.first(where: { _, state in
            guard let overlay = state.overlay, overlay.isVisible, overlay.alphaValue < 0.05 else { return false }
            return overlay.frame.contains(cocoaPoint)
        })?.key {
            wlog("titlebar-double-click: on a strip that is not shown yet; unfolding id=\(pending)")
            DispatchQueue.main.async { [weak self] in _ = self?.unshade(pending) }
            return true
        }
        // 点在一条已经显示出来的卷帘条上：不按标题栏双击处理。收起时卷帘条先显示、原窗口后移开，这段时间命中测试会落到
        // 卷帘条后面的原窗口上，按标题栏双击处理的话，双击会被当成“再收起一次”丢掉（108d26f 上 A32）。
        // 收起做完、点击位置上最上层就是卷帘条时放行，由卷帘条自己处理；还没做完，或者卷帘条被已收起窗口的原窗口盖着时不放行，
        // 直接调用卷帘条的双击处理（见 StripHitTest.swift）。
        let strip = NSApp.windows.first(where: { window in
            (window is NativeProxyOverlayWindow || window is OverlayWindow) && window.isVisible
                && window.alphaValue >= 0.05 && !window.ignoresMouseEvents
                && stripShows(at: cocoaPoint, frame: window.frame, shownOn: window.screen?.frame,
                              separateSpaces: NSScreen.screensHaveSeparateSpaces)
        })
        let foldFinished = strip.map { strip in shaded.values.contains { $0.overlay === strip } } ?? false
        // 点击位置上最上层的窗口是不是某扇已收起窗口的原窗口（快速查看窗口正在关闭，关闭动画还没结束）：是的话点击到不了卷帘条，见 stripDoubleClickRoute。
        let topWindow = strip == nil ? 0 : NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        let coveredByFoldedWindow = topWindow > 0 && topWindow != strip?.windowNumber
            && shaded[CGWindowID(topWindow)] != nil
        switch stripDoubleClickRoute(onShownStrip: strip != nil, foldFinished: foldFinished,
                                     coveredByFoldedWindow: coveredByFoldedWindow) {
        case .notOnStrip:
            break
        case .leaveToStrip:
            wlog("titlebar-double-click: on a shown strip; the strip handles it at=(\(Int(point.x)),\(Int(point.y)))")
            return false
        case .handleHere:
            guard stripDoubleClickAction(strip) != nil else {
                wlog("titlebar-double-click: on a strip still folding without a double-click action; the strip handles it")
                return false
            }
            wlog("titlebar-double-click: on a strip \(coveredByFoldedWindow ? "under its closing window" : "still folding"); "
                 + "handing the double click to it at=(\(Int(point.x)),\(Int(point.y)))")
            DispatchQueue.main.async { [weak self, weak strip] in
                self?.stripDoubleClickAction(strip)?()
            }
            return true
        }
        // 点在一条卷帘条的范围里却没按上面处理：记下它当时的状态（3064c36 上 A36 的第二次双击收起了后面的访达）。
        if let entry = shaded.first(where: { $0.value.overlay?.frame.contains(cocoaPoint) == true }),
           let overlay = entry.value.overlay {
            wlog("titlebar-double-click: strip id=\(entry.key) under the point visible=\(overlay.isVisible) "
                 + "alpha=\(String(format: "%.2f", overlay.alphaValue)) onScreen=\(overlay.isOnActiveSpace)")
        }
        // 先用窗口服务器的数据排除内容区的双击（选词等常见操作），
        // 这些双击就不用在钩子线程等待时对目标应用程序做同步的辅助功能命中测试。
        guard pointMayLieInTitlebarBand(point) else { return false }
        // 窗口外观配置描述的是裁剪几何，不说明标题栏里没有控件；标准标题栏里也可能有可编辑的附加视图。
        // 过了带内预过滤的点击都是“疑似标题栏双击”，这种点击不多，用户也能察觉——
        // 此后的每个拒绝分支都要留日志，否则“有时候收不起来”无从排查。
        let (hitErr, elRef, hitTimedOut) = titlebarHitTest(at: point)
        if hitErr == .success, let el = elRef {
            // 红绿灯、地址栏、搜索框、工具栏按钮等控件上的双击不处理；标签放行（见 stealsTitlebarDoubleClick 的注释）。
            let role = axRole(el)
            if stealsTitlebarDoubleClick(role) {
                wlog("titlebar-double-click: refused control role=\(role ?? "?") at=(\(Int(point.x)),\(Int(point.y)))")
                return false
            }
            if let win = containingWindow(el) {
                return handleTitleBarDoubleClick(win: win, point: point, source: "ax-hit")
            }
            // After Effects 等 Adobe 自绘窗口的 AX 命中元素是 AXUnknown 且没有
            // 窗口祖先（AX 树残缺）——几何回退，titlebarContains 仍会校验标题栏带。
            wlog("titlebar-double-click: no containing window role=\(role ?? "?") at=(\(Int(point.x)),\(Int(point.y))); trying geometry fallback")
            if let win = frontmostWindowContaining(point: point, requireCompatProfile: false) {
                return handleTitleBarDoubleClick(win: win, point: point, source: "geometry-after-orphan-hit")
            }
        } else if hitTimedOut {
            // 应用程序在 titlebarHitTestTimeout 内没有回答。几何回退还要再问它窗口位置，
            // 每问一次又是一次超时，所以这次双击放行给它自己，不收起。
            wlog("titlebar-double-click: app did not answer the hit-test in time; passing the click through at=(\(Int(point.x)),\(Int(point.y)))")
            return false
        } else if hitErr != .success {
            // 命中测试出了别的错：改用几何方法判断标题栏，并记一行日志，否则双击没反应时查不出原因。
            wlog("titlebar-double-click: ax hit-test failed err=\(hitErr.rawValue); trying geometry fallback")
            if let win = frontmostWindowContaining(point: point, requireCompatProfile: false) {
                return handleTitleBarDoubleClick(win: win, point: point, source: "geometry-after-ax-error")
            }
        }

        if let win = frontmostWindowContaining(point: point) {
            return handleTitleBarDoubleClick(win: win, point: point, source: "frontmost-geometry")
        }

        return false
    }

    func clearExpiredPendingTitlebarTripleClick() {
        if let pending = pendingTitlebarTripleClick, pending.deadline < Date() {
            pendingTitlebarTripleClick = nil
        }
    }
    func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
    func pendingTitlebarTripleClickMatches(_ pending: PendingTitlebarTripleClick,
                                                   point: CGPoint) -> Bool {
        if squaredDistance(point, pending.point) <= 96 * 96 { return true }
        guard let overlay = shaded[pending.id]?.overlay else { return false }
        let cocoaPoint = cocoaMousePoint(fromAXPoint: point)
        return overlay.frame.insetBy(dx: -28, dy: -28).contains(cocoaPoint)
    }
    func titlebarContains(point: CGPoint, in win: AXUIElement) -> (CGWindowID, pid_t)? {
        guard let id = windowID(of: win) else { titlebarMissDetail = "no window id"; return nil }
        guard !isDesktopWidgetWindow(id: id) else { titlebarMissDetail = "widget id=\(id)"; return nil }
        if overlayIDs.contains(id) { titlebarMissDetail = "strip id=\(id)"; return nil }
        guard let pos = axPosition(win), let size = axSize(win) else { titlebarMissDetail = "no frame id=\(id)"; return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        if isStickies(pid: pid) { titlebarMissDetail = "stickies id=\(id)"; return nil }
        let barH = titlebarHitHeight(of: win, id: id, winTop: pos.y, winSize: size, pid: pid)
        guard point.y >= pos.y, point.y <= pos.y + barH,
              point.x >= pos.x, point.x <= pos.x + size.width else {
            titlebarMissDetail = "outside id=\(id) frame=(\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height))) barH=\(Int(barH))"
            return nil
        }
        // 没有标题栏的窗口（windowHasTitleBar）和收起不值得的窗口（FoldPlanner.worthFolding）不收起：双击交给应用程序，不放音效、不提示。
        guard windowHasTitleBar(win, pid: pid) else { titlebarMissDetail = "no title bar id=\(id)"; return nil }
        guard FoldPlanner.worthFolding(windowHeight: size.height, barHeight: barH) else {
            titlebarMissDetail = "not worth folding id=\(id) height=\(Int(size.height)) barH=\(Int(barH))"
            return nil
        }
        return (id, pid)
    }
    func handleTitleBarTripleClick(at point: CGPoint, clickCount: Int64 = 3) -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if elapsedMilliseconds >= 50 {
                wlog("slow: titlebar-triple-click took \(elapsedMilliseconds)ms")
            }
        }
        guard titlebarDoubleClickEnabled else { return false }
        guard AXIsProcessTrusted() else { return false }
        guard systemTitlebarDoubleClickAction() != .none else {
            pendingTitlebarTripleClick = nil
            return false
        }
        clearExpiredPendingTitlebarTripleClick()

        if let pending = pendingTitlebarTripleClick,
           pending.deadline >= Date(),
           pendingTitlebarTripleClickMatches(pending, point: point) {
            pending.deadline = Date().addingTimeInterval(max(0.65, NSEvent.doubleClickInterval))
            // 第三下可能在截图或隐藏验证完成之前到达：先记下来，只有验证通过的收起才能开始展开。
            if clickCount == 3, pending.intent.request() { enqueuePendingTitlebarTripleClick(pending) }
            return true
        }

        // 第四下不能绕过已经拦下的三击的完成检查。
        guard clickCount == 3 else { return false }

        // 在待处理三击的分支之后才预过滤：三击补做系统动作时，和待处理记录的匹配不需要辅助功能查询。
        guard pointMayLieInTitlebarBand(point) else { return false }

        let (hitErr, elRef, hitTimedOut) = titlebarHitTest(at: point)
        // 应用程序没有响应时不再用几何回退去问它（见 handleTitleBarDoubleClick）。
        if hitTimedOut { return false }
        if hitErr == .success, let el = elRef {
            // 命中的控件被排除时直接放行，不再用几何判断，否则选中文字或点按钮会变成窗口动作。
            guard !stealsTitlebarDoubleClick(axRole(el)) else { return false }
            if let win = containingWindow(el) {
                guard let (id, _) = titlebarContains(point: point, in: win) else { return false }
                enqueueSystemTitlebarDoubleClickAction(on: win, id: id,
                                                       originalClickPoint: point,
                                                       source: "ax-hit")
                return true
            }
        }

        if let win = frontmostWindowContaining(point: point),
           let (id, _) = titlebarContains(point: point, in: win) {
            enqueueSystemTitlebarDoubleClickAction(on: win, id: id,
                                                   originalClickPoint: point,
                                                   source: "frontmost-geometry")
            return true
        }

        return false
    }
    private func enqueuePendingTitlebarTripleClick(_ pending: PendingTitlebarTripleClick) {
        let generation = titlebarActionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.titlebarActionGeneration, self.titlebarDoubleClickEnabled,
                  systemTitlebarDoubleClickAction() != .none,
                  let transaction = pending.foldTransactionID,
                  self.shaded[pending.id]?.foldTransactionID == transaction else { return }
            // 这个调用返回元素之后，验证器才安排完成回调。
            var restored: AXUIElement?
            restored = self.unshadeReturningElement(
                pending.id, playSound: false, pinAfterRestore: false,
                onVerified: { [weak self] success in
                    guard success, let self, let restored else { return }
                    self.completeTitlebarTripleClick(on: restored, pending: pending)
                })
        }
    }
    /// 钩子进程已经放行了这次点击（WindowShade 回话晚了）：已经排进主队列的收起和三击的系统动作都不做。
    func cancelQueuedTitlebarActions() {
        titlebarActionGeneration &+= 1
        pendingTitlebarTripleClick?.intent.cancel()
        pendingTitlebarTripleClick = nil
    }

    func titlebarFoldCanBegin(id: CGWindowID) -> Bool {
        let state = currentOperationState(id)
        return shaded[id] == nil && !shadeOperationIDs.contains(id)
            && (state == .normal || state == .failed)
    }
    private func completeTitlebarTripleClick(on win: AXUIElement,
                                            pending: PendingTitlebarTripleClick) {
        // 验证展开期间可能已经开始了新的收起。
        guard shaded[pending.id] == nil, !shadeOperationIDs.contains(pending.id),
              currentOperationState(pending.id) == .normal else { return }
        performSystemTitlebarDoubleClickAction(on: win, id: pending.id,
                                               originalClickPoint: pending.point,
                                               source: "pending")
    }
    private func enqueueSystemTitlebarDoubleClickAction(on win: AXUIElement, id: CGWindowID,
                                                       originalClickPoint: CGPoint, source: String) {
        let generation = titlebarActionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.titlebarActionGeneration else { return }
            self.performSystemTitlebarDoubleClickAction(on: win, id: id,
                                                        originalClickPoint: originalClickPoint,
                                                        source: source)
        }
    }
    func performAXZoomForTitlebarTripleClick(on win: AXUIElement,
                                                     id: CGWindowID,
                                                     source: String) -> Bool {
        switch realWindowManagementCapability(win) {
        case .zoom, .none:
            let ok = pressAXButton(win, kAXZoomButtonAttribute as String)
            wlog("titlebar-triple-click: AX zoom source=\(source) id=\(id) ok=\(ok)")
            return ok
        case .fullScreen:
            // 绿色按钮是全屏：按它会进全屏，不是缩放。用辅助功能直接设位置和大小，做系统缩放的事
            // （铺满屏幕可用区域；再缩放一次放回原来的位置和大小）。不合成双击或 Option 点击（R6）。
            return zoomWithinVisibleFrame(win, id: id, source: source)
        }
    }

    /// 缩放到所在屏幕的可用区域；已经是这个大小、并且记着原来的位置时，放回原处。
    private func zoomWithinVisibleFrame(_ win: AXUIElement, id: CGWindowID, source: String) -> Bool {
        guard let pos = axPosition(win), let size = axSize(win) else { return false }
        let current = CGRect(origin: pos, size: size)
        let visibleCocoa = visibleFrame(for: cocoaFrame(fromAXPosition: pos, size: size))
        let zoomed = CGRect(origin: axPosition(fromCocoaFrame: visibleCocoa), size: visibleCocoa.size)
        let isZoomed = abs(current.minX - zoomed.minX) <= 2 && abs(current.minY - zoomed.minY) <= 2
            && abs(current.width - zoomed.width) <= 2 && abs(current.height - zoomed.height) <= 2
        let target: CGRect
        if isZoomed, let previous = zoomRestoreFrames[id] {
            target = previous
            zoomRestoreFrames.removeValue(forKey: id)
        } else {
            zoomRestoreFrames[id] = current
            target = zoomed
        }
        let sizeOK = setAXSize(win, target.size) == .success
        let posOK = setAXPositionReturningError(win, target.origin) == .success
        wlog("titlebar-triple-click: exact zoom source=\(source) id=\(id) to=(\(Int(target.minX)),\(Int(target.minY)) "
             + "\(Int(target.width))x\(Int(target.height))) ok=(size:\(sizeOK),pos:\(posOK))")
        return sizeOK && posOK
    }
    func performSystemTitlebarDoubleClickAction(on win: AXUIElement, id: CGWindowID,
                                                        originalClickPoint: CGPoint,
                                                        source: String) {
        guard titlebarDoubleClickEnabled, systemTitlebarDoubleClickAction() != .none,
              windowID(of: win) == id else { return }
        cancelRestorePin(for: id)
        // 取消展开时安排的 80、250 毫秒两次“带到最前”：三击是先展开再做系统动作，那两次升起会把刚最小化的窗口又拉回来（场景 A08）。
        restoreFocusTokens.removeValue(forKey: id)
        let beforePos = axPosition(win)
        let beforeSize = axSize(win)
        switch systemTitlebarDoubleClickAction() {
        case .zoom:
            if performAXZoomForTitlebarTripleClick(on: win, id: id, source: source) {
                break
            }
            // 缩放按钮和直接设位置大小都没成：不做，不合成双击。
            wlog("titlebar-triple-click: zoom unavailable source=\(source) id=\(id)")
        case .minimize:
            // 在窗口所属应用程序的队列上做，排在展开时已经排进队列的“带到最前”之后（见 WindowRestorer.minimize）；
            // 读不到进程号时仍在主线程上直接做。
            var pid: pid_t = 0
            if AXUIElementGetPid(win, &pid) == .success {
                windowRestorer.minimize(WindowHandle(ax: win), pid: pid)
                wlog("titlebar-triple-click: AX minimize queued source=\(source) id=\(id)")
                break
            }
            let err = setAXMinimizedReturningError(win, true)
            wlog("titlebar-triple-click: AX minimize source=\(source) id=\(id) err=\(err)")
        case .none:
            wlog("titlebar-triple-click: system none source=\(source) id=\(id)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let afterPos = axPosition(win)
            let afterSize = axSize(win)
            let before = beforePos.flatMap { p in beforeSize.map { s in "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))" } } ?? "<unavailable>"
            let after = afterPos.flatMap { p in afterSize.map { s in "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))" } } ?? "<unavailable>"
            wlog("titlebar-triple-click: frame source=\(source) id=\(id) before=\(before) after=\(after)")
        }
    }
    func frontmostWindowContaining(point: CGPoint,
                                           requireCompatProfile: Bool = true) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // 常规路径只对已知需要几何回退的应用程序生效；辅助功能命中测试出错时的降级路径
        // （requireCompatProfile=false）对任何前台应用程序都生效。
        if requireCompatProfile {
            guard needsControlPaddedChrome(pid: app.processIdentifier) else { return nil }
        }
        // 焦点所在的元素确实就是指针下的窗口时，不读 AXWindows；裁剪几何和标题匹配都证明不了这一点。
        if let info = WindowListCache.shared.onScreenWindows().first(where: { info in
            guard let bounds = cgWindowBounds(info), bounds.contains(point) else { return false }
            return (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
        }),
           (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
           let number = info[kCGWindowNumber as String] as? NSNumber,
           let focused = focusedWindow() {
            var focusedID: CGWindowID = 0
            var focusedPID: pid_t = 0
            if AXUIElementGetPid(focused, &focusedPID) == .success,
               focusedPID == app.processIdentifier,
               _AXUIElementGetWindow(focused, &focusedID) == .success,
               focusedID == number.uint32Value,
               let position = axPosition(focused), let size = axSize(focused),
               size.width > 1, size.height > 1,
               CGRect(origin: position, size: size).contains(point) {
                return focused
            }
        }
        func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x
            let dy = a.y - b.y
            return dx * dx + dy * dy
        }
        let candidates = appWindows(pid: app.processIdentifier).compactMap { win -> (AXUIElement, CGPoint, CGSize)? in
            guard let pos = axPosition(win), let size = axSize(win),
                  size.width > 1, size.height > 1 else { return nil }
            let rect = CGRect(origin: pos, size: size)
            guard rect.contains(point) else { return nil }
            return (win, pos, size)
        }
        return candidates.min {
            let a = distanceSquared($0.1, point)
            let b = distanceSquared($1.1, point)
            return a < b
        }?.0
    }
    func handleTitleBarDoubleClick(win: AXUIElement, point: CGPoint, source: String) -> Bool {
        guard let (id, pid) = titlebarContains(point: point, in: win) else {
            // 钩子线程还在等这里的结果：未命中时的诊断不能再读一次 AXTitle，
            // 否则忙碌的应用程序每未命中一次，就多等一次同步调用超时。
            // 窗口属于哪个应用程序是本地查询，不是 IPC；问错了应用程序时（场景 B16）从这里看得出来。
            var owner: pid_t = 0
            AXUIElementGetPid(win, &owner)
            wlog("titlebar-double-click: miss source=\(source) app=\(appDisplayName(pid: owner)) at=(\(Int(point.x)),\(Int(point.y))) "
                 + titlebarMissDetail)
            return false
        }

        pendingTitlebarTripleClick?.intent.cancel()
        let pending: PendingTitlebarTripleClick?
        if titlebarFoldCanBegin(id: id), systemTitlebarDoubleClickAction() != .none {
            pending = PendingTitlebarTripleClick(id: id, point: point,
                deadline: Date().addingTimeInterval(max(0.65, NSEvent.doubleClickInterval)))
        } else {
            pending = nil
        }
        pendingTitlebarTripleClick = pending
        // 离开钩子之前登记这次手势，窗口操作全部延后。回话晚了时，cancelQueuedTitlebarActions 把 titlebarActionGeneration 加一，下面排进主队列的操作就不做，并取消三击的等待。
        let generation = titlebarActionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.titlebarActionGeneration else { pending?.intent.cancel(); return }
            self.performTitleBarDoubleClickAction(win: win, id: id, pid: pid,
                                                  point: point, source: source, pending: pending)
        }
        return true
    }
    private func performTitleBarDoubleClickAction(win: AXUIElement, id: CGWindowID, pid: pid_t,
                                                  point: CGPoint, source: String,
                                                  pending: PendingTitlebarTripleClick?) {
        guard titlebarDoubleClickEnabled else { pending?.intent.cancel(); return }
        var currentPID: pid_t = 0
        guard AXUIElementGetPid(win, &currentPID) == .success, currentPID == pid,
              windowID(of: win) == id, axRole(win) == (kAXWindowRole as String),
              let info = cgWindowInfo(id),
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
            pending?.intent.cancel()
            if pendingTitlebarTripleClick === pending { pendingTitlebarTripleClick = nil }
            return
        }
        logIfSlow("titlebar-double-click action id=\(id)", threshold: 0.05) {
            wlog("titlebar-double-click: source=\(source) app=\(appDisplayName(pid: pid)) id=\(id)")
            if let bounds = cgWindowBounds(info) {
                foldingTitleBands[id] = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(60, bounds.height))
            }
            if let pending {
                // 钩子返回之后，别的操作可能已经改动了这扇窗口。
                guard titlebarFoldCanBegin(id: id) else {
                    pending.intent.cancel()
                    if pendingTitlebarTripleClick === pending { pendingTitlebarTripleClick = nil }
                    return
                }
                // 这段闭包在主线程上执行（registerFoldWaiter 是 MainActor 方法）。
                MainActor.assumeIsolated {
                    _ = registerFoldWaiter(id: id) { [weak self, pending] success in
                        guard let self else { return }
                        if success { pending.foldTransactionID = self.shaded[id]?.foldTransactionID }
                        if pending.intent.completeFold(success: success && pending.foldTransactionID != nil) {
                            self.enqueuePendingTitlebarTripleClick(pending)
                        }
                        if !success, self.pendingTitlebarTripleClick === pending {
                            self.pendingTitlebarTripleClick = nil
                        }
                    }
                }
            }
            if shaded[id] != nil {
                unshade(id)
            } else {
                shade(win, id, trustElement: true)
            }
        }
    }
}

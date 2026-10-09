// 找回屏幕外的窗口：WindowShade 在收起期间异常退出后，先按恢复记录放回窗口，再扫描还停在停放位置上的窗口。
// 扫描在后台队列、写回在主线程；作为 AppDelegate 扩展实现。
//
// 顺序：找到记录 → 放回窗口 → 验证成功 → 才删除记录。
// 验证失败的记录留到下一轮重试；不能先删记录再放回窗口。

import Cocoa

extension AppDelegate {
    struct OffscreenRescueAction {
        let id: CGWindowID
        let win: AXUIElement
        let target: CGPoint
        let size: CGSize
        var pid: pid_t? = nil
        var hide: HideMethod? = nil
        var targetAlpha: Float? = nil
    }

    struct JournalAlphaRestore {
        let id: CGWindowID
        let targetAlpha: Float
    }

    struct JournalRescueResult {
        var actions: [OffscreenRescueAction] = []
        var alphaRestores: [JournalAlphaRestore] = []
        // 记录还停在 preparing、窗口仍然可见：收起没走到隐藏这一步，窗口完好，直接删掉这条记录。
        var resolvedIDs: Set<CGWindowID> = []
    }

    // WindowShade 自己的停放位置（见 Platform/WindowHider.swift 的 offscreenParkingPoint 和 offscreenSpots）：
    // 主点 (-32000,-32000)，备选 (-12000, y)、(x, -12000)、(-12000,-12000)。只匹配这些位置附近（±96 点）：
    // - 两个坐标都在停放位置附近（主点或 (-12000,-12000)），或
    // - 一个坐标在停放位置附近，另一个像普通窗口的坐标（备选点）。
    // 这样不会误动其他应用程序自己放到极远处（如 -100000）的窗口。
    nonisolated func isAtWindowShadeParkingSpot(_ pos: CGPoint) -> Bool {
        func onParkingBand(_ v: CGFloat) -> Bool {
            abs(v + 12000) <= 96 || abs(v + 32000) <= 96
        }
        func looksLikeWindowAxis(_ v: CGFloat) -> Bool {
            v >= -8000 && v <= 24000
        }
        let xParked = onParkingBand(pos.x)
        let yParked = onParkingBand(pos.y)
        if xParked && yParked { return true }
        return (xParked && looksLikeWindowAxis(pos.y))
            || (yParked && looksLikeWindowAxis(pos.x))
    }

    /// 在后台队列上跑：恢复记录由调用方先在主线程读好传进来。
    nonisolated func collectJournalRescueActions(entries: [[String: Any]], targetTopLeft: CGPoint,
                                                 into result: inout JournalRescueResult) {
        guard !entries.isEmpty else { return }
        var rescued = 0

        // 只枚举有窗口的进程：对每个运行中的进程都做一次辅助功能枚举，启动会明显变慢。
        let pidsOwningWindows = WindowListCache.shared.pidsWithWindows()

        for app in NSWorkspace.shared.runningApplications {
            guard pidsOwningWindows.contains(app.processIdentifier) else { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
                  let windows = ref as? [AXUIElement] else { continue }

            for win in windows {
                guard let entry = entries.first(where: { entry in
                    guard let id = journalID(entry),
                          !result.resolvedIDs.contains(id),
                          !result.actions.contains(where: { $0.id == id }),
                          !result.alphaRestores.contains(where: { $0.id == id }) else { return false }
                    return journalMatches(entry, app: app, win: win)
                }), let id = journalID(entry) else { continue }

                guard let pos = axPosition(win), let size = axSize(win) else { continue }
                if windowIsVisible(pos: pos, size: size),
                   journalString(entry,"stage") != ShadeLifecycleStage.restoring.rawValue,
                   journalString(entry,"hide") != HideMethod.minimized.rawValue,
                   journalString(entry,"hide") != HideMethod.hidden.rawValue,
                   journalString(entry,"hide") != HideMethod.privateAlpha.rawValue {
                    // 记录还停在 preparing、窗口仍然可见：收起没走到隐藏这一步（进程在写记录之后、
                    // 隐藏之前被结束），窗口完好，直接删掉这条记录。
                    if journalString(entry, "stage") == ShadeLifecycleStage.preparing.rawValue {
                        result.resolvedIDs.insert(id)
                        wlog("journal: preparing intent resolved (window visible) id=\(id)")
                    }
                    continue
                }

                let target = CGPoint(
                    x: CGFloat(journalNumber(entry, "originalX") ?? Double(targetTopLeft.x + CGFloat(rescued * 24))),
                    y: CGFloat(journalNumber(entry, "originalY") ?? Double(targetTopLeft.y + CGFloat(rescued * 24)))
                )
                let originalSize = CGSize(
                    width: CGFloat(journalNumber(entry, "originalWidth") ?? Double(size.width)),
                    height: CGFloat(journalNumber(entry, "originalHeight") ?? Double(size.height))
                )
                let safeTarget: CGPoint
                if windowIsVisible(pos: target, size: originalSize) {
                    safeTarget = target
                } else {
                    let frame = cocoaFrame(fromAXPosition: target, size: originalSize)
                    // 优先放回收起时所在的显示器，避免多显示器布局变化后放错屏幕。
                    let displayID = journalNumber(entry, "displayID").map { CGDirectDisplayID($0) }
                    safeTarget = axPosition(fromCocoaFrame: clampedFrame(frame, margin: 16,
                                                                          preferredDisplayID: displayID))
                }
                result.actions.append(OffscreenRescueAction(id: id, win: win,
                                                            target: safeTarget, size: originalSize,
                                                            pid:app.processIdentifier,hide:HideMethod(rawValue:journalString(entry,"hide")),
                                                            targetAlpha:journalString(entry,"hide") == HideMethod.privateAlpha.rawValue ? Float(journalNumber(entry,"originalAlpha") ?? 1):nil))
                rescued += 1
                wlog("journal: rescued id=\(id) app=\(journalString(entry, "appName")) target=(\(Int(safeTarget.x)),\(Int(safeTarget.y)))")
            }
        }
    }

    // 每个恢复动作单独验证：geometry 恢复至少确认 AXPosition/AXSize 可重新读取、
    // 窗口落在有效显示区域；只有验证成功的 entry 才允许被清理。
    func rescueActionVerified(_ action: OffscreenRescueAction) -> Bool {
        guard let pos = axPosition(action.win), let size = axSize(action.win) else { return false }
        guard pos.x.isFinite, pos.y.isFinite, size.width > 1, size.height > 1 else { return false }
        guard windowIsVisible(pos: pos, size: size), windowID(of:action.win) == action.id,
              let info=cgWindowInfo(action.id), (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              !axBoolAttribute(action.win,kAXMinimizedAttribute as String) else { return false }
        if let alpha=action.targetAlpha {
            guard let actual=PrivateSLSWindowMover.shared.windowAlpha(id:action.id), abs(actual-alpha)<0.05 else { return false }
        }
        return abs(pos.x-action.target.x)<=2 && abs(pos.y-action.target.y)<=2 &&
            abs(size.width-action.size.width)<=2 && abs(size.height-action.size.height)<=2
    }

    func alphaRestoreVerified(_ restore: JournalAlphaRestore) -> Bool {
        guard let current = PrivateSLSWindowMover.shared.windowAlpha(id: restore.id) else { return false }
        return current >= 0.5 || abs(current - restore.targetAlpha) <= 0.15
    }

    func pruneRescuedJournalEntries(rescuedIDs: Set<CGWindowID>) {
        guard !rescuedIDs.isEmpty else { return }
        let entries = shadeJournalEntries()
        let filtered = entries.filter { entry in
            guard let id = journalID(entry) else { return false }
            return !rescuedIDs.contains(id)
        }
        if filtered.count != entries.count {
            saveShadeJournalEntries(filtered)
            wlog("journal: pruned \(entries.count - filtered.count) rescued entries")
        }
    }
    nonisolated func collectParkedWindowRescueActions(targetTopLeft: CGPoint,
                                                  into actions: inout [OffscreenRescueAction]) -> Int {
        let allWindows = WindowListCache.shared.allWindows()
        var parkedPIDs: Set<pid_t> = []
        for info in allWindows {
            guard let bounds = cgWindowBounds(info),
                  isAtWindowShadeParkingSpot(CGPoint(x: bounds.minX, y: bounds.minY)),
                  let owner = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            parkedPIDs.insert(owner.int32Value)
        }

        var rescued = 0
        for pid in parkedPIDs {
            let appEl = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
                  let windows = ref as? [AXUIElement] else { continue }

            for win in windows {
                guard let pos = axPosition(win), let size = axSize(win) else { continue }
                // 只找回停在 WindowShade 停放位置附近、而且不在任何屏幕可见区域里的窗口。
                guard isAtWindowShadeParkingSpot(pos) else { continue }
                guard !windowIsVisible(pos: pos, size: size) else { continue }
                actions.append(OffscreenRescueAction(
                    id: 0,
                    win: win,
                    target: CGPoint(x: targetTopLeft.x + CGFloat(rescued * 24),
                                    y: targetTopLeft.y + CGFloat(rescued * 24)),
                    size: size))
                rescued += 1
            }
        }
        return rescued
    }
    func rescueOffscreenWindows(silent: Bool) {
        guard !isRescuingOffscreenWindows else {
            isRescueQueued = true
            return
        }
        isRescuingOffscreenWindows = true
        // 屏幕几何在主线程取好（NSScreen 只在主线程访问）；AX 扫描在后台。
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            isRescuingOffscreenWindows = false
            if !silent { quietNotice("没有可用屏幕", log: "rescue: no screen") }
            return
        }
        let targetTopLeft = CGPoint(x: screen.visibleFrame.minX + 80,
                                    y: coordinateBaselineY() - (screen.visibleFrame.maxY - 80))
        let finish: @Sendable (String?) -> Void = { [weak self] notice in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRescuingOffscreenWindows = false
                if let notice {
                    self.quietNotice(notice, log: "rescue: \(notice)")
                }
                if self.isRescueQueued {
                    self.isRescueQueued = false
                    self.rescueOffscreenWindows(silent: true)
                }
            }
        }
        let journalEntries = HandOff(shadeJournalEntries())
        rescueWorkQueue.async { [weak self] in
            guard let self else { return }
            guard AXIsProcessTrusted() else {
                DispatchQueue.main.async { self.showPermissionOnboardingIfNeeded(force: true) }
                finish(silent ? nil : "要先允许辅助功能")
                return
            }
            var result = JournalRescueResult()
            self.collectJournalRescueActions(entries: journalEntries.value, targetTopLeft: targetTopLeft, into: &result)
            var rescued = result.actions.count + result.alphaRestores.count
            if rescued == 0 {
                rescued += self.collectParkedWindowRescueActions(targetTopLeft: targetTopLeft,
                                                                 into: &result.actions)
            }
            // 写回统一在主线程：扫描期间用户收起了窗口（shaded 不为空）时，放弃这一批写回，
            // 免得把刚移开的窗口又放回可见区；删除记录也在主线程做，避免和收起时写记录冲突。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.shaded.isEmpty {
                    wlog("rescue: shaded windows appeared during scan; skip applying \(result.actions.count) actions")
                    finish(nil)
                    return
                }
                self.pruneShadeJournal(reason: "rescue")
                // 先恢复、逐条验证，再清理：验证失败的 entry 保留，下一轮重试。
                var verifiedIDs = result.resolvedIDs
                for action in result.actions {
                    guard action.id != 0 else {
                        setAXSize(action.win, action.size)
                        setAXPosition(action.win, action.target)
                        raiseAXWindow(action.win)
                        continue
                    }
                    if let alpha=action.targetAlpha { _=PrivateSLSWindowMover.shared.setAlpha(id:action.id,alpha:alpha) }
                    if action.hide == .hidden,let pid=action.pid { _=NSRunningApplication(processIdentifier:pid)?.unhide() }
                    if action.hide == .minimized { setAXMinimized(action.win,false) }
                    setAXSize(action.win, action.size)
                    setAXPosition(action.win, action.target)
                    raiseAXWindow(action.win)
                    if self.rescueActionVerified(action) {
                        verifiedIDs.insert(action.id)
                        wlog("journal: rescue verified id=\(action.id)")
                    } else {
                        wlog("journal: rescue unverified, keep entry for retry id=\(action.id)")
                    }
                }
                for restore in result.alphaRestores {
                    if PrivateSLSWindowMover.shared.setAlpha(id: restore.id, alpha: restore.targetAlpha),
                       self.alphaRestoreVerified(restore) {
                        verifiedIDs.insert(restore.id)
                        wlog("journal: alpha rescue verified id=\(restore.id)")
                    } else {
                        wlog("journal: alpha rescue unverified, keep entry for retry id=\(restore.id)")
                    }
                }
                self.pruneRescuedJournalEntries(rescuedIDs: verifiedIDs)
                wlog("rescueOffscreenWindows: rescued=\(rescued)")
                finish(rescued == 0 && !silent ? "没有在屏幕外的窗口" : nil)
            }
        }
    }
}

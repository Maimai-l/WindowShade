// 卷帘条整理：排列算法、桌面小组件避让、全部展开。作为 AppDelegate 扩展实现。

import Cocoa

extension AppDelegate {
    // animated=false 给「归位之后立刻要读卷帘条位置」的调用方用：展开真窗口时
    // 要按卷帘条的最终位置定位，动画中途的 frame 会把窗口放错地方。
    func restoreArrangedOverlayFrames(ids requestedIDs: Set<CGWindowID>? = nil,
                                      animated: Bool = true) -> Bool {
        arrangedOverlayFrames = arrangedOverlayFrames.filter { shaded[$0.key]?.overlay != nil }
        let entries = arrangedOverlayFrames.compactMap { id, frame -> (CGWindowID, NSWindow, NSRect)? in
            if let requestedIDs, !requestedIDs.contains(id) { return nil }
            guard let overlay = shaded[id]?.overlay else { return nil }
            return (id, overlay, frame)
        }
        guard !entries.isEmpty else {
            if requestedIDs == nil {
                arrangedOverlayFrames.removeAll()
            }
            return false
        }

        isProgrammaticOverlayArrangement = true
        defer { isProgrammaticOverlayArrangement = false }

        // NSWindow.setFrame(display:animate:) 是同步阻塞的：要等自己那段动画播完
        // 才返回。放在循环里逐个调用，总耗时就是各自动画时长之和——实测 9 条卷帘条
        // 3.2 秒，而且看上去是一条接一条地挪。改成一个动画组用 animator() 代理，
        // 所有卷帘条同时动，总耗时收敛到单条动画的长度。
        func applyMoves(_ moves: [(window: NSWindow, frame: NSRect)]) {
            guard !moves.isEmpty else { return }
            let proxies = moves.compactMap { $0.window as? NativeProxyOverlayWindow }
            let savedHandlers = proxies.map { ($0, $0.onResize) }
            proxies.forEach { $0.onResize = nil }

            guard animated else {
                for move in moves { move.window.setFrame(move.frame, display: true) }
                for (proxy, handler) in savedHandlers { proxy.onResize = handler }
                return
            }
            let duration = moves.map { $0.window.animationResizeTime($0.frame) }.max() ?? 0.2
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                for move in moves { move.window.animator().setFrame(move.frame, display: true) }
            } thenOnMain: {
                for (proxy, handler) in savedHandlers { proxy.onResize = handler }
            }
        }

        var moves: [(window: NSWindow, frame: NSRect)] = []
        for (id, overlay, savedFrame) in entries {
            let frame = clampedFrame(savedFrame, margin: 8, preferredDisplayID: shaded[id]?.sourceDisplayID)
            if !framesAlmostEqual(overlay.frame, frame) {
                moves.append((overlay, frame))
            }
            applyOverlayPresentation(overlay, bringForward: true)
            syncRestoreJournal(id: id, fromOverlayFrame: frame)
            arrangedOverlayFrames.removeValue(forKey: id)
            wlog("arrange: restore id=\(id) frame=(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))")
        }

        applyMoves(moves)

        if let active = activePreview, active.trigger == .titlebarPeek {
            updateHoverPreviewFrame(active.ownerID)
        }
        scheduleMenuRebuild()
        return true
    }

    func restoreReferenceFrame(id: CGWindowID, overlay: NSWindow) -> NSRect {
        return arrangedOverlayFrames[id] ?? overlay.frame
    }

    /// 用户拖动了卷帘条：记下新位置，它不再属于整理后的排列。
    func noteUserMovedOverlay(id: CGWindowID, frame: NSRect) {
        guard !isProgrammaticOverlayArrangement else { return }
        let hadArrangedFrame = arrangedOverlayFrames[id] != nil
        syncRestoreJournal(id: id, fromOverlayFrame: frame)
        arrangedOverlayFrames.removeValue(forKey: id)
        if hadArrangedFrame { rebuildMenu() }
    }

    func arrangedDisplayWidth(for state: ShadeState, overlay: NSWindow,
                                      visibleFrame: NSRect) -> CGFloat {
        guard state.appearanceMode == .proxyTitleBar else { return overlay.frame.width }
        let hasIcon = runningApp(pid: state.pid)?.icon != nil
        let fitting = NativeProxyTitleContentView.titleFittingWindowWidth(
            appName: state.appName,
            windowTitle: state.title,
            hasIcon: hasIcon
        )
        let minWidth = max(240, (overlay as? NativeProxyOverlayWindow)?.minimumReadableWidth ?? 0)
        let maxWidth = max(minWidth, visibleFrame.width)
        return min(max(fitting, minWidth), maxWidth)
    }

    func arrangedStairStepWidth(for state: ShadeState, visibleFrame: NSRect) -> CGFloat {
        let base = ProxyTitleLayoutMetrics.trafficLightDiameter * 0.95
        let clamped = min(visibleFrame.width * 0.05, base)
        return max(10, clamped)
    }

    func desktopWidgetScanLane(visibleFrame: NSRect) -> NSRect {
        let width = min(max(520, visibleFrame.width * 0.34), min(760, visibleFrame.width * 0.48))
        return NSRect(x: visibleFrame.minX,
                      y: visibleFrame.minY,
                      width: width,
                      height: visibleFrame.height)
    }

    func desktopWidgetFrames(for screen: NSScreen, visibleFrame: NSRect) -> [NSRect] {
        let desktopWidgetLayer = -2147483601
        let scanLane = desktopWidgetScanLane(visibleFrame: visibleFrame)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info -> NSRect? in
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.min
            guard layer == desktopWidgetLayer,
                  let bounds = cgWindowBounds(info) else { return nil }
            let frame = cocoaFrame(fromWindowServerBounds: bounds)
            guard screen.frame.intersects(frame),
                  scanLane.intersects(frame),
                  frame.width >= 96,
                  frame.height >= 80 else { return nil }
            return frame
        }
    }

    func desktopWidgetAvoidanceTop(for screen: NSScreen, visibleFrame: NSRect,
                                           widgetFrames: [NSRect]) -> CGFloat? {
        let leftLaneWidth = min(max(280, visibleFrame.width * 0.28), 420)
        let lane = NSRect(x: visibleFrame.minX,
                          y: visibleFrame.minY,
                          width: leftLaneWidth,
                          height: visibleFrame.height)
        let widgets = widgetFrames.filter { screen.frame.intersects($0) && lane.intersects($0) }
        guard !widgets.isEmpty else { return nil }
        let widgetBottom = widgets.map(\.minY).min() ?? visibleFrame.maxY
        let gap = max(18, proxyTitleBarHeight * 0.6)
        return max(visibleFrame.minY, widgetBottom - gap)
    }

    func arrangedHousekeepingStartX(for screen: NSScreen, visibleFrame: NSRect) -> CGFloat {
        visibleFrame.minX + 12
    }

    @discardableResult
    func arrangeShadedEntries(_ entries: [(CGWindowID, ShadeState, NSWindow)],
                                      reason: String) -> Bool {
        guard !entries.isEmpty else {
            return false
        }

        let sorted = entries.sorted {
            let a = $0.2.frame
            let b = $1.2.frame
            if abs(a.maxY - b.maxY) > 1 { return a.maxY > b.maxY }
            if abs(a.minX - b.minX) > 1 { return a.minX < b.minX }
            return $0.0 < $1.0
        }

        var grouped: [NSScreen: [(CGWindowID, ShadeState, NSWindow)]] = [:]
        for entry in sorted {
            let screen = screenForCocoaFrame(entry.2.frame) ?? NSScreen.main ?? NSScreen.screens.first
            if let screen {
                grouped[screen, default: []].append(entry)
            }
        }

        for (screen, group) in grouped {
            let visible = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            guard visible.width > 80, visible.height > 40 else { continue }
            let widgetFrames = desktopWidgetFrames(for: screen, visibleFrame: visible)

            let usesOriginalHousekeepingColumnLayout = reason == "housekeeping" &&
                group.allSatisfy { $0.1.appearanceMode != .proxyTitleBar }
            let verticalGap: CGFloat = 14
            let widestExisting = group.map {
                arrangedDisplayWidth(for: $0.1, overlay: $0.2, visibleFrame: visible)
            }.max() ?? visible.width
            let tallestBar = max(1, group.map { $0.2.frame.height }.max() ?? proxyTitleBarHeight)
            let stepY = tallestBar + verticalGap
            let startTop: CGFloat
            if usesOriginalHousekeepingColumnLayout {
                startTop = visible.maxY
            } else {
                startTop = desktopWidgetAvoidanceTop(for: screen, visibleFrame: visible,
                                                     widgetFrames: widgetFrames) ?? visible.maxY
            }
            let availableHeight = max(stepY, startTop - visible.minY)
            let maxRows = max(1, Int(floor(availableHeight / stepY)))
            let columnGap = min(28, max(14, visible.width * 0.012))
            let columnStep: CGFloat
            let columnStartX: CGFloat
            let stairStepX: CGFloat
            if usesOriginalHousekeepingColumnLayout {
                columnStep = min(max(widestExisting + columnGap, widestExisting * 1.04),
                                 visible.width * 0.52)
                columnStartX = arrangedHousekeepingStartX(for: screen, visibleFrame: visible)
                stairStepX = 0
            } else {
                let stairDepthCap = 4
                stairStepX = group.map {
                    arrangedStairStepWidth(for: $0.1, visibleFrame: visible)
                }.max() ?? max(10, ProxyTitleLayoutMetrics.trafficLightDiameter * 0.95)
                let maxStairOffset = CGFloat(stairDepthCap) * stairStepX
                columnStep = min(max(widestExisting + maxStairOffset + columnGap,
                                     widestExisting * 1.08),
                                 visible.width * 0.52)
                columnStartX = visible.minX + min(18, max(8, visible.width * 0.006))
            }

            isProgrammaticOverlayArrangement = true
            defer { isProgrammaticOverlayArrangement = false }
            for (index, entry) in group.enumerated() {
                let id = entry.0
                let overlay = entry.2
                let row = index % maxRows
                let column = index / maxRows
                var frame = overlay.frame
                arrangedOverlayFrames[id] = arrangedOverlayFrames[id] ?? overlay.frame
                frame.size.width = arrangedDisplayWidth(for: entry.1, overlay: overlay, visibleFrame: visible)
                let stackOffsetX = CGFloat(column) * columnStep
                let x = columnStartX + stackOffsetX +
                    (usesOriginalHousekeepingColumnLayout ? 0 : CGFloat(row) * stairStepX)
                let y = startTop - CGFloat(row) * stepY - frame.height
                frame.origin = NSPoint(x: x, y: y)
                frame = clampedFrame(frame, margin: 8)

                if let proxy = overlay as? NativeProxyOverlayWindow {
                    let oldResize = proxy.onResize
                    proxy.onResize = nil
                    if !framesAlmostEqual(proxy.frame, frame) {
                        proxy.setFrame(frame, display: true, animate: true)
                    }
                    proxy.onResize = oldResize
                } else {
                    if !framesAlmostEqual(overlay.frame, frame) {
                        overlay.setFrame(frame, display: true, animate: true)
                    }
                }
                applyOverlayPresentation(overlay, bringForward: true)
                wlog("arrange: side-stack reason=\(reason) id=\(id) row=\(row) column=\(column) frame=(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))")
            }
        }

        if let active = activePreview, active.trigger == .titlebarPeek {
            updateHoverPreviewFrame(active.ownerID)
        }
        scheduleMenuRebuild()
        return true
    }

@objc func arrangeShadedWindows() {
        if restoreArrangedOverlayFrames() { return }

        let entries = shaded.compactMap { id, state -> (CGWindowID, ShadeState, NSWindow)? in
            guard let overlay = state.overlay else { return nil }
            return (id, state, overlay)
        }
        // 缩略图排到屏幕下边一排（见 Thumbnail.swift）；卷帘条照旧。
        let thumbnails = entries.filter { $0.1.appearanceMode == .thumbnail }
        let strips = entries.filter { $0.1.appearanceMode != .thumbnail }
        let arrangedThumbnails = arrangeThumbnailEntries(thumbnails)
        let arrangedStrips = arrangeShadedEntries(strips, reason: "housekeeping")
        guard arrangedThumbnails || arrangedStrips else {
            quietNotice("没有收起的窗口", log: "arrange: no shaded overlays")
            return
        }
    }

    @objc func restoreAll() {
        guard !shaded.isEmpty else { return }
        let playSound = soundEnabled
        suppressUnshadeSounds = true
        withMenuRebuildSuppressed {
            for id in Array(shaded.keys) { _ = unshadeReturningElement(id) }
        }
        suppressUnshadeSounds = false
        if playSound {
            playUnfoldSound()
        }
    }
}

// 建卷帘条窗口：按收起后显示的样式建原标题栏或简化标题栏的卷帘条，复用回收的卷帘条窗口。
// 作为 AppDelegate 扩展实现。

import Cocoa

extension AppDelegate {
    func makeBaseOverlay(axPos: CGPoint, width: CGFloat, height: CGFloat) -> NSWindow {
        let frame = cocoaFrame(fromAXPosition: axPos, size: CGSize(width: width, height: height))

        // 复用已回收的卷帘条窗口（原标题栏样式、没有红绿灯的那种），避免频繁创建 NSWindow；池里没有才新建。
        let overlay = ShadeStripPool.shared.take()
            ?? OverlayWindow(contentRect: frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
        PaperSurfaceStyle.removeShadow(from: overlay)
        overlay.isReleasedWhenClosed = false
        overlay.setFrame(frame, display: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        applyOverlayPresentation(overlay, bringForward: false)
        overlay.hasShadow = true
        overlay.collectionBehavior = [.managed, .fullScreenNone, .fullScreenDisallowsTiling]
        return overlay
    }

    func makeScreenshotOverlay(image: CGImage, axPos: CGPoint, width: CGFloat, height: CGFloat,
                                       buttons: [(CGRect, TrafficAction)], id: CGWindowID,
                                       windowManagement: WindowManagementCapability,
                                       trafficLights: ProxyTrafficLightConfiguration) -> NSWindow {
        if !buttons.isEmpty {
            let effectiveWindowManagement: WindowManagementCapability = trafficLights.style == .quickLook
                ? .fullScreen
                : windowManagement
            let frame = cocoaFrame(fromAXPosition: axPos, size: CGSize(width: width, height: height))
            var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
            if trafficLights.closeVisible { style.insert(.closable) }
            if trafficLights.minimizeVisible { style.insert(.miniaturizable) }
            if effectiveWindowManagement.isEnabled || trafficLights.zoomVisible { style.insert(.resizable) }
            let contentRect = NSWindow.contentRect(forFrameRect: frame, styleMask: style)
            let overlay = NativeProxyOverlayWindow(contentRect: contentRect, styleMask: style,
                                                   backing: .buffered, defer: false)
            overlay.delegate = overlay
            overlay.fixedTitlebarHeight = frame.height
            overlay.allowsHorizontalResize = false
            overlay.minimumReadableWidth = frame.width
            overlay.setFrame(frame, display: false)
            overlay.titleVisibility = .hidden
            overlay.titlebarAppearsTransparent = true
            // 卷帘条的移动由它自己按每次拖动事件的指针位置来做（NativeProxyOverlayWindow.sendEvent），不交给系统。
            overlay.isMovable = false
            overlay.isReleasedWhenClosed = false
            overlay.acceptsMouseMovedEvents = true
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = true
            overlay.collectionBehavior = trafficLights.style == .quickLook
                ? [.managed, .fullScreenPrimary]
                : [.managed, .fullScreenNone, .fullScreenDisallowsTiling]
            overlay.minSize = NSSize(width: frame.width, height: frame.height)
            overlay.maxSize = effectiveWindowManagement == .fullScreen
                ? NSSize(width: 10000, height: 10000)
                : NSSize(width: 10000, height: frame.height)
            if #available(macOS 11.0, *) {
                overlay.titlebarSeparatorStyle = .none
                overlay.toolbarStyle = .unifiedCompact
            }

            let iv = TitleStripView(frame: NSRect(origin: .zero, size: frame.size))
            iv.image = NSImage(cgImage: image, size: frame.size)
            iv.imageScaling = .scaleAxesIndependently
            iv.configureAccessibility(appName: shaded[id]?.appName ?? "",
                                      windowTitle: shaded[id]?.title ?? "")
            iv.onDoubleClick = { [weak self] in self?.unshadeFromStrip(id) }
            iv.onClick = { [weak self] in self?.stripClicked(id) }
            iv.onMoveEnded = { [weak self] frame in
                self?.noteUserMovedOverlay(id: id, frame: frame)
            }
            overlay.contentView = iv
            overlay.configureTrafficLightButtons(trafficLights)
            overlay.alignStandardTrafficButtons(to: buttons)
            overlay.configureWindowManagementButton(capability: effectiveWindowManagement)
            overlay.onAction = { [weak self] action in self?.handleTrafficLight(action, id) }
            overlay.onFrameMoved = { [weak self] frame in
                self?.noteUserMovedOverlay(id: id, frame: frame)
            }
            overlay.onDragEnded = { [weak self] frame in
                self?.noteUserMovedOverlay(id: id, frame: frame)
            }
            overlay.onDoubleClick = { [weak self] in self?.unshadeFromStrip(id) }
            applyOverlayPresentation(overlay, bringForward: false)
            return overlay
        }

        let overlay = makeBaseOverlay(axPos: axPos, width: width, height: height)
        let frame = overlay.frame
        let iv = TitleStripView(frame: NSRect(origin: .zero, size: frame.size))
        iv.image = NSImage(cgImage: image, size: frame.size)
        iv.imageScaling = .scaleAxesIndependently
        iv.configureAccessibility(appName: shaded[id]?.appName ?? "",
                                  windowTitle: shaded[id]?.title ?? "")
        iv.onDoubleClick = { [weak self] in self?.unshadeFromStrip(id) }
        iv.onClick = { [weak self] in self?.stripClicked(id) }
        iv.onMoveEnded = { [weak self] frame in
            self?.noteUserMovedOverlay(id: id, frame: frame)
        }
        if !buttons.isEmpty {                                  // 在红绿灯位置盖透明的点击区
            let union = buttons.dropFirst().reduce(buttons[0].0) { $0.union($1.0) }
            let tlFrame = union.insetBy(dx: -4, dy: -4)
            let local = buttons.map { ($0.0.offsetBy(dx: -tlFrame.minX, dy: -tlFrame.minY), $0.1) }
            let tl = TrafficLightsView(frame: tlFrame, lights: local)
            tl.onAction = { [weak self] action in self?.handleTrafficLight(action, id) }
            iv.addSubview(tl)
        }
        overlay.contentView = iv
        overlay.invalidateShadow()
        // 原标题栏样式的卷帘条画面自带窗口圆角；系统方角阴影会在透明角落透出一块方形底，
        // 因此换成“上圆下直”的纸面阴影。
        overlay.hasShadow = false
        PaperSurfaceStyle.installShadow(on: overlay, corners: .top)
        return overlay
    }

    func makeProxyOverlay(axPos: CGPoint, width: CGFloat, height: CGFloat,
                                  pid: pid_t, appName: String, title: String, id: CGWindowID,
                                  canResize: Bool, windowManagement: WindowManagementCapability,
                                  trafficLights: ProxyTrafficLightConfiguration) -> NSWindow {
        let effectiveWindowManagement: WindowManagementCapability = trafficLights.style == .quickLook
            ? .fullScreen
            : windowManagement
        let minimumReadableWidth = NativeProxyTitleContentView.minimumReadableWindowWidth(
            appName: appName,
            windowTitle: title,
            hasIcon: AppIconCache.shared.image(pid: pid) != nil,
            trafficLightSlots: trafficLights.visibleSlotCount
        )
        let displayWidth = canResize ? width : max(width, minimumReadableWidth)
        let frame = cocoaFrame(fromAXPosition: axPos, size: CGSize(width: displayWidth, height: height))
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if trafficLights.closeVisible { style.insert(.closable) }
        if trafficLights.minimizeVisible { style.insert(.miniaturizable) }
        if canResize || effectiveWindowManagement.isEnabled || trafficLights.zoomVisible { style.insert(.resizable) }
        let contentRect = NSWindow.contentRect(forFrameRect: frame, styleMask: style)
        // 单独计时 NSWindow 本体的创建（带标题栏和红绿灯的窗口是 AppKit 里创建最慢的一种）：
        // 只有它占大部分时间，才值得冒重置漏项的风险改用窗口池。
        let overlay = foldPhase("└ NSWindow 创建") {
            NativeProxyOverlayWindow(contentRect: contentRect, styleMask: style,
                                     backing: .buffered, defer: false)
        }
        overlay.delegate = overlay
        overlay.fixedTitlebarHeight = frame.height
        overlay.allowsHorizontalResize = canResize
        overlay.allowsWindowManagement = effectiveWindowManagement.isEnabled
        overlay.minimumReadableWidth = minimumReadableWidth
        overlay.usesProxyTitleLayout = true
        overlay.trafficLightConfiguration = trafficLights
        overlay.setFrame(frame, display: false)
        overlay.title = proxyDisplayTitle(appName: appName, windowTitle: title)
        overlay.titleVisibility = .hidden
        overlay.titlebarAppearsTransparent = true
        // 卷帘条的移动由它自己按每次拖动事件的指针位置来做（NativeProxyOverlayWindow.sendEvent），不交给系统。
        overlay.isMovable = false
        overlay.isReleasedWhenClosed = false
        overlay.acceptsMouseMovedEvents = true
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = true
        overlay.collectionBehavior = trafficLights.style == .quickLook
            ? [.managed, .fullScreenPrimary]
            : [.managed, .fullScreenNone, .fullScreenDisallowsTiling]
        if canResize {
            overlay.minSize = NSSize(width: overlay.minimumReadableWidth, height: frame.height)
            overlay.maxSize = effectiveWindowManagement == .fullScreen
                ? NSSize(width: 10000, height: 10000)
                : NSSize(width: 10000, height: frame.height)
        } else if effectiveWindowManagement.isEnabled {
            overlay.minSize = NSSize(width: frame.width, height: frame.height)
            overlay.maxSize = effectiveWindowManagement == .fullScreen
                ? NSSize(width: 10000, height: 10000)
                : NSSize(width: 10000, height: frame.height)
        } else {
            overlay.minSize = NSSize(width: frame.width, height: frame.height)
            overlay.maxSize = NSSize(width: frame.width, height: frame.height)
        }
        if #available(macOS 11.0, *) {
            overlay.titlebarSeparatorStyle = .none
            overlay.toolbarStyle = .unifiedCompact
        }

        if let content = overlay.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor

            // 代理标题栏材质与其他自定义表面共用同一份系统外观策略。
            let material = SystemMaterialView(purpose: .proxyTitleBar)
            material.frame = content.bounds
            material.autoresizingMask = [.width, .height]
            material.apply()
            content.addSubview(material)

            let titleView = NativeProxyTitleContentView(frame: content.bounds,
                                                        appName: appName,
                                                        windowTitle: title,
                                                        appIcon: AppIconCache.shared.image(pid: pid),
                                                        trafficLightSlots: trafficLights.visibleSlotCount)
            titleView.autoresizingMask = [.width, .height]
            content.addSubview(titleView)
            overlay.configureTrafficLightButtons(trafficLights)
        }

        overlay.onAction = { [weak self] action in self?.handleTrafficLight(action, id) }
        overlay.onClick = { [weak self] in self?.stripClicked(id) }
        overlay.onFrameMoved = { [weak self] frame in
            self?.noteUserMovedOverlay(id: id, frame: frame)
        }
        overlay.onDragEnded = { [weak self] frame in
            self?.noteUserMovedOverlay(id: id, frame: frame)
        }
        if canResize {
            overlay.onResize = { [weak self] window in self?.resizeShadedWindowFromProxy(id, proxyFrame: window.frame) }
        }
        overlay.configureWindowManagementButton(capability: effectiveWindowManagement)
        overlay.onDoubleClick = { [weak self] in self?.unshadeFromStrip(id) }
        applyOverlayPresentation(overlay, bringForward: false)
        PaperSurfaceStyle.installShadow(on: overlay, corners: .top)
        return overlay
    }
}

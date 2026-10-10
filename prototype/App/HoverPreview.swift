// 菜单悬停预览：展示/隐藏、懒截图请求与预览定位；单击卷帘条转给看一眼。
// 作为 AppDelegate 扩展实现。

import Cocoa

extension AppDelegate {

    func safariStylePreviewSize(anchorWidth: CGFloat, imageSize: NSSize,
                                        visibleWidth: CGFloat) -> NSSize {
        let targetWidth = min(max(280, min(anchorWidth, 340)), max(1, visibleWidth))
        let thumbnailWidth = max(1, targetWidth - 20)
        let thumbnailHeight = min(176, max(92, floor(thumbnailWidth * imageSize.height / max(1, imageSize.width))))
        return NSSize(width: targetWidth, height: thumbnailHeight + 20)
    }

    func statusMenuWindowFrame(near mouse: NSPoint) -> NSRect? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = windows.compactMap { info -> NSRect? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == selfPID,
                  let bounds = cgWindowBounds(info) else { return nil }
            let frame = cocoaFrame(fromWindowServerBounds: bounds)
            guard frame.width >= 180,
                  frame.height >= 80,
                  frame.insetBy(dx: -8, dy: -8).contains(mouse) else { return nil }
            return frame
        }
        return candidates.min { ($0.width * $0.height) < ($1.width * $1.height) }
    }

    func estimatedStatusMenuItemAnchor(near mouse: NSPoint) -> NSRect {
        let rawVisible = visibleFrame(for: NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1))
        let visible = rawVisible.insetBy(dx: 8, dy: 8)
        if let menuFrame = statusMenuWindowFrame(near: mouse) {
            return NSRect(x: menuFrame.minX,
                          y: mouse.y - 1,
                          width: menuFrame.width,
                          height: 2)
        }

        let measuredWidth = ceil(statusMenu.size.width)
        let menuWidth = min(max(280, measuredWidth), min(640, visible.width))
        let cursorOffsetFromMenuLeft = min(max(menuWidth * 0.28, 96), menuWidth - 80)
        let x = min(max(mouse.x - cursorOffsetFromMenuLeft, visible.minX), visible.maxX - menuWidth)
        return NSRect(x: x, y: mouse.y - 1, width: menuWidth, height: 2)
    }

    func menuHoverPreviewFrame(anchor: NSRect, imageSize: NSSize) -> NSRect {
        let rawVisible = visibleFrame(for: anchor)
        let visible = rawVisible.insetBy(dx: 8, dy: 8)
        let size = safariStylePreviewSize(anchorWidth: max(anchor.width, menuHoverPreviewMaxSize.width),
                                          imageSize: imageSize,
                                          visibleWidth: visible.width)
        let gap: CGFloat = 10
        var origin = NSPoint(x: anchor.minX - size.width - gap,
                             y: anchor.midY - size.height / 2)
        if origin.x < visible.minX {
            origin.x = anchor.maxX + gap
        }
        if origin.x + size.width > visible.maxX {
            origin.x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            origin.y = anchor.minY - size.height - gap
        }
        let frame = NSRect(origin: origin, size: size)
        return clampedFrame(frame, margin: 8)
    }

    func showMenuHoverPreview(_ id: CGWindowID, anchor: NSRect?) {
        guard let anchor else { return }
        if shaded[id] != nil {
            showShadedMenuHoverPreview(id, anchor: anchor)
        }
    }

    func showShadedMenuHoverPreview(_ id: CGWindowID, anchor: NSRect) {
        guard let state = shaded[id] else { return }
        guard let image = state.previewImage,
              image.size.width > 1,
              image.size.height > 1 else {
            requestCachedPreview(id, reason: "menu") { [weak self] in
                guard let self,
                      self.menuPreviewHoverID == id else { return }
                self.showMenuHoverPreview(id, anchor: self.menuPreviewAnchor ?? anchor)
            }
            return
        }

        let frame = menuHoverPreviewFrame(anchor: anchor, imageSize: image.size)
        let previewView = SafariStylePreviewView(frame: NSRect(origin: .zero, size: frame.size),
                                                 image: image,
                                                 windowTitle: hoverPreviewTitle(ownerID: id))
        presentPreview(ownerID: id, frame: frame, contentView: previewView,
                       trigger: .menuHover)
    }

    /// 菜单悬停预览要显示的窗口名。
    func hoverPreviewTitle(ownerID: CGWindowID) -> String {
        guard let state = shaded[ownerID] else { return "" }
        return descriptiveDisplayTitle(appName: state.appName, windowTitle: state.title)
    }

    // 唯一显示预览的入口：建窗口、放入内容，并保证同一时间只有一个预览窗口：显示新的之前一定先关掉旧的。
    func presentPreview(ownerID: CGWindowID, frame: NSRect, contentView: NSView,
                                trigger: PreviewTrigger, alpha: CGFloat = 1) {
        hidePreview(reason: "replaced")
        let window = PreviewWindow(contentRect: frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.hasShadow = true
        window.contentView = contentView
        window.alphaValue = alpha
        activePreview = ActivePreview(ownerID: ownerID, window: window, trigger: trigger)
        window.orderFrontRegardless()
    }

    // 隐藏当前活跃预览。ownerID/trigger 给定时先核对，只清掉匹配的那一个——不匹配
    // 就是另一条触发路径正显示着别的窗口，什么都不做。
    func hidePreview(ownerID: CGWindowID? = nil, trigger: PreviewTrigger? = nil, reason: String) {
        guard let active = activePreview else { return }
        if let ownerID, active.ownerID != ownerID { return }
        if let trigger, active.trigger != trigger { return }
        active.window.orderOut(nil)
        activePreview = nil
    }

    func requestCachedPreview(_ id: CGWindowID, reason: String,
                                      completion: @escaping () -> Void) {
        guard #available(macOS 14.0, *) else { return }
        guard !previewCapturePendingIDs.contains(id),
              let state = shaded[id] else { return }
        previewCapturePendingIDs.insert(id)
        wlog("preview-cache: capture request id=\(id) app=\(state.appName) reason=\(reason)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentPos = axPosition(state.element) ?? state.originalPosition
            let capturePos = windowIsVisible(pos: currentPos, size: state.originalSize)
                ? currentPos
                : state.originalPosition
            let image = await self.captureWindow(id: id,
                                                 axPos: capturePos,
                                                 size: state.originalSize,
                                                 maxPixelSize: hoverPreviewMaxPixelSize)
            self.previewCapturePendingIDs.remove(id)
            guard let image,
                  var latest = self.shaded[id] else {
                wlog("preview-cache: capture unavailable id=\(id) reason=\(reason)")
                return
            }
            latest.previewImage = NSImage(cgImage: image, size: latest.originalSize)
            self.shaded[id] = latest
            completion()
        }
    }

    func hideMenuHoverPreview(id: CGWindowID? = nil) {
        hidePreview(ownerID: id, trigger: .menuHover, reason: "menu-hide")
    }

    func hoverPreviewIsSuppressed(_ id: CGWindowID) -> Bool {
        guard let until = hoverPreviewSuppressedUntil[id] else { return false }
        if until > Date() { return true }
        hoverPreviewSuppressedUntil.removeValue(forKey: id)
        return false
    }

    /// 单击卷帘条：设置里打开了看一眼时，立即在原处按原尺寸显示看一眼的卡片；没打开时什么都不做。
    func stripClicked(_ id: CGWindowID) {
        guard GlanceController.isEnabled else { return }
        MainActor.assumeIsolated { glance.stripClicked(id) }
    }
}

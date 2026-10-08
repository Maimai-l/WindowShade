// 覆盖层视图：卷帘条窗口（截图条/代理标题栏）与预览视窗。视图只通过闭包回调动作，不直接持有 AppDelegate。

import Cocoa
import QuartzCore

// MARK: - 覆盖层

/// 卷帘条在最前面时按 ⌘N / ⌘H / ⌘M / ⌘Q / ⌘W：本意是对它背后的 App 或窗口说的。卷帘条是
/// WindowShade 的窗口，不转的话 ⌘Q 会退出 WindowShade、⌘H 会把所有卷帘条一起藏起来、
/// ⌘M 会把卷帘条自己缩进 Dock。
enum StripKeyForwarding {
    @MainActor static var handler: ((NSWindow, String) -> Bool)?

    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              ["n", "h", "m", "q", "w"].contains(key) else { return false }
        return MainActor.assumeIsolated { handler?(window, key) ?? false }
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        StripKeyForwarding.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// 预览视窗的来源。系统中任一时刻最多只有一个预览视窗。
enum PreviewTrigger {
    case menuHover
}

struct ActivePreview {
    let ownerID: CGWindowID
    let window: NSWindow
    let trigger: PreviewTrigger
}

final class ShadedAccessibilityActionTarget: NSObject {
    private let action: () -> Bool

    init(action: @escaping () -> Bool) {
        self.action = action
    }

    @objc func perform(_ customAction: NSAccessibilityCustomAction) -> Bool {
        action()
    }
}

final class NativeProxyOverlayWindow: NSWindow, NSWindowDelegate {
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    var onAction: ((TrafficAction) -> Void)?
    var onWindowManagementPopover: (() -> Void)?
    var onResize: ((NSWindow) -> Void)?
    var onFrameMoved: ((NSRect) -> Void)?

    /// 卷帘条要正好盖在原来的标题栏上：原窗口伸出屏幕边，卷帘条也跟着伸出去，不让 AppKit 推回屏幕里
    /// （推回来以后展开位置跟着变，窗口就不在原处了）。够不着时由 overlayIsReachable 的调用方拉回。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    var onDragEnded: ((NSRect) -> Void)?
    var fixedTitlebarHeight: CGFloat = proxyTitleBarHeight
    var minimumReadableWidth: CGFloat = 260
    var allowsHorizontalResize = true
    var allowsWindowManagement = true
    var usesProxyTitleLayout = false
    var trafficLightConfiguration = ProxyTrafficLightConfiguration.standard
    private var redirectingFullScreen = false
    private var pendingWindowManagementHover: DispatchWorkItem?
    private var zoomMouseDown = false
    private var zoomPopoverForwarded = false
    /// 卷帘条可能直接出现在一个停着的指针下面（在标题栏上两指上滑收起时，指针停在哪都有可能，
    /// 正好停在绿色按钮的位置就会被当成悬停，窗口随即被展开去弹系统菜单）。这不是想打开窗口
    /// 管理菜单：出现那一刻指针就在绿色按钮上的话，先离开一次，悬停转发才恢复。指针从别处
    /// 移过来、按下绿色按钮都不受影响。
    private var zoomHoverArmed = true
    private var potentialWindowDrag = false
    private var didWindowDrag = false
    private var isClosingProgrammatically = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        StripKeyForwarding.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }

    override func performClose(_ sender: Any?) {
        onAction?(.close)
    }

    override func close() {
        if isClosingProgrammatically {
            super.close()
            return
        }
        onAction?(.close)
    }

    func closeProgrammatically() {
        isClosingProgrammatically = true
        onDoubleClick = nil
        onClick = nil
        onAction = nil
        onWindowManagementPopover = nil
        onResize = nil
        onFrameMoved = nil
        onDragEnded = nil
        delegate = nil
        orderOut(nil)
        super.close()
        isClosingProgrammatically = false
    }

    override func performMiniaturize(_ sender: Any?) {
        onAction?(.minimize)
    }

    override func miniaturize(_ sender: Any?) {
        onAction?(.minimize)
    }

    override func performZoom(_ sender: Any?) {
        guard allowsWindowManagement else { return }
        onAction?(greenTrafficAction)
    }

    override func zoom(_ sender: Any?) {
        guard allowsWindowManagement else { return }
        onAction?(greenTrafficAction)
    }

    override func toggleFullScreen(_ sender: Any?) {
        guard allowsWindowManagement else { return }
        onAction?(greenTrafficAction)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard !redirectingFullScreen else { return }
        redirectingFullScreen = true
        wlog("proxy fullscreen: redirect to real window")
        onAction?(greenTrafficAction)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if self.styleMask.contains(.fullScreen) {
                self.toggleFullScreen(nil)
            }
            self.orderOut(nil)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard redirectingFullScreen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.styleMask.contains(.fullScreen) {
                self.toggleFullScreen(nil)
            }
            self.orderOut(nil)
        }
    }

    func windowDidResize(_ notification: Notification) {
        if usesProxyTitleLayout, let content = contentView {
            alignStandardTrafficButtons(to: ProxyTitleLayoutMetrics.trafficLightRects(
                in: content.bounds,
                actions: trafficLightConfiguration.visibleActions
            ))
        }
        onResize?(self)
    }

    func windowDidMove(_ notification: Notification) {
        onFrameMoved?(frame)
    }

    private var greenTrafficAction: TrafficAction {
        trafficLightConfiguration.visibleActions.contains(.fullScreen) ? .fullScreen : .zoom
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard allowsHorizontalResize else {
            return NSSize(width: sender.frame.width, height: fixedTitlebarHeight)
        }
        return NSSize(width: max(minimumReadableWidth, frameSize.width), height: fixedTitlebarHeight)
    }

    private func pointHitsStandardButton(_ type: NSWindow.ButtonType, _ pointInWindow: NSPoint) -> Bool {
        guard let button = standardWindowButton(type),
              !button.isHidden,
              let superview = button.superview else { return false }
        let p = superview.convert(pointInWindow, from: nil)
        return button.frame.insetBy(dx: -7, dy: -7).contains(p)
    }

    func alignStandardTrafficButtons(to localRects: [(CGRect, TrafficAction)]) {
        guard let content = contentView else { return }
        let types: [(TrafficAction, NSWindow.ButtonType)] = [
            (.close, .closeButton),
            (.minimize, .miniaturizeButton),
            (.zoom, .zoomButton),
            (.fullScreen, .zoomButton),
        ]
        for (action, type) in types {
            guard let sourceRect = localRects.first(where: { $0.1 == action })?.0,
                  let button = standardWindowButton(type),
                  let superview = button.superview else { continue }
            let buttonSize = button.frame.size
            let centered = NSRect(x: sourceRect.midX - buttonSize.width / 2,
                                  y: sourceRect.midY - buttonSize.height / 2,
                                  width: buttonSize.width,
                                  height: buttonSize.height)
            button.frame = superview.convert(centered, from: content)
        }
    }

    func configureTrafficLightButtons(_ configuration: ProxyTrafficLightConfiguration) {
        trafficLightConfiguration = configuration
        let buttons: [(TrafficAction, NSWindow.ButtonType, Bool, Bool)] = [
            (.close, .closeButton, configuration.closeVisible, configuration.closeEnabled),
            (.minimize, .miniaturizeButton, configuration.minimizeVisible, configuration.minimizeEnabled),
            (.zoom, .zoomButton, configuration.zoomVisible, configuration.zoomEnabled),
        ]
        for (_, type, visible, enabled) in buttons {
            guard let button = standardWindowButton(type) else { continue }
            button.isHidden = !visible
            button.isEnabled = enabled
        }
        if let content = contentView {
            alignStandardTrafficButtons(to: ProxyTitleLayoutMetrics.trafficLightRects(
                in: content.bounds,
                actions: configuration.visibleActions
            ))
        }
    }

    func configureWindowManagementButton(capability: WindowManagementCapability) {
        let supportsProxyFullScreen = trafficLightConfiguration.visibleActions.contains(.fullScreen)
        allowsWindowManagement = capability.isEnabled || supportsProxyFullScreen
        if let zoom = standardWindowButton(.zoomButton) {
            zoom.isEnabled = trafficLightConfiguration.zoomEnabled && allowsWindowManagement
        }
    }

    private func pointHitsAnyStandardButton(_ pointInWindow: NSPoint) -> Bool {
        [.closeButton, .miniaturizeButton, .zoomButton].contains {
            pointHitsStandardButton($0, pointInWindow)
        }
    }

    override func orderFrontRegardless() {
        let appearing = !isVisible
        super.orderFrontRegardless()
        if appearing {
            let pointer = convertPoint(fromScreen: NSEvent.mouseLocation)
            zoomHoverArmed = !pointHitsStandardButton(.zoomButton, pointer)
        }
    }

    private func cancelWindowManagementHover() {
        pendingWindowManagementHover?.cancel()
        pendingWindowManagementHover = nil
    }

    private func forwardWindowManagementPopover() {
        cancelWindowManagementHover()
        zoomPopoverForwarded = true
        onWindowManagementPopover?()
    }

    private func scheduleWindowManagementPopover(delay: TimeInterval = 0.55) {
        if pendingWindowManagementHover != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWindowManagementHover = nil
            self?.forwardWindowManagementPopover()
        }
        pendingWindowManagementHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func sendEvent(_ event: NSEvent) {
        let greenAction = greenTrafficAction
        if event.type == .mouseMoved || event.type == .mouseEntered {
            let hitsZoomButton = pointHitsStandardButton(.zoomButton, event.locationInWindow)
            if !hitsZoomButton { zoomHoverArmed = true }
            if allowsWindowManagement && hitsZoomButton && greenAction != .fullScreen {
                if zoomHoverArmed { scheduleWindowManagementPopover() }
                return
            } else {
                cancelWindowManagementHover()
            }
        }
        if event.type == .mouseExited {
            zoomHoverArmed = true
            cancelWindowManagementHover()
            // AppKit must also deliver the exit to content tracking areas so
            // the paper title's hover hint can disappear.
        }
        if event.type == .leftMouseDown,
           allowsWindowManagement,
           pointHitsStandardButton(.zoomButton, event.locationInWindow) {
            zoomMouseDown = true
            zoomPopoverForwarded = false
            if greenAction != .fullScreen {
                scheduleWindowManagementPopover(delay: 0.45)
            }
            return
        }
        if event.type == .leftMouseDown,
           !pointHitsAnyStandardButton(event.locationInWindow) {
            potentialWindowDrag = true
            didWindowDrag = false
        }
        if event.type == .leftMouseUp, zoomMouseDown {
            zoomMouseDown = false
            let wasForwarded = zoomPopoverForwarded
            zoomPopoverForwarded = false
            cancelWindowManagementHover()
            if !wasForwarded, allowsWindowManagement, pointHitsStandardButton(.zoomButton, event.locationInWindow) {
                onAction?(greenAction)
            }
            return
        }
        if event.type == .leftMouseDragged, potentialWindowDrag {
            didWindowDrag = true
        }
        if event.type == .leftMouseDragged, zoomMouseDown {
            return
        }
        if event.type == .leftMouseUp, potentialWindowDrag {
            let dragged = didWindowDrag
            potentialWindowDrag = false
            didWindowDrag = false
            if dragged {
                onDragEnded?(frame)
                return
            }
            // 单击在松开时算，而且只算没拖动的：按下就算的话，拖卷帘条时看一眼会先闪出来。
            if event.clickCount == 1 { onClick?() }
        }
        if event.type == .leftMouseUp,
           event.clickCount == 2,
           !pointHitsAnyStandardButton(event.locationInWindow) {
            onDoubleClick?()
            return
        }
        super.sendEvent(event)
    }
}

final class NativeProxyTitleContentView: NSView {
    static let minimumVisibleTextWidth: CGFloat = 96

    private var hoverArea: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    private let appName: String
    private let windowTitle: String
    private let appIcon: NSImage?
    private let trafficLightSlots: Int

    init(frame: NSRect, appName: String, windowTitle: String, appIcon: NSImage?,
         trafficLightSlots: Int = 3) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.appIcon = appIcon
        self.trafficLightSlots = max(trafficLightSlots, 1)
        super.init(frame: frame)
        clipsToBounds = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        PaperSurfaceStyle.drawEdge(in: bounds, scale: window?.backingScaleFactor ?? 2)
        let title = proxyDisplayTitle(appName: appName, windowTitle: windowTitle)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        // 系统语义颜色：深色、提高对比度与增强活力下都由系统给值，不再手调灰阶。
        let color = NSColor.labelColor
        let attr = NSAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])

        let hasIcon = appIcon != nil
        let centerY = ProxyTitleLayoutMetrics.centerY(in: bounds)
        let iconRect = ProxyTitleLayoutMetrics.iconRect(in: bounds, hasIcon: hasIcon,
                                                        trafficLightSlots: trafficLightSlots)
        var textFrame = ProxyTitleLayoutMetrics.textFrame(in: bounds, hasIcon: hasIcon,
                                                          trafficLightSlots: trafficLightSlots)

        if hovered && textFrame.width > 180 {
            let hint = NSAttributedString(string: "双击展开", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let hintWidth = hint.size().width
            hint.draw(at: NSPoint(x: bounds.maxX - 18 - hintWidth,
                                 y: floor(centerY - hint.size().height / 2)))
            textFrame.size.width = max(0, textFrame.width - hintWidth - 16)
        }
        if let icon = appIcon {
            icon.draw(in: iconRect,
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .sourceOver,
                      fraction: 0.92)
        }

        drawAlignedTitleLine(attr, textX: textFrame.minX, textWidth: textFrame.width, centerY: centerY)
    }

    static func minimumReadableWindowWidth(appName: String, windowTitle: String, hasIcon: Bool,
                                           trafficLightSlots: Int = 3) -> CGFloat {
        let title = proxyDisplayTitle(appName: appName, windowTitle: windowTitle)
        let attr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        let iconWidth = hasIcon ? ProxyTitleLayoutMetrics.iconSize + ProxyTitleLayoutMetrics.iconGap : 0
        let desiredTextWidth = min(max(minimumVisibleTextWidth, attr.size().width * 0.36), 220)
        return ProxyTitleLayoutMetrics.iconCenterX(trafficLightSlots: trafficLightSlots) - ProxyTitleLayoutMetrics.iconSize / 2 +
            iconWidth + desiredTextWidth + ProxyTitleLayoutMetrics.textTrailingInset
    }

    static func titleFittingWindowWidth(appName: String, windowTitle: String, hasIcon: Bool,
                                        trafficLightSlots: Int = 3) -> CGFloat {
        let title = proxyDisplayTitle(appName: appName, windowTitle: windowTitle)
        let attr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        let iconWidth = hasIcon ? ProxyTitleLayoutMetrics.iconSize + ProxyTitleLayoutMetrics.iconGap : 0
        return ceil(ProxyTitleLayoutMetrics.iconCenterX(trafficLightSlots: trafficLightSlots) - ProxyTitleLayoutMetrics.iconSize / 2 +
                    iconWidth + attr.size().width + ProxyTitleLayoutMetrics.textTrailingInset)
    }
}

final class TitleStripView: NSImageView {
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    var onMoveEnded: ((NSRect) -> Void)?
    private var dragOffset = CGPoint.zero
    private var didDrag = false

    /// 截图卷帘条的画面来自真实截图，外观变化时只需要刷新边线。
    func applySystemAppearance(capabilities: SystemAppearanceCapabilities = .current) {
        wantsLayer = true
        layer?.borderWidth = SystemAppearancePolicy.edgeWidth(capabilities)
        layer?.borderColor = SystemAppearancePolicy.cgColor(NSColor.separatorColor, for: self)
    }

    /// 截图卷帘条：画面来自真实窗口截图，VoiceOver 读出标题并提供展开动作。
    func configureAccessibility(appName: String, windowTitle: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(PaperSurfaceAccessibility.stripLabel(appName: appName,
                                                                   windowTitle: windowTitle))
        setAccessibilityHelp(PaperSurfaceAccessibility.stripHelp())
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "展开窗口") { [weak self] in
                self?.accessibilityPerformPress() ?? false
            }
        ])
        // 截图条可能被裁短，鼠标悬停时给出完整标题。
        let clean = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        toolTip = clean.isEmpty ? appName : "\(appName) — \(clean)"
    }

    /// VoiceOver 的“按下”（VO-Space）等价于双击展开。
    override func accessibilityPerformPress() -> Bool {
        guard onDoubleClick != nil else { return false }
        onDoubleClick?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let m = NSEvent.mouseLocation
        dragOffset = CGPoint(x: m.x - window.frame.origin.x, y: m.y - window.frame.origin.y)
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let m = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y))
        didDrag = true
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag {
            didDrag = false
            if let window { onMoveEnded?(window.frame) }
            return
        }
        // 单击在松开时算，而且只算没拖动的：按下就算的话，拖卷帘条时看一眼会先闪出来。
        if event.clickCount == 1 { onClick?() }
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

// 盖在真交通灯上的透明命中区。
// 视觉完全来自系统真实渲染后的截图；这里只负责把点击转发给真窗口。
final class TrafficLightsView: NSView {
    private let lights: [(CGRect, TrafficAction)]
    var onAction: ((TrafficAction) -> Void)?
    private var pressedAction: TrafficAction?

    init(frame: NSRect, lights: [(CGRect, TrafficAction)]) {
        self.lights = lights
        super.init(frame: frame)
        // 只是盖在真交通灯上的透明命中区，VoiceOver 读到的是源窗口自己的按钮。
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func action(at point: NSPoint) -> TrafficAction? {
        lights.first(where: { $0.0.contains(point) })?.1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        action(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        pressedAction = action(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAction = nil }
        let p = convert(event.locationInWindow, from: nil)
        if let pressed = pressedAction, action(at: p) == pressed {
            onAction?(pressed)
        }
    }
}

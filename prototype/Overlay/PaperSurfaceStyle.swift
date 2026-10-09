import Cocoa

/// 纸面表面共用的边线和阴影尺寸。
enum PaperSurfaceStyle {
    /// 纸面阴影：提高对比度时阴影更深、更明确（系统外观策略统一决定）。
    static func shadow(capabilities: SystemAppearanceCapabilities = .current) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = capabilities.increaseContrast ? 10 : 12
        shadow.shadowColor = SystemAppearancePolicy.shadowColor(capabilities)
        return shadow
    }

    /// 细线按屏幕的像素倍率对齐；提高对比度时加粗并去掉顶部高光。
    static func drawEdge(in bounds: NSRect, scale: CGFloat,
                         capabilities: SystemAppearanceCapabilities = .current) {
        let width = SystemAppearancePolicy.edgeWidth(capabilities)
        NSColor.separatorColor.setStroke()
        // 卷帘条是收起后留下的窗口顶部：上面两角和系统窗口一样，是 13 点的连续曲率圆角；
        // 下边是直边，和原标题栏的卷帘条里的窗口标题栏对齐。
        let radius = SystemCornerRadius.surfaceRadius(forHeight: bounds.height)
        let border = SystemCornerPath.path(in: bounds.insetBy(dx: width / 2, dy: width / 2),
                                           radius: radius, corners: .top)
        border.lineWidth = width
        border.stroke()
        let highlight = SystemAppearancePolicy.highlightAlpha(capabilities)
        guard highlight > 0 else { return }
        NSColor.white.withAlphaComponent(highlight).setFill()
        let pixel = 1 / max(scale, 1)
        let inset = radius
        NSRect(x: inset, y: bounds.maxY - pixel,
               width: max(0, bounds.width - inset * 2), height: pixel).fill()
    }
}

/// 画纸面阴影的视图，放在不接收鼠标的子窗口（PaperShadowPanel）里，不改父窗口的外框（外框要和原窗口对齐）。
private final class PaperShadowView: NSView {
    /// 面板四角都要圆；卷帘条只有上面两角圆（下边是收起后留下的直边）。
    var corners: SystemCornerPath.Corners = .all {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 24, dy: 24)
        let paper = SystemCornerPath.path(
            in: inset, radius: SystemCornerRadius.surfaceRadius(forHeight: inset.height),
            corners: corners)
        NSGraphicsContext.saveGraphicsState()
        PaperSurfaceStyle.shadow(capabilities: .current).set()
        NSColor.black.setFill()
        paper.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        paper.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 纸面阴影子窗口：不接收鼠标，也不能成为主窗口或键盘焦点窗口。它只用来画阴影，
/// 移到前面时不该激活所属的应用程序，也不该抢走键盘焦点。
private final class PaperShadowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 隐藏、显示、移动、换桌面时，阴影子窗口的前后顺序都跟着父窗口。
@MainActor
private final class PaperWindowShadow: NSObject {
    private weak var parent: NSWindow?
    private let panel: NSPanel
    private let shadowView: PaperShadowView
    // 只在主线程写；deinit 里移除时已没有别的引用。
    nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
    private var alphaObservation: NSKeyValueObservation?
    private var levelObservation: NSKeyValueObservation?

    init(parent: NSWindow, corners: SystemCornerPath.Corners = .all) {
        self.parent = parent
        shadowView = PaperShadowView(frame: parent.frame.insetBy(dx: -24, dy: -24))
        shadowView.corners = corners
        panel = PaperShadowPanel(contentRect: parent.frame.insetBy(dx: -24, dy: -24),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityElement(false)
        panel.hidesOnDeactivate = false
        panel.level = parent.level
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        shadowView.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = shadowView
        parent.hasShadow = false
        parent.addChildWindow(panel, ordered: .below)
        alphaObservation = parent.observe(\.alphaValue, options: [.initial, .new]) { [weak self] window, _ in
            // AppKit 在修改这个属性的线程上回调；窗口属性只在主线程改。
            MainActor.assumeIsolated { self?.panel.alphaValue = window.alphaValue }
        }
        levelObservation = parent.observe(\.level, options: [.new]) { [weak self] window, _ in
            // AppKit 在修改这个属性的线程上回调；窗口属性只在主线程改。
            MainActor.assumeIsolated { self?.panel.level = window.level }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: parent, queue: .main
        ) { [weak self] _ in
            // 观察者指定了主队列，回调在主线程。
            MainActor.assumeIsolated {
                guard let self, let parent = self.parent else { return }
                self.panel.setFrame(parent.frame.insetBy(dx: -24, dy: -24), display: true)
            }
        }
    }

    deinit {
        // 这个影子只挂在主线程的窗口上，最后一次释放也在主线程。
        MainActor.assumeIsolated {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

/// 只取它的地址当关联对象的键，从不读写它的值。
nonisolated(unsafe) private var paperShadowAssociation: UInt8 = 0
extension PaperSurfaceStyle {
    /// `corners` 决定阴影轮廓：面板用 `.all`，卷帘条用 `.top`。
    static func installShadow(on window: NSWindow,
                              corners: SystemCornerPath.Corners = .all) {
        let already = objc_getAssociatedObject(window, &paperShadowAssociation) != nil
        MainActor.assumeIsolated {
            window.hasShadow = false
            guard !already else { return }
            objc_setAssociatedObject(window, &paperShadowAssociation,
                                     PaperWindowShadow(parent: window, corners: corners),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

extension PaperSurfaceStyle {
    static func removeShadow(from window: NSWindow) {
        objc_setAssociatedObject(window, &paperShadowAssociation, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

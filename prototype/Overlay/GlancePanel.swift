// 看一眼的画面：一张单独的卡片，和真窗口分得开。
// 收起的窗口：原貌卷帘条不动，卡片挂在它下面、隔一道缝，显示标题栏以下的内容。
// 缩略图：卡片就是整扇窗口，从缩略图长回原来的大小，移开时缩回去（grow / shrink）。
// 卡片四个角都用真窗口的圆角（从截图里量），带自己的投影；有画面时不铺底色。
// 被隐藏的 App 临时在原处取消隐藏时，缝和圆角缺口底下垫一张真实背景，真窗口露不出来。
// 面板不激活 WindowShade、不抢键盘焦点；单击卡片才真正打开那扇窗。

import AVFoundation
import Cocoa

final class GlancePanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = "WindowShade 看一眼"
        level = .floating
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        isOpaque = false
        backgroundColor = .clear
        // 投影画在卡片上：窗口自带的投影会连背景垫片一起勾出一个方框。
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        tabbingMode = .disallowed
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class GlanceContentView: NSView {
    /// 卡片四周给投影留的边距（点）。
    static let shadowMargin: CGFloat = 24

    var onClick: (() -> Void)?

    /// 卡片在本视图里的位置（非翻转坐标）。
    let cardFrame: NSRect
    /// 整扇窗口的画面在卡片里的位置；超出卡片的部分（标题栏、屏幕外）被裁掉。
    let pictureFrame: NSRect
    /// 见 GlanceTarget.stripJoin：大于 0 时卡片上沿是直角，再往上补出卷帘条圆角外的两小块。
    let stripJoin: CGFloat

    private let backdropLayer = CALayer()
    private let shadowLayer = CALayer()
    private let cardLayer = CALayer()
    private let snapshotLayer = CALayer()
    private weak var videoLayer: AVSampleBufferDisplayLayer?
    private let rollMask = CALayer()
    private(set) var hasSnapshot = false
    private(set) var isLive = false

    init(frame: NSRect, cardFrame: NSRect, pictureFrame: NSRect, cornerRadius: CGFloat,
         stripJoin: CGFloat = 0, accessibilityTitle: String) {
        self.cardFrame = cardFrame
        self.pictureFrame = pictureFrame
        self.stripJoin = stripJoin
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root
        root.masksToBounds = true
        backdropLayer.contentsGravity = .resize
        backdropLayer.isHidden = true
        root.addSublayer(backdropLayer)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.26
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        root.addSublayer(shadowLayer)
        if stripJoin > 0 {
            // 卡片层往上多出 stripJoin 高，形状由 mask 给：下面两角圆、上沿直角，再加上卷帘条
            // 两个下圆角外的缺口。投影只留在卡片上沿以下，不落到卷帘条上。
            let shape = CAShapeLayer()
            shape.path = Self.joinedCardPath(size: cardFrame.size, radius: cornerRadius, join: stripJoin)
            cardLayer.mask = shape
            let shadowClip = CALayer()
            shadowClip.backgroundColor = NSColor.black.cgColor
            shadowClip.frame = CGRect(x: 0, y: 0, width: frame.width, height: cardFrame.maxY)
            shadowLayer.mask = shadowClip
        } else {
            cardLayer.masksToBounds = true
            cardLayer.cornerRadius = cornerRadius
            cardLayer.cornerCurve = .continuous
        }
        root.addSublayer(cardLayer)
        snapshotLayer.contentsGravity = .resize
        snapshotLayer.minificationFilter = .trilinear
        cardLayer.addSublayer(snapshotLayer)
        rollMask.backgroundColor = NSColor.black.cgColor
        rollMask.anchorPoint = CGPoint(x: 0, y: 1)
        root.mask = rollMask
        shadowLayer.shadowPath = CGPath(roundedRect: cardFrame, cornerWidth: cornerRadius,
                                        cornerHeight: cornerRadius, transform: nil)

        applySystemAppearance()

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("看一眼：\(accessibilityTitle)")
        setAccessibilityHelp("单击打开这个窗口")
    }

    required init?(coder: NSCoder) { nil }

    /// 卡片接卷帘条时往上多盖的一道（点）：盖住卷帘条下沿和圆角上那道细边，真窗口上没有这道线。
    static let stripEdgeCover: CGFloat = 2

    /// 接在卷帘条下的卡片形状（卡片层坐标，原点在左下，卡片上沿在 size.height）：下面两角圆，
    /// 上沿直角并往上多盖 stripEdgeCover；再加上左右两个角落里、卷帘条下圆角外面的那一小块，
    /// 同样往圆角里多盖 stripEdgeCover。
    static func joinedCardPath(size: CGSize, radius: CGFloat, join: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = min(radius, size.width / 2, size.height / 2)
        let edge = min(stripEdgeCover, join)
        let top = size.height + edge
        path.move(to: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: r, y: 0), radius: r)
        path.addLine(to: CGPoint(x: size.width - r, y: 0))
        path.addArc(tangent1End: CGPoint(x: size.width, y: 0),
                    tangent2End: CGPoint(x: size.width, y: r), radius: r)
        path.addLine(to: CGPoint(x: size.width, y: top))
        path.closeSubpath()
        let cornerY = size.height + join
        // 三块都按逆时针走：和卡片本体重叠的那 2 点里绕数相加，方向相反会抵消成一个洞。
        // 左边：角落方块减去以卷帘条左下圆角圆心为心、半径小 edge 的圆。
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: join, y: size.height))
        path.addArc(center: CGPoint(x: join, y: cornerY), radius: join - edge,
                    startAngle: 1.5 * .pi, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: cornerY))
        path.closeSubpath()
        // 右边对称。
        path.move(to: CGPoint(x: size.width, y: cornerY))
        path.addLine(to: CGPoint(x: size.width - edge, y: cornerY))
        path.addArc(center: CGPoint(x: size.width - join, y: cornerY), radius: join - edge,
                    startAngle: 0, endAngle: -0.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: size.width - join, y: size.height))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 只有卡片本身接单击；缝、投影边距上点了不算打开。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return cardFrame.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func accessibilityFrame() -> NSRect {
        window?.convertToScreen(convert(cardFrame, to: nil)) ?? super.accessibilityFrame()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 用 bounds + position 摆，不用 frame：缩略图的看一眼长大、缩回时这两层带着变换，
        // 那时写 frame 会被变换折算错。没有变换时两种写法一样。
        shadowLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        shadowLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        cardLayer.bounds = CGRect(origin: .zero, size: CGSize(width: cardFrame.width,
                                                              height: cardFrame.height + stripJoin))
        cardLayer.position = CGPoint(x: cardFrame.midX, y: cardFrame.minY + (cardFrame.height + stripJoin) / 2)
        snapshotLayer.frame = pictureFrame
        videoLayer?.frame = pictureFrame
        if rollMask.animationKeys()?.isEmpty ?? true {
            rollMask.bounds = CGRect(x: 0, y: 0, width: bounds.width,
                                     height: rollMask.bounds.height)
            rollMask.position = CGPoint(x: 0, y: bounds.height)
        }
        CATransaction.commit()
    }

    /// 真窗口临时在底下时：把那块区域原本的背景垫在卡片下面（缝与圆角缺口里看到的就是它）。
    func setBackdrop(_ image: CGImage, frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.contents = image
        backdropLayer.frame = frame
        backdropLayer.isHidden = false
        CATransaction.commit()
    }

    func setSnapshot(_ image: CGImage?) {
        hasSnapshot = image != nil
        snapshotLayer.contents = image
        refreshPlaceholder()
    }

    func attachVideo(_ layer: AVSampleBufferDisplayLayer) {
        videoLayer?.removeFromSuperlayer()
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.clear.cgColor
        cardLayer.addSublayer(layer)
        videoLayer = layer
        needsLayout = true
    }

    /// 实时画面到了：盖住截图。
    func setLive(_ live: Bool) {
        isLive = live
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.isHidden = live && videoLayer != nil
        CATransaction.commit()
        refreshPlaceholder()
    }

    private func refreshPlaceholder() {
        applySystemAppearance()
        needsLayout = true
    }

    /// 卡片的底色与细边只在什么画面都没有时出现：窗口画面自带边缘，多一层会在角上露出月牙。
    func applySystemAppearance(capabilities: SystemAppearanceCapabilities = .current) {
        let bare = !hasSnapshot && !isLive
        cardLayer.borderWidth = bare ? SystemAppearancePolicy.edgeWidth(capabilities) : 0
        cardLayer.borderColor = SystemAppearancePolicy.cgColor(NSColor.separatorColor, for: self)
        cardLayer.backgroundColor = bare
            ? SystemAppearancePolicy.cgColor(NSColor.windowBackgroundColor, for: self)
            : NSColor.clear.cgColor
    }

    // MARK: 卷下 / 卷上

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func rollDown(duration: CFTimeInterval = 0.18) {
        layoutSubtreeIfNeeded()
        let full = bounds.height
        rollMask.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rollMask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: full)
        rollMask.position = CGPoint(x: 0, y: full)
        CATransaction.commit()
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            layer?.add(fade, forKey: "glance-fade")
            return
        }
        let roll = CABasicAnimation(keyPath: "bounds.size.height")
        roll.fromValue = 0
        roll.toValue = full
        roll.duration = duration
        roll.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        rollMask.add(roll, forKey: "glance-roll")
    }

    /// 卷上（或缩回缩略图）途中指针又回来了：停在全开，不重播卷下。
    func cancelRollUp() {
        rollMask.removeAllAnimations()
        layer?.removeAnimation(forKey: "glance-fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 1
        rollMask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        rollMask.position = CGPoint(x: 0, y: bounds.height)
        for grown in [shadowLayer, cardLayer] {
            grown.removeAnimation(forKey: "glance-grow")
            grown.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    // MARK: 从缩略图长回原大小 / 缩回缩略图

    /// 卡片（连同投影）缩在 rect（本视图坐标）里的样子：把卡片外框映到 rect 上的变换。
    private func shrunkTransform(for target: CALayer, into rect: NSRect) -> CATransform3D {
        guard cardFrame.width > 0, cardFrame.height > 0 else { return CATransform3DIdentity }
        let kx = rect.width / cardFrame.width
        let ky = rect.height / cardFrame.height
        let p = target.position
        let tx = rect.minX + kx * (p.x - cardFrame.minX) - p.x
        let ty = rect.minY + ky * (p.y - cardFrame.minY) - p.y
        return CATransform3DConcat(CATransform3DMakeScale(kx, ky, 1), CATransform3DMakeTranslation(tx, ty, 0))
    }

    /// 缩略图上停够了：卡片从缩略图（rect，本视图坐标）长回窗口原来的大小，弹簧 0.3 / 不回弹。
    /// 返回多久之后卡片整张盖住原处（被隐藏的 App 要等到那时才在下面取消隐藏）。
    @discardableResult
    func grow(from rect: NSRect) -> CFTimeInterval {
        layoutSubtreeIfNeeded()
        rollMask.removeAllAnimations()
        layer?.removeAnimation(forKey: "glance-fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 1
        rollMask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        rollMask.position = CGPoint(x: 0, y: bounds.height)
        for grown in [shadowLayer, cardLayer] {
            grown.removeAnimation(forKey: "glance-grow")
            grown.transform = CATransform3DIdentity
        }
        CATransaction.commit()
        if reduceMotion {
            // 整张一起淡入。
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            layer?.add(fade, forKey: "glance-fade")
            return 0.12
        }
        var settle: CFTimeInterval = 0
        for grown in [shadowLayer, cardLayer] {
            let spring = CASpringAnimation(perceptualDuration: 0.3, bounce: 0)
            spring.keyPath = "transform"
            spring.fromValue = NSValue(caTransform3D: shrunkTransform(for: grown, into: rect))
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.duration = spring.settlingDuration
            settle = spring.settlingDuration
            grown.add(spring, forKey: "glance-grow")
        }
        // 临界阻尼的弹簧到 0.45 秒已差不到 0.1%：千点宽的窗口也露不出一点。
        let covered = min(settle, 0.45)
        return covered
    }

    /// 指针移开：卡片缩回缩略图（rect，本视图坐标），0.16 秒，缩完再交回 completion。
    func shrink(to rect: NSRect, completion: @escaping () -> Void) {
        rollMask.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        if reduceMotion {
            layer?.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.1
            layer?.add(fade, forKey: "glance-fade")
        } else {
            for grown in [shadowLayer, cardLayer] {
                let from = grown.presentation()?.transform ?? grown.transform
                let to = shrunkTransform(for: grown, into: rect)
                grown.removeAnimation(forKey: "glance-grow")
                grown.transform = to
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.fromValue = NSValue(caTransform3D: from)
                shrink.toValue = NSValue(caTransform3D: to)
                shrink.duration = 0.16
                shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
                grown.add(shrink, forKey: "glance-grow")
            }
        }
        CATransaction.commit()
    }

    func rollUp(duration: CFTimeInterval = 0.14, completion: @escaping () -> Void) {
        let current = rollMask.presentation()?.bounds.height ?? rollMask.bounds.height
        rollMask.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        if reduceMotion {
            layer?.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.1
            layer?.add(fade, forKey: "glance-fade")
        } else {
            rollMask.bounds.size.height = 0
            let roll = CABasicAnimation(keyPath: "bounds.size.height")
            roll.fromValue = current
            roll.toValue = 0
            roll.duration = duration * Double(max(0.3, current / max(1, bounds.height)))
            roll.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
            rollMask.add(roll, forKey: "glance-roll")
        }
        CATransaction.commit()
    }
}

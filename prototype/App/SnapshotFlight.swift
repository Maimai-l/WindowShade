// 窗口截图从一个外框移动到另一个外框：缩略图收起、展开时用。

import Cocoa

/// 窗口截图从一个外框移动到另一个外框（Core Animation 的弹簧）：位置的弹簧参数由 fly 的 response、bounce 给出，
/// 尺寸和圆角用 Motion.Spring.settle。
/// 面板一次开到能容纳整条路径（含弹簧超出终点的余量），之后只移动里面那一层：面板窗口本身一帧都不移动。
@MainActor
final class SnapshotFlight {
    private let panel: NSPanel
    private let picture = CALayer()
    private let area: NSRect

    /// from、to：Cocoa 坐标。joinsAllSpaces = false：只留在当前桌面上
    /// （用于先盖在原处、稍后才开始动画的截图，中途切换桌面时不跟过去）。
    init(image: CGImage, from: NSRect, to: NSRect, level: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1),
         joinsAllSpaces: Bool = true) {
        area = from.union(to).insetBy(dx: -80, dy: -80)
        panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = level
        panel.collectionBehavior = joinsAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            : [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let root = NSView(frame: NSRect(origin: .zero, size: area.size))
        root.wantsLayer = true
        picture.contents = image
        picture.contentsGravity = .resize
        picture.cornerRadius = 10
        picture.masksToBounds = true
        picture.frame = from.offsetBy(dx: -area.minX, dy: -area.minY)
        root.layer?.addSublayer(picture)
        panel.contentView = root
        panel.orderFrontRegardless()
    }

    /// 面板开出的那块地方够不够移动到 target（Cocoa 坐标）：够不着的部分会被面板边裁掉。
    func canReach(_ target: NSRect) -> Bool {
        area.contains(target)
    }

    /// velocity：点/秒，Cocoa 坐标（y 向上）。
    func fly(to target: NSRect, velocity: CGVector, response: Double = 0.42, bounce: CGFloat = 0.12,
             cornerRadius: CGFloat? = nil, done: @escaping () -> Void) {
        let end = target.offsetBy(dx: -area.minX, dy: -area.minY)
        if Motion.reduced {
            dissolve(to: end, cornerRadius: cornerRadius, done: done)
            return
        }
        let start = picture.frame

        CATransaction.begin()
        CATransaction.setCompletionBlock { done() }
        // 横、竖各用一条弹簧（WWDC18：二维运动拆成相互独立的轴），各自接上甩动速度在这条轴上的分量；
        // 只把速度投影到连线上会丢掉横向分量，斜着甩时起步会转弯。
        // CASpringAnimation 的初速度按“这条轴剩下的路程每秒走几倍”算。
        func axis(_ keyPath: String, from: CGFloat, to: CGFloat, speed: CGFloat) -> CASpringAnimation {
            let spring = CASpringAnimation(perceptualDuration: response, bounce: bounce)
            spring.keyPath = keyPath
            spring.fromValue = from
            spring.toValue = to
            let distance = to - from
            spring.initialVelocity = abs(distance) > 1 ? max(-40, min(40, speed / distance)) : 0
            spring.duration = spring.settlingDuration
            return spring
        }
        let positionX = axis("position.x", from: start.midX, to: end.midX, speed: velocity.dx)
        let positionY = axis("position.y", from: start.midY, to: end.midY, speed: velocity.dy)
        // 尺寸用 settle：不回弹，时长按它自己的弹簧计算。
        let size = CASpringAnimation(perceptualDuration: Motion.Spring.settle.response, bounce: Motion.Spring.settle.bounce)
        size.keyPath = "bounds.size"
        size.fromValue = NSValue(size: start.size)
        size.toValue = NSValue(size: end.size)
        size.duration = size.settlingDuration
        var animations: [CAAnimation] = [positionX, positionY, size]
        if let cornerRadius {
            let corner = CASpringAnimation(perceptualDuration: Motion.Spring.settle.response, bounce: Motion.Spring.settle.bounce)
            corner.keyPath = "cornerRadius"
            corner.fromValue = picture.cornerRadius
            corner.toValue = cornerRadius
            corner.duration = corner.settlingDuration
            animations.append(corner)
        }
        CATransaction.setDisableActions(true)
        picture.position = CGPoint(x: end.midX, y: end.midY)
        picture.bounds = CGRect(origin: .zero, size: end.size)
        if let cornerRadius { picture.cornerRadius = cornerRadius }
        for animation in animations { picture.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath) }
        CATransaction.commit()
    }

    /// 减少动态效果时截图不移动：原处淡出，目标处淡入。
    private func dissolve(to end: CGRect, cornerRadius: CGFloat?, done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { done() }
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = 0.2
        picture.opacity = 0
        picture.add(out, forKey: "dissolve")
        let arrival = CALayer()
        arrival.contents = picture.contents
        arrival.contentsGravity = .resize
        arrival.cornerRadius = cornerRadius ?? picture.cornerRadius
        arrival.masksToBounds = true
        arrival.frame = end
        picture.superlayer?.addSublayer(arrival)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.2
        arrival.add(fadeIn, forKey: "dissolve")
        CATransaction.commit()
    }

    func remove(fade: Bool = true) {
        let panel = self.panel
        guard fade else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // 动画完成回调在主线程。
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

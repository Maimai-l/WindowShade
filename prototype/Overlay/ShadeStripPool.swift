// 简单卷帘条窗口池：没有红绿灯的原标题栏卷帘条（OverlayWindow）复用，避免频繁创建 NSWindow。
// 带红绿灯的卷帘条窗口（NativeProxyOverlayWindow，原标题栏和简化标题栏都用它）带着很多每扇窗口各自的状态
// （红绿灯配置、窗口代理对象、窗口管理能力），不复用。
//
// 池内窗口 isReleasedWhenClosed = false（makeBaseOverlay 设置）；内容视图在
// 回收与取出时清空，避免闭包（unshade 等）滞留形成引用环。

import Cocoa

@MainActor
final class ShadeStripPool {
    /// 取出和回收都要求在主队列上（下面有 dispatchPrecondition），所以整个类标成 @MainActor。
    static let shared = ShadeStripPool()

    private var available: [OverlayWindow] = []
    private let maxPooled = 4

    func take() -> OverlayWindow? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !available.isEmpty else { return nil }
        let window = available.removeLast()
        PaperSurfaceStyle.removeShadow(from: window)
        window.contentView = nil
        return window
    }

    func recycle(_ window: OverlayWindow) {
        dispatchPrecondition(condition: .onQueue(.main))
        PaperSurfaceStyle.removeShadow(from: window)
        window.contentView = nil
        if available.count < maxPooled {
            available.append(window)
        } else {
            window.close()
        }
    }
}

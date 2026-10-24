// AX（左上原点）与 Cocoa（左下原点）坐标换算、屏幕归属。

import Cocoa

// AX / CGEvent 坐标以主屏左上为原点、y 向下；NSWindow 坐标以主屏左下为原点、y 向上。
// 多显示器时副屏可以有负 y，但两套坐标仍共享同一个主屏高度作为翻转基线。
func coordinateBaselineY() -> CGFloat {
    (NSScreen.screens.first { $0.frame.origin == .zero }?.frame.maxY)
        ?? NSScreen.main?.frame.maxY ?? 0
}

func cocoaFrame(fromAXPosition p: CGPoint, size: CGSize) -> NSRect {
    NSRect(x: p.x, y: coordinateBaselineY() - p.y - size.height,
           width: size.width, height: size.height)
}

func axPosition(fromCocoaFrame frame: NSRect) -> CGPoint {
    CGPoint(x: frame.minX, y: coordinateBaselineY() - frame.maxY)
}

func screenForAXWindow(pos: CGPoint, size: CGSize) -> NSScreen? {
    let rect = cocoaFrame(fromAXPosition: pos, size: size)
    return screenForCocoaFrame(rect)
}

func screenForCocoaFrame(_ rect: NSRect) -> NSScreen? {
    func intersectionArea(_ screen: NSScreen) -> CGFloat {
        let hit = screen.frame.intersection(rect)
        return hit.isNull ? 0 : hit.width * hit.height
    }
    if let best = NSScreen.screens.max(by: { intersectionArea($0) < intersectionArea($1) }),
       intersectionArea(best) > 0 {
        return best
    }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.min {
        let a = $0.frame
        let b = $1.frame
        let da = hypot(center.x - a.midX, center.y - a.midY)
        let db = hypot(center.x - b.midX, center.y - b.midY)
        return da < db
    } ?? NSScreen.main
}

func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
    screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        .flatMap { ($0 as? NSNumber)?.uint32Value }
}

/// 显示器本身的样子：有哪几块屏、各自的位置尺寸与缩放。
/// 菜单栏时隐时现、Dock 高度差一点只改 visibleFrame，不算在内——接 Studio Display 的
/// Mac 上这类“屏幕参数变了”每隔几秒就来一次，只有这里变了才算真的换了屏。
struct DisplayLayout: Equatable {
    struct Screen: Equatable {
        let id: CGDirectDisplayID?
        let frame: CGRect
        let scale: CGFloat
    }
    let screens: [Screen]

    static func current() -> DisplayLayout {
        DisplayLayout(screens: NSScreen.screens.map {
            Screen(id: displayID(for: $0), frame: $0.frame, scale: $0.backingScaleFactor)
        })
    }
}

func screenForDisplayID(_ displayID: CGDirectDisplayID?) -> NSScreen? {
    guard let displayID else { return nil }
    return NSScreen.screens.first {
        (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value) == displayID
    }
}

func backingScaleForAXWindow(pos: CGPoint, size: CGSize) -> CGFloat {
    screenForAXWindow(pos: pos, size: size)?.backingScaleFactor
        ?? NSScreen.main?.backingScaleFactor ?? 2
}

extension ScreenLayout {
    /// 只在主线程调用。
    static func current() -> ScreenLayout {
        let baseline = coordinateBaselineY()
        return ScreenLayout(screens: NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: baseline - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        })
    }
}

/// 屏幕的快照：在主线程用 current() 取一次，交给后台队列用，后台不再读 NSScreen（NSScreen 只在主线程访问）。
/// 找回屏幕外窗口的扫描在 rescueWorkQueue 上做，要判断窗口可见、换算坐标、把放回的位置挪进屏幕，用的就是这几项。
/// 坐标和 NSScreen 一样是 Cocoa 的（主屏左下为原点）；各方法的算法和上面读 NSScreen 的同名函数相同。
struct ScreenSnapshot: Sendable {
    struct Screen: Sendable {
        let displayID: CGDirectDisplayID?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    /// 翻转基线，即主屏的高度（见 coordinateBaselineY）。
    let baselineY: CGFloat
    /// 第一项是主屏。
    let screens: [Screen]

    @MainActor
    static func current() -> ScreenSnapshot {
        ScreenSnapshot(baselineY: coordinateBaselineY(), screens: NSScreen.screens.map { screen in
            Screen(displayID: displayID(for: screen), frame: screen.frame, visibleFrame: screen.visibleFrame)
        })
    }

    func cocoaFrame(fromAXPosition p: CGPoint, size: CGSize) -> NSRect {
        NSRect(x: p.x, y: baselineY - p.y - size.height, width: size.width, height: size.height)
    }

    func axPosition(fromCocoaFrame frame: NSRect) -> CGPoint {
        CGPoint(x: frame.minX, y: baselineY - frame.maxY)
    }

    /// 同 windowIsVisible(pos:size:)：露出一块看得见的部分才算可见。
    func isVisible(pos: CGPoint, size: CGSize) -> Bool {
        rectIsVisible(cocoaFrame(fromAXPosition: pos, size: size), onScreens: screens.map(\.frame))
    }

    /// 同 screenForCocoaFrame(_:)：重叠面积最大的那块屏；都不重叠时取中心最近的一块。
    func screen(for rect: NSRect) -> Screen? {
        func area(_ screen: Screen) -> CGFloat {
            let hit = screen.frame.intersection(rect)
            return hit.isNull ? 0 : hit.width * hit.height
        }
        if let best = screens.max(by: { area($0) < area($1) }), area(best) > 0 { return best }
        func distance(_ screen: Screen) -> CGFloat {
            hypot(rect.midX - screen.frame.midX, rect.midY - screen.frame.midY)
        }
        return screens.min { distance($0) < distance($1) }
    }

    /// 同 AppDelegate.clampedFrame：把 frame 挪进屏幕的可用区域，四周留 margin；
    /// 优先放进 preferredDisplayID 那块屏，找不到它时用 frame 所在的屏。
    func clampedFrame(_ frame: NSRect, margin: CGFloat = 8, preferredDisplayID: CGDirectDisplayID? = nil) -> NSRect {
        let preferred = preferredDisplayID.flatMap { id in screens.first { $0.displayID == id } }
        let usable = (preferred ?? screen(for: frame))?.visibleFrame ?? frame
        var visible = usable.insetBy(dx: margin, dy: margin)
        if visible.width <= 1 || visible.height <= 1 { visible = usable }
        var result = frame
        if result.width <= visible.width {
            result.origin.x = min(max(result.origin.x, visible.minX), visible.maxX - result.width)
        } else {
            result.origin.x = visible.minX
        }
        if result.height <= visible.height {
            result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
        } else {
            result.origin.y = visible.minY
        }
        return result
    }
}

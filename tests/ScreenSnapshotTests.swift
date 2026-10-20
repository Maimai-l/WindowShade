// 覆盖 R1 R4：交给后台队列用的屏幕快照（Window/Coordinates.swift 的 ScreenSnapshot）。
// 缺陷回归（2026-10-20 代码审查发现）：找回屏幕外窗口的扫描在后台队列上直接读 NSScreen
// （windowIsVisible、cocoaFrame、axPosition(fromCocoaFrame:)、clampedFrame），而 NSScreen 只能在主线程访问；
// 接上、拔下显示器时正好会开始这次扫描。快照在主线程取好，后台只用快照算。
// 这里用两块假屏检查快照的换算、可见判断和挪进屏幕，和读 NSScreen 的同名函数算法一致。
import Cocoa

@main
struct ScreenSnapshotTests {
    @MainActor
    static func main() {
        var suite = TestSuite("ScreenSnapshotTests")
        // 主屏 1440×900，菜单栏 25 点；右边一块 1920×1080，底边对齐。
        let layout = ScreenSnapshot(baselineY: 900, screens: [
            .init(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                  visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)),
            .init(displayID: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                  visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)),
        ])

        suite.section("C1", "AX and Cocoa coordinates flip at the primary screen's height")
        let cocoa = layout.cocoaFrame(fromAXPosition: CGPoint(x: 100, y: 100), size: CGSize(width: 400, height: 300))
        suite.expect(cocoa == CGRect(x: 100, y: 500, width: 400, height: 300), "AX top-left becomes Cocoa bottom-left")
        suite.expect(layout.axPosition(fromCocoaFrame: cocoa) == CGPoint(x: 100, y: 100), "and back")

        suite.section("C2", "visibility matches windowIsVisible")
        suite.expect(layout.isVisible(pos: CGPoint(x: 100, y: 100), size: CGSize(width: 400, height: 300)),
                     "a window on the primary screen is visible")
        suite.expect(!layout.isVisible(pos: CGPoint(x: -32000, y: -32000), size: CGSize(width: 400, height: 300)),
                     "a window at the parking spot is not")
        suite.expect(!layout.isVisible(pos: CGPoint(x: 3359, y: -179), size: CGSize(width: 400, height: 300)),
                     "a window showing one pixel at a screen corner is not")

        suite.section("C3", "clamping into the preferred screen, else the screen the frame is on")
        let parked = CGRect(x: -5000, y: -5000, width: 400, height: 300)
        suite.expect(layout.clampedFrame(parked, margin: 16, preferredDisplayID: 2).origin == CGPoint(x: 1456, y: 16),
                     "a window parked far away goes onto the display it was folded on")
        let straddling = CGRect(x: 1300, y: 800, width: 400, height: 300)
        suite.expect(layout.clampedFrame(straddling, margin: 16).origin == CGPoint(x: 1456, y: 764),
                     "without a preferred display, the screen with the larger overlap takes it")
        suite.expect(layout.clampedFrame(straddling, margin: 16, preferredDisplayID: 99).origin == CGPoint(x: 1456, y: 764),
                     "an unknown display falls back to the overlap rule")
        let onPrimary = CGRect(x: 20, y: 20, width: 400, height: 300)
        suite.expect(layout.clampedFrame(onPrimary, margin: 16) == onPrimary, "a window already inside stays put")

        suite.section("C4", "current() reads the same screens as the NSScreen helpers")
        let live = ScreenSnapshot.current()
        suite.expect(live.baselineY == coordinateBaselineY(), "same flip baseline")
        suite.expect(live.screens.count == NSScreen.screens.count, "same number of screens")
        suite.finish()
    }
}

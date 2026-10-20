// 卷帘条窗口池（Overlay/ShadeStripPool.swift）：回收的窗口再取出来时，要和新建的一样接收鼠标事件。
// 缺陷回归（2026-10-20 代码审查发现）：展开时卷帘条被设成不接收鼠标事件再回收，取出时没有改回来。
// 再收起窗口、取到回收的没有红绿灯的卷帘条时，点击和拖动都没有反应，双击落到后面的窗口上。
import Cocoa

@main
struct StripPoolTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    let owner = AppDelegate()
    let first = owner.makeBaseOverlay(axPos: CGPoint(x: 100, y: 100), width: 300, height: 28)
    precondition(!first.ignoresMouseEvents, "a new strip takes the mouse")
    owner.dismissOverlay(first)
    precondition(first.ignoresMouseEvents, "a dismissed strip stops taking the mouse while it is in the pool")
    let reused = owner.makeBaseOverlay(axPos: CGPoint(x: 120, y: 140), width: 320, height: 28)
    precondition(reused === first, "the dismissed strip window is reused")
    precondition(!reused.ignoresMouseEvents, "a reused strip takes the mouse again")
    print("PASS StripPoolTests")
  }
}

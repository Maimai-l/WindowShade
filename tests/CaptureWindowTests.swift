// 覆盖 R5 F1：截图、读窗口时的辅助功能遍历和缓存（Window/、Capture/）。
// 缺陷回归（2026-10-20 代码审查发现），每一节对应一条缺陷，见 docs/testing.md 第 5 节。
// 不对任何真实窗口发辅助功能请求：要遍历的树、量高度的函数都由测试注入。
import Cocoa

@main
struct CaptureWindowTests {
  @MainActor
  static func main() {
    toolbarSearchStopsAtTheNodeBudget()
    print("PASS CaptureWindowTests")
  }

  /// 找工具栏要有节点预算：没有工具栏、每层 40 个子节点的窗口，不设预算要看 40 + 1600 + 64000 个节点，
  /// 双击标题栏时这些辅助功能请求都在主线程上。
  @MainActor
  static func toolbarSearchStopsAtTheNodeBudget() {
    // 节点 n 的子节点是 n*41+1 … n*41+40，树没有尽头，只靠深度和预算停下。
    func children(_ node: Int) -> [Int] { (1...40).map { node * 41 + $0 } }
    var examined = 0
    var expanded = 0
    var budget = axTraversalNodeBudget
    let none = firstDescendant(of: 0, maxDepth: 2, nodeBudget: &budget,
                               children: { expanded += 1; return children($0) },
                               matches: { _ in examined += 1; return false })
    precondition(none == nil, "a window without a toolbar has none")
    precondition(examined <= axTraversalNodeBudget,
                 "the search looks at no more than the node budget (looked at \(examined))")
    precondition(expanded <= axTraversalNodeBudget + 1, "only looked-at nodes are expanded (expanded \(expanded))")

    var direct = axTraversalNodeBudget
    precondition(firstDescendant(of: 0, maxDepth: 2, nodeBudget: &direct, children: children,
                                 matches: { $0 == 3 }) == 3, "a toolbar among the window's children is found")
    var nested = axTraversalNodeBudget
    precondition(firstDescendant(of: 0, maxDepth: 2, nodeBudget: &nested, children: children,
                                 matches: { $0 == 1 * 41 + 5 }) == 46, "a toolbar one level down is found within the budget")
  }
}

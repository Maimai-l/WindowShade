// 覆盖 R5 F1：截图、读窗口时的辅助功能遍历和缓存（Window/、Capture/）。
// 缺陷回归（2026-10-20 代码审查发现），每一节对应一条缺陷，见 docs/testing.md 第 5 节。
// 不对任何真实窗口发辅助功能请求：要遍历的树、量高度的函数都由测试注入。
import Cocoa

@main
struct CaptureWindowTests {
  @MainActor
  static func main() {
    toolbarSearchStopsAtTheNodeBudget()
    titlebarHitHeightIsMeasuredOnce()
    quickPreviewRejectsAnEmptyCapture()
    staleSnapshotSizeForcesARefresh()
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

  /// 双击判定量出的标题栏高度要存起来：以前只有收起时的外形解析会填缓存，
  /// 每次双击都在主线程上重新量一遍（几十次辅助功能请求）。
  @MainActor
  static func titlebarHitHeightIsMeasuredOnce() {
    let cache = ChromeProfileCache()
    // 只建元素，不发请求。
    let window = AXUIElementCreateApplication(4242)
    let other = AXUIElementCreateApplication(4243)
    let size = CGSize(width: 800, height: 600)
    var measured = 0
    func hit(_ element: AXUIElement, _ size: CGSize) -> CGFloat {
      titlebarHitHeight(of: element, id: 77, winTop: 100, winSize: size, pid: 4242, cache: cache,
                        measure: { _, _, _, _ in measured += 1; return 52 })
    }
    precondition(hit(window, size) == 52 && measured == 1, "the first double-click measures")
    precondition(hit(window, size) == 52 && measured == 1, "the next double-click on the same window uses the stored height")
    precondition(cache.cachedHitBarHeight(id: 77, win: window, size: size) == 52,
                 "the fold's profile resolution sees the stored height")
    _ = hit(window, CGSize(width: 900, height: 600))
    precondition(measured == 2, "a resized window is measured again")
    _ = hit(other, CGSize(width: 900, height: 600))
    precondition(measured == 3, "another element with the same window number is measured again")
  }

  /// 收起时用简化标题栏的那条路径先用旧接口截一张预览：窗口还没合成出画面时截到的是全透明的图，
  /// 以前照样当成截到了，就不再在隐藏原窗口之前用 ScreenCaptureKit 补截，这次收起的预览一直是空的。
  @MainActor
  static func quickPreviewRejectsAnEmptyCapture() {
    func image(width: Int, height: Int, opaque: Bool) -> CGImage {
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      if opaque {
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      }
      return context.makeImage()!
    }
    let limit = CGSize(width: 720, height: 480)
    let empty = image(width: 1440, height: 900, opaque: false)
    precondition(quickWindowPreviewCGImage(id: 9, maxPixelSize: limit, capture: { _ in empty }) == nil,
                 "a window that is not composited yet gives no preview")
    let drawn = image(width: 1440, height: 900, opaque: true)
    guard let preview = quickWindowPreviewCGImage(id: 9, maxPixelSize: limit, capture: { _ in drawn }) else {
      preconditionFailure("a drawn window gives a preview")
    }
    precondition(CGFloat(preview.width) <= limit.width && CGFloat(preview.height) <= limit.height,
                 "the preview is scaled down to the limit")
    precondition(quickWindowPreviewCGImage(id: 9, maxPixelSize: limit, capture: { _ in nil }) == nil,
                 "no capture gives no preview")
  }

  /// ScreenCaptureKit 的截图尺寸取自窗口列表快照（最多缓存 1.5 秒）。快照之后窗口被缩放过，
  /// 以前照样用旧的大小截图，卷帘条被拉变形、裁错高度。现在大小对不上就重新枚举（content(requiring:size:)）。
  @MainActor
  static func staleSnapshotSizeForcesARefresh() {
    let now = CGSize(width: 1200, height: 800)
    precondition(ShareableContentCache.sizeMatches(CGSize(width: 1200, height: 800), expected: now), "same size")
    precondition(ShareableContentCache.sizeMatches(CGSize(width: 1201.5, height: 798), expected: now),
                 "a point or two of rounding still matches")
    precondition(!ShareableContentCache.sizeMatches(CGSize(width: 900, height: 800), expected: now),
                 "a window resized after the snapshot does not match")
    precondition(!ShareableContentCache.sizeMatches(CGSize(width: 1200, height: 640), expected: now),
                 "a height change does not match")
    precondition(ShareableContentCache.sizeMatches(CGSize(width: 900, height: 640), expected: nil),
                 "callers without a size keep the old behaviour")
  }
}

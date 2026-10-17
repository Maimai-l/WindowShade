// 一个点是否落在卷帘条显示出来的部分上（两块屏幕各有自己的桌面时，只算显示卷帘条的那块屏幕上的部分），以及双击落在上面时鼠标钩子怎么处理。
// 依据见 prototype/Overlay/StripHitTest.swift 开头的注释。

@main
struct StripHitTestTests {
    static func main() {
        var suite = TestSuite("strip-hit-test")
        // 主屏幕 x 从 0 到 1680，第二块屏幕接在右边，从 1680 到 3600；卷帘条从 1380 到 2020，大部分在第二块屏幕上。
        let main = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let second = CGRect(x: 1680, y: 0, width: 1920, height: 1080)
        let strip = CGRect(x: 1380, y: 800, width: 640, height: 28)

        suite.section("S1", "两块屏幕各有自己的桌面：只算显示卷帘条的那块屏幕上的部分（A18-right）")
        suite.expect(!stripShows(at: CGPoint(x: 1530, y: 810), frame: strip, shownOn: second, separateSpaces: true),
                     "a point on the main screen, where the strip is not drawn, does not hit the strip")
        suite.expect(stripShows(at: CGPoint(x: 1840, y: 810), frame: strip, shownOn: second, separateSpaces: true),
                     "a point on the screen the strip is shown on hits it")

        suite.section("S2", "所有屏幕共用桌面时，卷帘条在两块屏幕上都显示：按外框算")
        suite.expect(stripShows(at: CGPoint(x: 1530, y: 810), frame: strip, shownOn: second, separateSpaces: false),
                     "without separate Spaces the whole frame counts")

        suite.section("S3", "点在外框以外；不知道卷帘条显示在哪块屏幕上时按外框算")
        suite.expect(!stripShows(at: CGPoint(x: 100, y: 100), frame: strip, shownOn: main, separateSpaces: true),
                     "a point outside the frame never hits the strip")
        suite.expect(stripShows(at: CGPoint(x: 1530, y: 810), frame: strip, shownOn: nil, separateSpaces: true),
                     "no screen known: fall back to the frame")

        suite.section("S4", "双击时：不在卷帘条上就照常判断；在卷帘条上，收起做完了就放行，没做完就由鼠标钩子直接调用卷帘条的双击处理（A32）")
        suite.expect(stripDoubleClickRoute(onShownStrip: false, foldFinished: false) == .notOnStrip,
                     "not on a shown strip: keep checking for a title bar double-click")
        suite.expect(stripDoubleClickRoute(onShownStrip: true, foldFinished: true) == .leaveToStrip,
                     "the fold is done: let the strip handle the double-click")
        suite.expect(stripDoubleClickRoute(onShownStrip: true, foldFinished: false) == .handleHere,
                     "the fold is still running: take the double-click and hand it to the strip directly")

        suite.finish()
    }
}

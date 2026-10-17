// 一个点是否落在卷帘条显示出来的部分上、是否落在收起还没做完的窗口的原标题栏上，以及双击时鼠标钩子怎么处理。
//
// 两块屏幕各有自己的桌面时（系统设置里“显示器具有单独的空间”打开），跨在两块屏幕上的窗口只显示在其中一块上，
// 另一块上的那一部分不显示，点击会落到下面别的窗口上。只看卷帘条的外框，会把落在这一部分的双击误当作双击卷帘条放行
// （依据：df2e916 本机运行的 A18-right，两次点击落到了活动监视器上）。

import CoreGraphics

/// frame 是卷帘条的外框，shownOn 是显示卷帘条的那块屏幕的外框（NSWindow.screen），separateSpaces 是
/// NSScreen.screensHaveSeparateSpaces。坐标都是 Cocoa 屏幕坐标。
func stripShows(at point: CGPoint, frame: CGRect, shownOn screen: CGRect?, separateSpaces: Bool) -> Bool {
    guard frame.contains(point) else { return false }
    guard separateSpaces, let screen else { return true }
    return screen.contains(point)
}

/// 双击时鼠标钩子怎么处理：看是否落在显示出来的卷帘条上、收起是否做完。
enum StripDoubleClickRoute: Equatable {
    /// 不在显示出来的卷帘条上：按标题栏双击继续判断。
    case notOnStrip
    /// 收起已经做完：放行，由卷帘条自己处理。
    case leaveToStrip
    /// 收起还没做完：鼠标钩子不放行这次双击，直接调用卷帘条的双击处理（收起做完后再展开）。
    /// 这段时间里别的窗口可能还盖在卷帘条上，放行的点击会落到它上面，例如快速查看窗口关闭时的过渡窗口
    /// （依据：54f1aa1 上 CI 场景 A32 的录像）。
    case handleHere
}

func stripDoubleClickRoute(onShownStrip: Bool, foldFinished: Bool) -> StripDoubleClickRoute {
    guard onShownStrip else { return .notOnStrip }
    return foldFinished ? .leaveToStrip : .handleHere
}

/// 返回原标题栏包含 point 的那扇窗口，只看 inFlight 里收起还没做完的窗口。bands 是各窗口原标题栏所在的区域，
/// 屏幕坐标，左上角为原点。收起刚开始时卷帘条可能还没建好，窗口也还没登记为已收起，按卷帘条判断会漏掉；
/// 这时在原处再双击，是要展开它，不能算作后面窗口标题栏上的双击（依据：9494581 上 CI 场景 A36，第二次双击收起了后面的访达）。
func foldingWindow(at point: CGPoint, bands: [UInt32: CGRect], inFlight: Set<UInt32>) -> UInt32? {
    bands.first { id, band in inFlight.contains(id) && band.contains(point) }?.key
}

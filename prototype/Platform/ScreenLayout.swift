// 屏幕几何的快照（辅助功能坐标：主屏左上为原点，y 向下）。在主线程用 current()（Window/Coordinates.swift）
// 取一次，之后交给后台的平台层模块使用，后台不再读 NSScreen。只依赖 CoreGraphics，测试直接编译。

import CoreGraphics
import Foundation

struct ScreenLayout: Equatable, Sendable {
    /// 各屏幕的范围，第一项是主屏。
    let screens: [CGRect]

    /// 窗口露出一块看得见的部分才算可见；停在屏幕角上只剩一像素不算（见 Core/CornerParking.swift）。
    func isVisible(pos: CGPoint, size: CGSize) -> Bool {
        rectIsVisible(CGRect(origin: pos, size: size), onScreens: screens)
    }

    /// 窗口所在的屏幕：重叠面积最大的那块；都不重叠时取中心最近的一块。
    func screen(containing pos: CGPoint, size: CGSize) -> CGRect? {
        let rect = CGRect(origin: pos, size: size)
        func area(_ screen: CGRect) -> CGFloat {
            let hit = screen.intersection(rect)
            return hit.isNull ? 0 : hit.width * hit.height
        }
        if let best = screens.max(by: { area($0) < area($1) }), area(best) > 0 { return best }
        return screens.min { a, b in
            hypot(rect.midX - a.midX, rect.midY - a.midY) < hypot(rect.midX - b.midX, rect.midY - b.midY)
        }
    }
}

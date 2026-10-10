// 系统设置里打开了“减少动态效果”时：弹簧不回弹，也不接甩动的速度；截图不移动，改为原处淡出、目标处淡入。
// 依据是 HIG 的 Motion：动效要能关掉，可以收紧弹簧、减少回弹，移动位置时可以先淡出、到了再淡入。

import Cocoa

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 设计系统 §4.6 的弹簧令牌。dampingRatio = 1 − bounce。
    struct Spring: Equatable {
        var response: Double
        var dampingRatio: Double
        var bounce: CGFloat

        /// 尺寸变化（不回弹）。
        static let settle = Spring(response: 0.38, dampingRatio: 1, bounce: 0)
    }
}

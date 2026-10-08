// 系统设置里打开了“减少动态效果”：弹簧不回弹、不接甩出去的速度，截图不飞、原处淡出目标处淡入
// （HIG：Motion，“让动效可以不要”：收紧弹簧、减少回弹；挪位置可以先淡出、到了再淡入）。

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

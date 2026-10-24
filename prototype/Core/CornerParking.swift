// 角落停放：系统不让别人的窗口整个离开屏幕，最小化又一定有缩进 Dock 的动画。
// 退而求其次，把窗口挪到它所在屏幕的下角外面，只在角上留一像素（AeroSpace 藏工作区窗口也是这个办法）。
// 这里只做几何计算。可见与否只要求传进来的矩形在同一个坐标系里；停放点按辅助功能接口的
// 全局坐标给：左上角为原点，y 向下。

import CoreGraphics

/// 窗口在某块屏幕上露出的部分至少有这么宽、这么高才算看得见；停在角上的那一像素不算。
let minimumVisibleExtent: CGFloat = 8

func rectIsVisible(_ rect: CGRect, onScreens screens: [CGRect]) -> Bool {
    let needWidth = min(minimumVisibleExtent, rect.width)
    let needHeight = min(minimumVisibleExtent, rect.height)
    return screens.contains { screen in
        let overlap = screen.intersection(rect)
        return !overlap.isNull && overlap.width >= needWidth && overlap.height >= needHeight
    }
}

/// 依次试的停放点：先右下角，再左下角。挪过去会压到别的屏幕的点不要，否则窗口会出现在那块屏幕上。
func cornerParkingSpots(screen: CGRect, otherScreens: [CGRect], windowSize: CGSize) -> [CGPoint] {
    let candidates = [
        CGPoint(x: screen.maxX - 1, y: screen.maxY - 1),
        CGPoint(x: screen.minX - windowSize.width + 1, y: screen.maxY - 1),
    ]
    return candidates.filter { spot in
        let parked = CGRect(origin: spot, size: windowSize)
        return !otherScreens.contains { $0.intersects(parked) }
    }
}

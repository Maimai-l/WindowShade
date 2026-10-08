// WindowControl 的模拟实现：一个窗口，按配置决定各种操作是否生效，记下每一次调用。
// 只编进测试二进制。

import CoreGraphics
import Foundation

final class FakeWindowControl: WindowControl, @unchecked Sendable {
    /// 系统允许窗口停到的范围：位置会被夹回这个范围（模拟 macOS 不让窗口完全离开屏幕）。
    var allowedOrigins: CGRect
    var windowPosition: CGPoint
    let windowSize: CGSize
    var visibleWindows = 1
    var totalWindows = 1
    var appHideWorks = true
    var closeButtonWorks = true
    var skyLightMoveAvailable = true
    var skyLightAlphaAvailable = true
    /// SIP 开着时 SkyLight 调用返回成功，但窗口不变。
    var skyLightTakesEffect = false
    private var alpha: Float = 1
    private(set) var calls: [String] = []
    private(set) var minimized = false

    init(position: CGPoint, size: CGSize, allowedOrigins: CGRect) {
        self.windowPosition = position
        self.windowSize = size
        self.allowedOrigins = allowedOrigins
    }

    func position(_ window: WindowHandle) -> CGPoint? { windowPosition }

    func setPosition(_ window: WindowHandle, _ point: CGPoint) {
        calls.append("setPosition(\(Int(point.x)),\(Int(point.y)))")
        windowPosition = CGPoint(x: min(max(point.x, allowedOrigins.minX), allowedOrigins.maxX),
                                 y: min(max(point.y, allowedOrigins.minY), allowedOrigins.maxY))
    }

    func setMinimized(_ window: WindowHandle, _ minimized: Bool) {
        calls.append("minimize")
        self.minimized = minimized
    }

    func pressCloseButton(_ window: WindowHandle) -> Bool {
        calls.append("close")
        return closeButtonWorks
    }

    func hideApp(pid: pid_t) -> String? {
        calls.append("hideApp")
        return appHideWorks ? "AX" : nil
    }

    func windowCounts(pid: pid_t, layout: ScreenLayout) -> (visible: Int, total: Int) { (visibleWindows, totalWindows) }

    func skyLightMove(id: CGWindowID, to point: CGPoint) -> Bool {
        calls.append("skyLightMove")
        if skyLightTakesEffect { windowPosition = point }
        return true
    }

    func skyLightAlpha(id: CGWindowID) -> Float? { alpha }

    func skyLightSetAlpha(id: CGWindowID, _ value: Float) -> Bool {
        calls.append("skyLightSetAlpha(\(value))")
        if skyLightTakesEffect || value >= 1 { alpha = value }
        return true
    }

    func windowServerBounds(id: CGWindowID) -> CGRect? { CGRect(origin: windowPosition, size: windowSize) }

    func log(_ message: String) {}

    func callsMatching(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
}

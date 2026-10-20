// 覆盖 R5：收起截图的短时缓存（Capture/WindowSnapshotCache.swift）。
// 缺陷回归（2026-10-20 代码审查发现）：过期的图只在下一次存入、或再读同一个键时才清掉。
// 一两次走 ScreenCaptureKit 的收起之后，完整 Retina 大图（5K 窗口约 65 MB）一直占着内存。
// 时钟和到期清理都由测试注入，不等待、不读系统时间。
import CoreGraphics
import Foundation

private final class FakeTime: @unchecked Sendable {
    var now: CFAbsoluteTime = 1_000
    var scheduled: [(delay: TimeInterval, work: @Sendable () -> Void)] = []
}

private func image(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@main
struct WindowSnapshotCacheTests {
    static func main() {
        var suite = TestSuite("WindowSnapshotCacheTests")
        let time = FakeTime()
        let cache = WindowSnapshotCache(ttl: 0.5, currentTime: { time.now },
                                        schedule: { delay, work in time.scheduled.append((delay, work)) })
        let first = WindowSnapshotKey(windowID: 7, variant: .nativeChrome, maxPixelSize: nil)
        let second = WindowSnapshotKey(windowID: 8, variant: .nativeChrome, maxPixelSize: nil)

        suite.section("S1", "an expired capture is released without another read or store")
        cache.store(image: image(width: 400, height: 300), key: first)
        suite.expect(cache.totalCostInBytes > 0, "the stored capture counts against the budget")
        suite.expect(cache.cachedImage(key: first) != nil, "a fresh capture is reused")
        suite.expect(time.scheduled.count == 1, "storing schedules one cleanup")
        suite.expect((time.scheduled.first?.delay ?? 0) >= 0.5, "the cleanup runs after the capture has expired")
        time.now += 0.6
        time.scheduled.forEach { $0.work() }
        suite.expect(cache.totalCostInBytes == 0, "the cleanup releases the expired capture")

        suite.section("S2", "a cleanup leaves a later capture alone")
        time.scheduled.removeAll()
        cache.store(image: image(width: 400, height: 300), key: first)
        time.now += 0.3
        cache.store(image: image(width: 200, height: 100), key: second)
        time.now += 0.3
        time.scheduled.first?.work()
        suite.expect(cache.cachedImage(key: first) == nil, "the first capture has expired")
        suite.expect(cache.cachedImage(key: second) != nil, "the later capture is still there")
        suite.finish()
    }
}

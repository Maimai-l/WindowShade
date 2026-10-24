// 角落停放的几何：选哪个角、露出多少才算看得见。
import CoreGraphics
import Foundation

@main
struct CornerParkingTests {
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    static func main() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 700, height: 460)

        // 一块屏：先右下角，再左下角。
        let spots = cornerParkingSpots(screen: main, otherScreens: [], windowSize: size)
        expect(spots == [CGPoint(x: 1439, y: 899), CGPoint(x: -699, y: 899)],
               "one screen: bottom right first, then bottom left (\(spots))")

        // 停好之后只剩一像素，不算看得见。
        for spot in spots {
            expect(!rectIsVisible(CGRect(origin: spot, size: size), onScreens: [main]),
                   "a window parked at \(spot) is not visible")
        }

        // 露出一截标题栏还算看得见。
        expect(rectIsVisible(CGRect(x: 1400, y: 860, width: 700, height: 460), onScreens: [main]),
               "40 points showing still counts as visible")
        expect(rectIsVisible(CGRect(x: 100, y: 100, width: 700, height: 460), onScreens: [main]),
               "a window on screen is visible")

        // 右边接着一块屏：右下角会压到它，只剩左下角。
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        expect(cornerParkingSpots(screen: main, otherScreens: [right], windowSize: size)
               == [CGPoint(x: -699, y: 899)],
               "a screen on the right rules out the bottom right corner")

        // 下面接着一块屏：两个下角都压到它，不停放，交给最小化。
        let below = CGRect(x: -200, y: 900, width: 1920, height: 1080)
        expect(cornerParkingSpots(screen: main, otherScreens: [below], windowSize: size).isEmpty,
               "a screen below rules out both corners")

        // 很小的窗口：露出的部分只要和窗口一样大就算看得见。
        expect(rectIsVisible(CGRect(x: 10, y: 10, width: 4, height: 4), onScreens: [main]),
               "a tiny window fully on screen is visible")

        if failures == 0 { print("PASS: corner parking picks a free bottom corner and leaves nothing visible") }
        else { print("FAILED \(failures)"); exit(1) }
    }
}

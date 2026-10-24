// 顶部区域下沿的像素判定（Core/ChromeBand.swift）：合成的窗口顶部，按 2 倍缩放。
import CoreGraphics
import Foundation

@main
struct ChromeBandTests {
    typealias Color = (UInt8, UInt8, UInt8, UInt8)
    static let red: Color = (230, 50, 50, 255)
    static let white: Color = (255, 255, 255, 255)
    static let grey: Color = (200, 200, 200, 255)
    static let toolbar: Color = (236, 236, 236, 255)

    /// 宽 400 点、高 140 点的窗口顶部，颜色按点坐标给出。
    static func image(_ color: (CGFloat, CGFloat) -> Color) -> TopPixels {
        let scale: CGFloat = 2, width = 800, height = 280
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = color(CGFloat(x) / scale, CGFloat(y) / scale)
            let i = (y * width + x) * 4
            data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = c.3
        } }
        return TopPixels(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    static func bottom(_ color: @escaping (CGFloat, CGFloat) -> Color, floor: CGFloat = 28,
                       controls: [ClosedRange<CGFloat>] = []) -> CGFloat? {
        ChromeBand.bottom(of: image(color), scale: 2, floor: floor, controls: controls)
    }

    /// 自己画的 60 点高红色顶栏，中间有一个白色搜索框（从顶边往下 15～45 点），下面是白色内容区。
    static func customTopBar(_ x: CGFloat, _ y: CGFloat) -> Color {
        guard y < 60 else { return white }
        return (15..<45).contains(y) && (150..<270).contains(x) ? white : red
    }

    static func main() {
        var t = TestSuite("chrome-band")

        t.section("S1", "没有原生工具栏的窗口：卷帘条到顶部区域的下沿为止")
        // 缺陷回归（2026-10-19 用户实测）：修复之前，网易云音乐的卷帘条只到红绿灯下面，它自己画的顶栏下半截不在卷帘条里。
        t.expect(bottom(customTopBar) == 60, "自己画的 60 点顶栏：下沿在 60 点，不只到红绿灯下面")
        t.expect(bottom { x, y in (60..<60.5).contains(y) ? grey : customTopBar(x, y) } == 60.5,
                 "顶栏和内容区之间有一条分隔线：线留在卷帘条里")
        t.expect(bottom { x, y in
            if (28..<28.5).contains(y) { return grey }
            if y < 52 { return toolbar }
            return x > 150 ? white : (240, 240, 250, 255)
        } == 52, "标题栏和下面同色的一排之间隔一条细线：细线不算下沿，下沿在 52 点")
        t.expect(bottom(customTopBar, controls: [50...70]) == 70, "下沿落在辅助功能读到的控件中间：挪到控件下面")
        t.expect(bottom { _, y in y < 20 ? red : white } == 28, "顶部区域的下沿高于红绿灯的下沿：下沿取红绿灯的下沿（floor）")
        t.expect(bottom({ x, y in
            if y < 40 { return (60, 60, 60, 255) }
            if y < 80 { return (46..<74).contains(y) && (120..<380).contains(x) ? white : (90, 90, 90, 255) }
            return (250, 250, 250, 255)
        }, controls: [46...74]) == 80, "浏览器的标签条下面紧接着另一种底色的地址栏一排：两层都留在卷帘条里")
        t.expect(bottom(customTopBar, controls: [75...95]) == 60, "下沿下面隔了 15 点的控件是内容区的：不算顶部区域")

        t.section("S1", "红绿灯在标准位置的窗口：找到下沿就裁到下沿，推算的高度和下沿之间只有内容元素时裁到推算的高度")
        // 缺陷回归（2026-10-20 用户看 CI 截图发现）：修复之前，Texpile 的顶栏 31 点，卷帘条按红绿灯推算裁到 34 点，下面多出一条白边。
        t.expect(ChromeBand.standardWindowBar(standard: 34, found: 31, maxHeight: 96) == 31, "下沿比推算的浅：裁到下沿，不带白边")
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: 64, maxHeight: 96) == 64, "自己画的 64 点顶栏：裁到下沿")
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: nil, maxHeight: 96) == 28, "找不到下沿：裁到推算的高度")
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: 120, maxHeight: 96) == 28, "下沿深过 96 点：裁到推算的高度")
        // 缺陷回归（用户的 macOS 14.5 本机运行，122d6fa，场景 A33-Calculator）：计算器的显示屏和标题栏同一种底色，
        // 修复之前卷帘条裁到 81 点，把显示屏也裁了进去。
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: 81, maxHeight: 96, content: [36...76]) == 28,
                 "推算的高度和下沿之间有内容元素（计算器的显示屏）：裁到推算的高度")
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: 81, maxHeight: 96, content: [22...78, 5...21],
                                              controls: [80...129, 128...177]) == 28,
                 "macOS 14.5 上计算器读到的值：显示屏 22 至 78 点，上沿伸进标题栏；按键从 80 点起，和下沿只差 1 点，不算在那一段里")
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: 64, maxHeight: 96, content: [6...20, 64...400]) == 64,
                 "标题栏里的标题、下沿下面的正文不算：自己画的顶栏照样裁到下沿")
        t.expect(ChromeBand.standardWindowBar(standard: 28, found: 60, maxHeight: 96, content: [36...50], controls: [32...56]) == 60,
                 "那一段里还有按钮、搜索框：是自己画的顶栏，裁到下沿")
        t.expect(ChromeBand.standardWindowBar(standard: 34, found: 31, maxHeight: 96, content: [32...300]) == 31,
                 "下沿比推算的浅：不看内容元素")

        t.section("S1", "分不出下沿时返回 nil（调用方改用图标和标题）")
        t.expect(bottom { _, _ in toolbar } == nil, "顶部和内容区同一种底色、没有分隔线")
        t.expect(bottom { x, y in (UInt8(Int(x) % 256), UInt8(Int(y * 3) % 256), UInt8(Int(x + y) % 256), 255) } == nil,
                 "顶部是渐变或透出后面内容的半透明材质")
        // 用户 2026-10-24 实测（macOS 26）：图标和标题一律是灰色的系统材质，和下面窗口的标题栏对不上（终端的标题栏是白的）。
        t.section("S5", "图标和标题的卷帘条照原窗口的标题栏：底色、高度")
        let whiteBar = image { x, y in y < 32 ? (x < 70 ? red : white) : grey }
        let barColor = ChromeBand.titleBarColor(of: whiteBar, scale: 2, height: 32)
        t.expect(barColor.map { $0.r == 255 && $0.g == 255 && $0.b == 255 } ?? false, "白色标题栏：底色取白色，不受左边红绿灯影响")
        let darkBar = image { _, y in y < 28 ? (40, 40, 44, 255) : white }
        t.expect(ChromeBand.titleBarColor(of: darkBar, scale: 2, height: 28).map { $0.r == 40 && $0.g == 40 && $0.b == 44 } ?? false, "深色标题栏")
        let noisy = image { x, y in (UInt8(Int(x * 7) % 256), UInt8(Int(y * 13) % 256), UInt8(Int(x + y) % 256), 255) }
        t.expect(ChromeBand.titleBarColor(of: noisy, scale: 2, height: 32) == nil, "标题栏是图片或渐变：不取颜色，用系统材质")
        t.expect(ChromeBand.proxyBarHeight(standard: 32, fallback: 34, windowHeight: 600) == 32, "和原窗口的标题栏一样高")
        t.expect(ChromeBand.proxyBarHeight(standard: nil, fallback: 34, windowHeight: 600) == 34, "读不到时用默认高度")
        t.expect(ChromeBand.proxyBarHeight(standard: 80, fallback: 34, windowHeight: 600) == 52, "最高 52 点")
        t.expect(ChromeBand.proxyBarHeight(standard: 32, fallback: 34, windowHeight: 20) == 20, "不超过窗口本身")
        t.finish()
    }
}

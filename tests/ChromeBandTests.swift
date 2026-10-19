// 顶部区域下沿的像素判定（Core/ChromeBand.swift）：合成的窗口顶部，2 倍像素。
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
    static func image(_ color: (CGFloat, CGFloat) -> Color) -> RGBAPixels {
        let scale: CGFloat = 2, width = 800, height = 280
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = color(CGFloat(x) / scale, CGFloat(y) / scale)
            let i = (y * width + x) * 4
            data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = c.3
        } }
        return RGBAPixels(data: data, width: width, height: height, bytesPerRow: width * 4)
    }

    static func bottom(_ color: @escaping (CGFloat, CGFloat) -> Color, floor: CGFloat = 28,
                       controls: [ClosedRange<CGFloat>] = []) -> CGFloat? {
        ChromeBand.bottom(of: image(color), scale: 2, floor: floor, controls: controls)
    }

    /// 自绘的 60 点高红色顶栏，中间有一个白色搜索框（15–45 点），下面是白色内容区。
    static func customTopBar(_ x: CGFloat, _ y: CGFloat) -> Color {
        guard y < 60 else { return white }
        return (15..<45).contains(y) && (150..<270).contains(x) ? white : red
    }

    static func main() {
        var t = TestSuite("chrome-band")

        t.section("S1", "没有原生工具栏的窗口：卷帘条到顶部区域的下沿为止")
        // 缺陷回归（2026-10-19 用户实测）：修复之前，网易云音乐的卷帘条只到红绿灯下面，切过了它自绘的顶栏。
        t.expect(bottom(customTopBar) == 60, "自绘的 60 点顶栏：下沿在 60 点，不停在红绿灯下面")
        t.expect(bottom { x, y in (60..<60.5).contains(y) ? grey : customTopBar(x, y) } == 60.5,
                 "顶栏和内容区之间有一条分隔线：线留在卷帘条里")
        t.expect(bottom { x, y in
            if (28..<28.5).contains(y) { return grey }
            if y < 52 { return toolbar }
            return x > 150 ? white : (240, 240, 250, 255)
        } == 52, "标题栏下面接着同色的一排按钮，中间隔一条细线：细线不算下沿，下沿在 52 点")
        t.expect(bottom(customTopBar, controls: [50...70]) == 70, "下沿落在辅助功能读到的控件中间：挪到控件下面")
        t.expect(bottom { _, y in y < 20 ? red : white } == 28, "顶部区域比红绿灯还浅：下沿不浅于红绿灯（floor）")
        t.expect(bottom({ x, y in
            if y < 40 { return (60, 60, 60, 255) }
            if y < 80 { return (46..<74).contains(y) && (120..<380).contains(x) ? white : (90, 90, 90, 255) }
            return (250, 250, 250, 255)
        }, controls: [46...74]) == 80, "浏览器：标签条下面紧接着地址栏一排（另一种底色）：两层都留在卷帘条里")
        t.expect(bottom(customTopBar, controls: [75...95]) == 60, "下沿下面隔了 15 点的控件是内容区的：不算顶部区域")

        t.section("S1", "分不出下沿时返回 nil（调用方改用简化标题栏）")
        t.expect(bottom { _, _ in toolbar } == nil, "顶部和内容区同一种底色、没有分隔线")
        t.expect(bottom { x, y in (UInt8(Int(x) % 256), UInt8(Int(y * 3) % 256), UInt8(Int(x + y) % 256), 255) } == nil,
                 "顶部是渐变或透出后面内容的半透明材质")
        t.finish()
    }
}

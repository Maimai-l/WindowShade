// 在收起时的截图里找窗口顶部区域的下沿：顶部区域（标题栏连同自绘的顶栏）的底色一直往下铺，铺不满一行的地方就是内容区开始的地方。
// 只用于没有原生工具栏的窗口：网页、跨平台框架画的顶栏，辅助功能读不到它有多高（docs/design.md 的 S1）。
// 纯计算，不调用系统接口，可在任意线程上做。

import CoreGraphics

/// 截图的一块像素，RGBA，每像素 4 字节。
struct RGBAPixels {
    let data: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int

    func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = y * bytesPerRow + x * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}

enum ChromeBand {
    /// 底色相差在这个范围内（每个颜色分量）算同一种颜色。
    static let colorTolerance = 14
    /// 一行里底色占这个比例以上，这一行仍属顶部区域（上面画着按钮、搜索框、文字也不要紧）。
    static let chromeRowShare = 0.4
    /// 顶部区域本身要有一种占主导的底色；渐变、透出后面内容的半透明材质分不出下沿，不猜。
    static let bandUniformShare = 0.5
    /// 底色中断超过这么高（点）才算到了内容区；更短的是顶部区域里的分隔线。
    static let maxInnerLine: CGFloat = 3
    /// 下沿下面这么近（点）以内就有顶部控件时，算顶部区域的下一层。
    static let nextTierGap: CGFloat = 8

    /// 顶部区域的下沿（点，从窗口顶边算）。找不到时返回 nil，调用方改用简化标题栏。
    /// floor：不能比它更浅（红绿灯的下沿）。ceiling：最多找到这么深。
    /// controls：辅助功能读到的顶部控件的上下沿（点）；下沿不能切过任何一个控件。
    static func bottom(of pixels: RGBAPixels, scale: CGFloat, floor: CGFloat, ceiling: CGFloat = 140,
                       controls: [ClosedRange<CGFloat>] = []) -> CGFloat? {
        guard pixels.width > 40, pixels.height > 8, scale > 0 else { return nil }
        let px = { (points: CGFloat) in Int((points * scale).rounded()) }
        // 左边留出红绿灯，右边留出圆角。
        let left = min(px(80), pixels.width / 4)
        let right = pixels.width - min(px(12), pixels.width / 8)
        let step = max(1, (right - left) / 240)
        let xs = Array(stride(from: left, to: right, by: step))
        guard xs.count >= 8 else { return nil }
        let floorRow = max(0, px(floor))
        let lastRow = min(pixels.height, px(ceiling))
        guard floorRow < lastRow else { return nil }

        // 这一行里有多少取样点是这种颜色。
        func shareOf(_ color: (Int, Int, Int), row y: Int) -> Double {
            var near = 0
            for x in xs {
                let p = pixels.pixel(x: x, y: y)
                if p.a > 200, same((p.r, p.g, p.b), color) { near += 1 }
            }
            return Double(near) / Double(xs.count)
        }
        // 一层顶部区域的底色：这几行取样的中位色；这几行本身没有一种占主导的底色时为 nil。
        func bandColor(_ rows: [Int]) -> (Int, Int, Int)? {
            let rows = rows.filter { $0 < pixels.height }
            var reds: [Int] = [], greens: [Int] = [], blues: [Int] = []
            for y in rows { for x in xs {
                let p = pixels.pixel(x: x, y: y)
                guard p.a > 200 else { continue }
                reds.append(p.r); greens.append(p.g); blues.append(p.b)
            } }
            guard !rows.isEmpty, reds.count >= xs.count else { return nil }
            let color = (median(reds), median(greens), median(blues))
            let covered = rows.map { shareOf(color, row: $0) }.reduce(0, +) / Double(rows.count)
            return covered >= bandUniformShare ? color : nil
        }
        // 第一层的底色取顶边往下 2 点到 floor（至少 6 点）之间。
        guard var band = bandColor(Array(px(2)..<max(px(6), floorRow))) else { return nil }
        func share(_ y: Int) -> Double { shareOf(band, row: y) }

        let innerLine = max(1, px(maxInnerLine))
        var y = floorRow
        while y < lastRow {
            guard share(y) < chromeRowShare else { y += 1; continue }
            // 底色在这里断了：断开的一段不超过 maxInnerLine、下面又接上底色的，是顶部区域里的分隔线。
            var end = y
            while end < lastRow, share(end) < chromeRowShare { end += 1 }
            if end < lastRow, end - y <= innerLine { y = end; continue }
            var candidate = CGFloat(y) / scale
            // 断开处是一条整行同色的细线（顶部区域和内容区之间的分隔线），下面的内容是别的颜色时，把线留在卷帘条里。
            if let lineColor = uniformColor(pixels, y: y, xs: xs) {
                var line = y + 1
                while line < min(end, y + px(2)), uniformColor(pixels, y: line, xs: xs).map({ same($0, lineColor) }) == true {
                    line += 1
                }
                let below = line < pixels.height ? uniformColor(pixels, y: line, xs: xs) : nil
                if line < end, below.map({ !same($0, lineColor) }) ?? true { candidate = CGFloat(line) / scale }
            }
            // 不切过顶部的控件：下沿落在某个控件中间时，挪到那个控件下面接着找。
            if let control = controls.first(where: { $0.lowerBound < candidate - 1 && candidate < $0.upperBound - 1 }) {
                y = max(y + 1, px(control.upperBound))
                continue
            }
            // 下沿下面紧接着（nextTierGap 以内）又有控件：那是顶部区域的下一层（例如浏览器标签条下面的地址栏一排），
            // 换成这一层的底色接着找。
            if let control = controls.filter({ $0.lowerBound >= candidate - 1 && $0.lowerBound <= candidate + nextTierGap })
                .min(by: { $0.lowerBound < $1.lowerBound }),
               control.lowerBound - candidate >= 1,
               let next = bandColor(Array(px(candidate) + 1..<px(control.lowerBound))) {
                band = next
                y = max(y + 1, px(control.upperBound))
                continue
            }
            return candidate
        }
        return nil
    }

    private static func median(_ values: [Int]) -> Int {
        values.sorted()[values.count / 2]
    }

    private static func same(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) <= colorTolerance && abs(a.1 - b.1) <= colorTolerance && abs(a.2 - b.2) <= colorTolerance
    }

    /// 这一行 85% 以上的取样点是同一种颜色时，返回这种颜色。
    private static func uniformColor(_ pixels: RGBAPixels, y: Int, xs: [Int]) -> (Int, Int, Int)? {
        let samples = xs.map { pixels.pixel(x: $0, y: y) }
        let color = (median(samples.map(\.r)), median(samples.map(\.g)), median(samples.map(\.b)))
        let near = samples.filter { same(($0.r, $0.g, $0.b), color) }.count
        return Double(near) >= Double(samples.count) * 0.85 ? color : nil
    }
}

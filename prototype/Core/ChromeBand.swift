// 在收起时的截图里找窗口顶部区域（标题栏连同应用程序自己画的顶栏）的下沿：从上往下逐行看，
// 底色在一行里占不到四成、连着超过 3 点的地方，就是内容区的开始。
// 用于两种窗口：没有原生工具栏、辅助功能读不出顶部多高的窗口（网页、跨平台框架自己画的顶栏）；红绿灯在标准位置的窗口。见 docs/design.md 的 S1。
// 纯计算，不调用系统接口，可在任意线程上做。

import CoreGraphics

/// 截图的一块像素，RGBA，每像素 4 字节。
struct TopPixels {
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
    /// 两种颜色的每个分量相差都不超过这个值，算同一种颜色。
    static let colorTolerance = 14
    /// 一行里底色占这个比例以上，这一行仍属顶部区域（上面画着按钮、搜索框、文字也算）。
    static let chromeRowShare = 0.4
    /// 顶部区域本身要有一种占主导的底色；渐变、透出后面内容的半透明材质分不出下沿，返回 nil。
    static let bandUniformShare = 0.5
    /// 底色中断超过这么高（点）才算到了内容区；不超过这么高、下面又接上底色的，是顶部区域里的分隔线。
    static let maxInnerLine: CGFloat = 3
    /// 下沿下面这么近（点）以内就有顶部控件时，算顶部区域的下一层。
    static let nextTierGap: CGFloat = 8

    /// 顶部区域的下沿（点，从窗口顶边算）。找不到时返回 nil，调用方改用简化标题栏。
    /// floor：下沿最高到这里（调用方传红绿灯按钮的下沿往下 2 点，读不到按钮时传按红绿灯推算的高度，至少 12 点）。ceiling：最深找到这里。
    /// controls：辅助功能读到的顶部控件的上下沿（点）；下沿不落在任何一个控件中间。
    static func bottom(of pixels: TopPixels, scale: CGFloat, floor: CGFloat, ceiling: CGFloat = 140,
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
        // 一层顶部区域的底色：这几行取样点的中位色。不透明的取样点太少，或中位色平均占不到每行的一半（bandUniformShare）时为 nil。
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
        // 第一层的底色取顶边往下 2 点到 floor 之间的几行；floor 不到 6 点时取到 6 点。
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
            // 断开处先是一条最多 2 点高、85% 以上取样点同色的细线，下面又是另一种颜色时，
            // 这条线是顶部区域和内容区之间的分隔线，留在卷帘条里。
            if let lineColor = uniformColor(pixels, y: y, xs: xs) {
                var line = y + 1
                while line < min(end, y + px(2)), uniformColor(pixels, y: line, xs: xs).map({ same($0, lineColor) }) == true {
                    line += 1
                }
                let below = line < pixels.height ? uniformColor(pixels, y: line, xs: xs) : nil
                if line < end, below.map({ !same($0, lineColor) }) ?? true { candidate = CGFloat(line) / scale }
            }
            // 下沿不落在顶部控件中间：落在某个控件中间时，从那个控件的下沿接着往下找。
            if let control = controls.first(where: { $0.lowerBound < candidate - 1 && candidate < $0.upperBound - 1 }) {
                y = max(y + 1, px(control.upperBound))
                continue
            }
            // 下沿下面 1 点到 nextTierGap 之间又有控件，中间那几行有一种底色时，那是顶部区域的下一层
            // （例如浏览器标签条下面的地址栏一排），换成这一层的底色接着找。
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

    /// 红绿灯在标准位置的窗口裁多高。standard 是按红绿灯推算的高度，自己画的顶栏不一定这么高。
    /// found 不深过 maxHeight 时裁到 found，比 standard 浅也一样（例外见下）；found 为 nil 或深过 maxHeight 时裁到 standard。
    /// 例如 Texpile 的顶栏 31 点，推算是 34 点，裁到 34 点会带上 3 点白色内容区。
    /// content、controls 是辅助功能读到的内容元素和顶部控件的上下沿（点，从窗口顶边算）。found 比 standard 深、
    /// 上沿落在两者之间的只有内容元素、没有控件时，那一段虽然和标题栏同一种底色，却是窗口内容，裁到 standard。
    /// 例如计算器的显示屏和标题栏同一种底色，截图里找到的下沿在 81 点，会把显示屏裁进卷帘条（场景 A33-Calculator）。
    /// 那一段里有按钮、搜索框这类控件时，是应用程序自己画的顶栏，裁到 found。
    static func standardWindowBar(standard: CGFloat, found: CGFloat?, maxHeight: CGFloat,
                                  content: [ClosedRange<CGFloat>] = [],
                                  controls: [ClosedRange<CGFloat>] = []) -> CGFloat {
        guard let found, found <= maxHeight else { return standard }
        let between = { (range: ClosedRange<CGFloat>) in range.lowerBound >= standard - 1 && range.lowerBound < found }
        if found > standard + 1, content.contains(where: between), !controls.contains(where: between) {
            return standard
        }
        return found
    }

    private static func median(_ values: [Int]) -> Int {
        values.sorted()[values.count / 2]
    }

    private static func same(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) <= colorTolerance && abs(a.1 - b.1) <= colorTolerance && abs(a.2 - b.2) <= colorTolerance
    }

    /// 这一行 85% 以上的取样点是同一种颜色时，返回这种颜色。
    private static func uniformColor(_ pixels: TopPixels, y: Int, xs: [Int]) -> (Int, Int, Int)? {
        let samples = xs.map { pixels.pixel(x: $0, y: y) }
        let color = (median(samples.map { $0.r }), median(samples.map { $0.g }), median(samples.map { $0.b }))
        let near = samples.filter { same(($0.r, $0.g, $0.b), color) }.count
        return Double(near) >= Double(samples.count) * 0.85 ? color : nil
    }
}

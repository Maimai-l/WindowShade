// 第一次打开设置窗口时要做的一次性准备，启动后先在后台做完。
//
// 第一次打开设置窗口时，主线程会停 0.5 秒以上（CI 场景 C15、H01）：Foundation 按需加载属性范围、
// 系统字体第一次画字形、第一次读 SF Symbols 的矢量数据（设置窗口的分页图标、按键符号、“已允许”的勾）。
// 这几件事和窗口无关，启动后在后台先做一遍，主线程第一次用到时就是现成的。

import AppKit
import CoreText

enum FirstUseWarmup {
    /// 设置窗口里出现的字：中文走苹方，英文和数字走系统字体。
    private static let sample = "WindowShade 设置 通用 收起 展开 卷帘条 置顶 窗口浏览 快捷键 关于 0123456789"

    static func start() {
        DispatchQueue.global(qos: .utility).async {
            let started = CFAbsoluteTimeGetCurrent()
            // 和 SwiftUI 排文字时走同一条路：NSAttributedString 转 AttributedString 时加载默认的属性范围。
            _ = AttributedString(NSAttributedString(string: sample))
            drawGlyphs()
            drawSymbols()
            wlog("warmup: text, glyphs and symbols ready in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))ms")
        }
    }

    /// 设置窗口里出现的 SF Symbols（SettingsWindow.swift 的分页、HotKey.swift 的按键、SettingsView.swift 的勾）。
    private static let symbols = [
        "rectangle.compress.vertical", "command", "lock.shield", "gearshape.2", "checkmark.circle.fill",
        "control", "option", "shift", "arrow.left", "arrow.right", "arrow.up", "arrow.down",
        "return", "delete.left", "delete.right", "escape", "arrow.right.to.line", "space",
    ]

    /// 每个符号按设置窗口里的字号栅格化一次，矢量数据就加载好了。
    private static func drawSymbols() {
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        for name in symbols {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { continue }
            var rect = NSRect(origin: .zero, size: image.size)
            _ = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }

    /// 用设置窗口里的几种字号、字重各画一遍，字形缓存里就有了。
    private static func drawGlyphs() {
        guard let context = CGContext(data: nil, width: 1200, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let fonts = [
            NSFont.systemFont(ofSize: NSFont.systemFontSize),
            NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            NSFont.systemFont(ofSize: NSFont.labelFontSize),
        ]
        for font in fonts {
            let text = NSAttributedString(string: sample, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: 2, y: 12)
            CTLineDraw(line, context)
        }
    }
}

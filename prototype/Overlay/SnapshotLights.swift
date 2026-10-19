// 卷帘条截图里原窗口的红绿灯，用标题栏的底色盖掉。
// 卷帘条上真正的红绿灯是系统按钮，对准截图里红绿灯的位置。
// 卷帘条成为当前窗口时，标题栏重新布局，会把系统按钮挪回默认位置；推测 WindowShade 有一帧来不及把按钮放回。
// 这一帧里，截图上的红绿灯和挪开的系统按钮同时露出来，成了两组红绿灯（CI 录像 be8f9b1、ea18372，macOS 26 访达）。
// 截图里不留红绿灯，这一帧最多是按钮的位置不对。

import CoreGraphics

enum SnapshotLights {
    /// rects 是要盖掉的红绿灯所在的按钮框，坐标原点在左下角，单位是点；size 是截图对应的卷帘条大小（点）。
    /// 底色取最左边那个按钮框左边 3 点、高度居中处的像素：那里是标题栏的空白处。取不到或那里全透明时，原样返回截图。
    static func erase(_ image: CGImage, rects: [CGRect], size: CGSize) -> CGImage {
        guard !rects.isEmpty, size.width > 0, size.height > 0,
              let first = rects.min(by: { $0.minX < $1.minX }) else { return image }
        let width = image.width, height = image.height
        let scaleX = CGFloat(width) / size.width, scaleY = CGFloat(height) / size.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let rgbSpace = colorSpace.model == .rgb ? colorSpace : CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return pixels.withUnsafeMutableBytes { buffer -> CGImage in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: rgbSpace, bitmapInfo: info) else { return image }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let sampleX = Int(((first.minX - 3) * scaleX).rounded(.down))
            let sampleY = Int((first.midY * scaleY).rounded(.down))
            guard sampleX >= 0, sampleX < width, sampleY >= 0, sampleY < height else { return image }
            // 位图的第 0 行是图像的最上面一行，绘图坐标的 y 从下往上数。
            let offset = (height - 1 - sampleY) * bytesPerRow + sampleX * 4
            let alpha = CGFloat(buffer[offset + 3]) / 255
            guard alpha > 0 else { return image }
            let color = CGColor(colorSpace: rgbSpace, components: [
                CGFloat(buffer[offset]) / 255 / alpha, CGFloat(buffer[offset + 1]) / 255 / alpha,
                CGFloat(buffer[offset + 2]) / 255 / alpha, alpha,
            ]) ?? CGColor(gray: 0.9, alpha: 1)
            context.setFillColor(color)
            for rect in rects {
                let grown = rect.insetBy(dx: -1, dy: -1)
                context.fill(CGRect(x: grown.minX * scaleX, y: grown.minY * scaleY,
                                    width: grown.width * scaleX, height: grown.height * scaleY))
            }
            return context.makeImage() ?? image
        }
    }
}

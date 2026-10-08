// 需求：S1（docs/testing.md 第 3.2 节）。
// 卷帘条没聚焦时，红绿灯是三个灰点，位置和系统按钮一致；指针移到按钮上时换回系统按钮。
import Cocoa

@main
struct StripTrafficLightTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    let frame = NSRect(x: 200, y: 200, width: 420, height: 30)
    let style: NSWindow.StyleMask = [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable]
    let strip = NativeProxyOverlayWindow(contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: style),
                                         styleMask: style, backing: .buffered, defer: false)
    strip.titlebarAppearsTransparent = true
    strip.titleVisibility = .hidden
    strip.setFrame(frame, display: false)
    strip.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
    strip.usesProxyTitleLayout = true
    strip.configureTrafficLightButtons(.standard)

    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let buttons = types.compactMap { strip.standardWindowButton($0) }
    precondition(buttons.count == 3, "The strip has the three standard buttons")
    guard let content = strip.contentView,
          let gray = content.subviews.compactMap({ $0 as? InactiveTrafficLightsView }).first else {
      preconditionFailure("The strip has the gray lights view")
    }

    func centers(_ rects: [CGRect]) -> [CGPoint] { rects.map { CGPoint(x: $0.midX, y: $0.midY) } }
    func buttonCenters() -> [CGPoint] {
      centers(buttons.map { content.convert($0.frame, from: $0.superview) })
    }
    func showsGray() -> Bool {
      !gray.isHidden && buttons.allSatisfy { $0.alphaValue == 0 }
    }

    precondition(!strip.isKeyWindow, "The strip is not the key window")
    precondition(showsGray(), "Unfocused: gray dots, system buttons transparent")
    precondition(gray.dots.count == 3, "One gray dot per visible button")
    precondition(centers(gray.dots) == buttonCenters(), "Gray dots sit on the system buttons")
    precondition(gray.hitTest(NSPoint(x: gray.dots[0].midX, y: gray.dots[0].midY)) == nil,
                 "Clicks pass through the gray dots to the buttons")

    // 截图条：系统按钮对齐原窗口的灯，灰点跟着走。
    let source: [(CGRect, TrafficAction)] = [
      (CGRect(x: 20, y: 8, width: 14, height: 14), .close),
      (CGRect(x: 42, y: 8, width: 14, height: 14), .minimize),
      (CGRect(x: 64, y: 8, width: 14, height: 14), .zoom),
    ]
    strip.alignStandardTrafficButtons(to: source)
    precondition(centers(gray.dots) == centers(source.map(\.0)), "Gray dots follow the original window's lights")

    // 指针移到按钮上：换回系统按钮（系统对没聚焦的窗口也是悬停时才显示颜色和符号）。
    let closeCenter = strip.contentView!.convert(NSPoint(x: source[0].0.midX, y: source[0].0.midY), to: nil)
    func pointer(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
      if type == .mouseMoved {
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: strip.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 0, pressure: 0)!
      }
      return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                    windowNumber: strip.windowNumber, context: nil, eventNumber: 0,
                                    trackingNumber: 0, userData: nil)!
    }
    strip.sendEvent(pointer(.mouseMoved, at: closeCenter))
    precondition(!showsGray() && gray.isHidden && buttons.allSatisfy { $0.alphaValue == 1 },
                 "Pointer over the lights: system buttons")
    strip.sendEvent(pointer(.mouseMoved, at: NSPoint(x: 300, y: 15)))
    precondition(showsGray(), "Pointer leaves the lights: gray dots again")
    strip.sendEvent(pointer(.mouseMoved, at: closeCenter))
    strip.sendEvent(pointer(.mouseExited, at: NSPoint(x: -20, y: -20)))
    precondition(showsGray(), "Pointer leaves the strip: gray dots again")

    // 隐藏的按钮不画灰点。
    var noZoom = ProxyTrafficLightConfiguration.standard
    noZoom.zoomVisible = false
    strip.configureTrafficLightButtons(noZoom)
    precondition(gray.dots.count == 2, "No gray dot for a hidden button")

    strip.closeProgrammatically()
    print("PASS strip traffic lights")
  }
}

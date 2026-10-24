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
    /// 位置比较留 0.5 点：坐标换算有浮点误差。
    func same(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
      a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
    }
    func buttonCenters() -> [CGPoint] {
      centers(buttons.map { content.convert($0.frame, from: $0.superview) })
    }
    func showsGray() -> Bool {
      !gray.isHidden && buttons.allSatisfy { $0.alphaValue == 0 }
    }

    precondition(!strip.isKeyWindow, "The strip is not the key window")
    precondition(showsGray(), "Unfocused: gray dots, system buttons transparent")
    precondition(gray.dots.count == 3, "One gray dot per visible button")
    precondition(same(centers(gray.dots), buttonCenters()),
                 "Gray dots sit on the system buttons: \(centers(gray.dots)) vs \(buttonCenters())")
    precondition(gray.hitTest(NSPoint(x: gray.dots[0].midX, y: gray.dots[0].midY)) == nil,
                 "Clicks pass through the gray dots to the buttons")

    // 截图条：系统按钮对齐原窗口的灯，灰点跟着走。
    let source: [(CGRect, TrafficAction)] = [
      (CGRect(x: 20, y: 8, width: 14, height: 14), .close),
      (CGRect(x: 42, y: 8, width: 14, height: 14), .minimize),
      (CGRect(x: 64, y: 8, width: 14, height: 14), .zoom),
    ]
    strip.alignStandardTrafficButtons(to: source)
    precondition(same(centers(gray.dots), buttonCenters()) && same(buttonCenters(), centers(source.map(\.0))),
                 "Gray dots follow the original window's lights: \(centers(gray.dots))")

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

    // 按在绿色按钮上再拖动 12 点：当作拖动卷帘条，松开时不算点了绿色按钮
    // （2026-10-18 用户录像：按住绿色按钮挪了约 6 点，Edge 进了全屏）。
    var actions: [TrafficAction] = []
    strip.onAction = { actions.append($0) }
    let zoomCenter = content.convert(buttonCenters()[2], to: nil)
    func press(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                         windowNumber: strip.windowNumber, context: nil, eventNumber: 0,
                         clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    let moved = NSPoint(x: zoomCenter.x + 12, y: zoomCenter.y)
    strip.sendEvent(press(.leftMouseDown, at: zoomCenter))
    strip.sendEvent(press(.leftMouseDragged, at: moved))
    strip.sendEvent(press(.leftMouseUp, at: moved))
    precondition(actions.isEmpty, "Dragging from the green button does not press it: \(actions)")
    // 原地按下、松开：照常算点了绿色按钮。
    strip.sendEvent(press(.leftMouseDown, at: content.convert(buttonCenters()[2], to: nil)))
    strip.sendEvent(press(.leftMouseUp, at: content.convert(buttonCenters()[2], to: nil)))
    precondition(actions.count == 1, "A click on the green button still presses it: \(actions)")
    // 关闭按钮也一样：按下后拖动不算点，原地按下、松开才算。
    actions.removeAll()
    let closeAt = content.convert(buttonCenters()[0], to: nil)
    strip.sendEvent(press(.leftMouseDown, at: closeAt))
    strip.sendEvent(press(.leftMouseDragged, at: NSPoint(x: closeAt.x + 12, y: closeAt.y)))
    strip.sendEvent(press(.leftMouseUp, at: NSPoint(x: closeAt.x + 12, y: closeAt.y)))
    precondition(actions.isEmpty, "Dragging from the close button does not press it: \(actions)")
    let closeNow = content.convert(buttonCenters()[0], to: nil)
    strip.sendEvent(press(.leftMouseDown, at: closeNow))
    strip.sendEvent(press(.leftMouseUp, at: closeNow))
    precondition(actions == [.close], "A click on the close button still presses it: \(actions)")
    strip.onAction = nil

    // 隐藏的按钮不画灰点。
    var noZoom = ProxyTrafficLightConfiguration.standard
    noZoom.zoomVisible = false
    strip.configureTrafficLightButtons(noZoom)
    precondition(gray.dots.count == 2, "No gray dot for a hidden button")

    strip.closeProgrammatically()
    print("PASS strip traffic lights")
  }
}

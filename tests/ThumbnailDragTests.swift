// 需求：S2、A1（docs/testing.md 第 3.2、3.4 节）。缩略图拖到哪里就停在哪里，展开时窗口跟到那里。
// 缺陷回归（2026-10-20 代码审查发现）：拖缩略图时，抓点和移动按处理事件那一刻的指针位置（NSEvent.mouseLocation）算，
// 不按事件自己带的位置；主线程忙、事件处理晚了时，缩略图一路落后指针，松开后也不在松开的地方。
// 这里只建事件对象、直接交给视图，不发给系统；系统里的指针不动，所以按指针位置算的旧代码看不到这次拖动。
import Cocoa

@main
struct ThumbnailDragTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    guard let primaryHeight = NSScreen.screens.first?.frame.height else {
      preconditionFailure("ThumbnailDragTests needs a screen")
    }
    let frame = NSRect(x: 200, y: 200, width: 240, height: 160)
    let window = ShadeThumbnailWindow(frame: frame)
    let view = ShadeThumbnailView(frame: NSRect(origin: .zero, size: frame.size), picture: nil, icon: nil)
    window.contentView = view
    var moves: [NSRect] = []
    var clicks = 0
    view.onMoveEnded = { moves.append($0) }
    view.onClick = { clicks += 1 }

    /// point 是 Cocoa 屏幕坐标（原点在主屏左下角）；事件用的坐标原点在主屏左上角。
    func mouse(_ type: CGEventType, at point: NSPoint) -> NSEvent {
      let location = CGPoint(x: point.x, y: primaryHeight - point.y)
      guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
                                  mouseButton: .left),
            let event = NSEvent(cgEvent: cgEvent) else {
        preconditionFailure("Cannot make a mouse event of type \(type.rawValue)")
      }
      return event
    }

    let press = NSPoint(x: frame.minX + 60, y: frame.minY + 50)
    view.mouseDown(with: mouse(.leftMouseDown, at: press))
    view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: press.x + 40, y: press.y - 20)))
    precondition(window.frame.origin == NSPoint(x: frame.minX + 40, y: frame.minY - 20),
                 "The thumbnail follows the pointer position carried by the drag event: \(window.frame.origin)")
    // 最后一次拖动事件之后指针又动了：松开时按松开事件的位置放。
    view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: press.x + 55, y: press.y - 30)))
    precondition(window.frame.origin == NSPoint(x: frame.minX + 55, y: frame.minY - 30),
                 "The thumbnail ends where the button was released: \(window.frame.origin)")
    precondition(moves == [window.frame], "The move is reported once, with the final frame: \(moves)")
    precondition(clicks == 0, "A drag is not a click")

    // 原地按下、松开：算单击，不挪。
    let before = window.frame
    let here = NSPoint(x: before.minX + 30, y: before.minY + 30)
    view.mouseDown(with: mouse(.leftMouseDown, at: here))
    view.mouseUp(with: mouse(.leftMouseUp, at: here))
    precondition(clicks == 1 && window.frame == before && moves.count == 1, "A click in place does not move the thumbnail")

    window.close()
    print("PASS ThumbnailDragTests")
  }
}

// 覆盖 R1
// 恢复记录和 WindowShade 自己的状态之间的配合：哪些窗口算正在操作、后台找回不能动。
import Cocoa

@main
struct RecoveryJournalTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    let owner = AppDelegate()

    // 正在收起的窗口：installOverlay 一开始就把它从 shadeOperationIDs 里拿掉，之后还要写恢复记录、
    // 等焦点交接、在后台移开原窗口，这期间它也还不在 shaded 里。后台找回不能把它当成上次退出留下的窗口。
    let capturing: CGWindowID = 0x7FFF_FF30
    precondition(owner.transitionOperationState(id: capturing, to: .capturing, reason: "test"),
                 "a window can start folding")
    precondition(!owner.shadeOperationIDs.contains(capturing) && owner.shaded[capturing] == nil,
                 "the window is in neither shadeOperationIDs nor shaded")
    precondition(owner.windowsInUse.contains(capturing),
                 "正在收起（截图、写记录、移开原窗口还没做完）的窗口算正在操作，后台找回不动它")

    // 刚展开、还在确认是否回到原处的窗口：找回不能和展开同时放回它。
    let restoring: CGWindowID = 0x7FFF_FF31
    owner.restoreVerificationTokens[restoring] = UUID()
    precondition(owner.windowsInUse.contains(restoring), "刚展开、还在确认的窗口算正在操作")

    print("PASS RecoveryJournalTests")
  }
}

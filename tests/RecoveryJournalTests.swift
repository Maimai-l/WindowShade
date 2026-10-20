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

    // 恢复记录写下以后、移开原窗口之前放弃收起（窗口号、进程或当前桌面变了）：记录要一起删掉。
    // 留着的话，之后的找回会取消用户自己做的隐藏或最小化。
    let journalDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("windowshade-recovery-\(UUID().uuidString)")
    owner.recoveryJournalOverride = DurableShadeJournal(url: journalDirectory.appendingPathComponent("RecoveryJournal.plist"))
    defer { try? FileManager.default.removeItem(at: journalDirectory) }
    let abandoned: CGWindowID = 0x7FFF_FF32
    precondition(owner.transitionOperationState(id: abandoned, to: .capturing, reason: "test"), "the fold starts")
    precondition(owner.recordShadeRecoveryIntent(id: abandoned, pid: getpid(), bundleID: "test.recovery", appName: "test",
                                                 title: "", originalPosition: CGPoint(x: 40, y: 60),
                                                 originalSize: CGSize(width: 400, height: 300),
                                                 sourceDisplayID: nil, sourceSpaceID: nil),
                 "the recovery intent is written")
    precondition(owner.shadeJournalEntries().contains { owner.journalID($0) == abandoned }, "the intent is on disk")
    let strip = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 28), styleMask: .borderless,
                         backing: .buffered, defer: true)
    strip.isReleasedWhenClosed = false
    owner.abandonFoldAfterIntent(id: abandoned, overlay: strip, reason: "test")
    precondition(!owner.shadeJournalEntries().contains { owner.journalID($0) == abandoned },
                 "放弃收起时删掉已经写下的恢复记录")
    precondition(owner.currentOperationState(abandoned) == .failed, "the fold is marked as failed")

    // 退出：正在收起的窗口还不在 shaded 里，刚展开的窗口还在确认；这两种都要等，不能立刻退出。
    let quitting = AppDelegate()
    precondition(!quitting.mustWaitBeforeQuit, "nothing folded, folding or being unfolded: quit at once")
    precondition(quitting.transitionOperationState(id: 0x7FFF_FF33, to: .capturing, reason: "test"), "a fold starts")
    precondition(quitting.mustWaitBeforeQuit,
                 "退出时有窗口正在收起：等它收起完再展开，不能让它在 WindowShade 退出后一直藏着")
    let unfolding = AppDelegate()
    unfolding.restoreVerificationTokens[0x7FFF_FF34] = UUID()
    precondition(unfolding.mustWaitBeforeQuit,
                 "退出时有窗口刚展开、还在确认：等确认做完、恢复记录删掉再退出")

    print("PASS RecoveryJournalTests")
  }
}

// 需求：R2（docs/design.md）。收起时隐藏了应用程序，用户把它唤回以后，复查和重试不能因为切了桌面就不再进行。
// 依据：代码审查。应用程序的窗口在桌面 1 上，收起时整个应用程序被隐藏；在桌面 2 上按 Command-Tab 切到它，系统取消隐藏并切到桌面 1；
// 这时 isHidden 常常还没更新，0.1 秒后的重试看到呈现编号换了，就不再展开，卷帘条盖在已经回来的窗口上，等定时核对才撤。
import Cocoa

@main
struct FoldRevealTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    let owner = AppDelegate()
    // 一个一定在运行的应用程序：程序坞。
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
      preconditionFailure("the Dock is not running")
    }
    let id: CGWindowID = 0x7FFF_FFE0
    let state = ShadeState(element: AXUIElementCreateApplication(pid), sourceWindowID: id, originalPosition: .zero,
                           originalSize: CGSize(width: 400, height: 300), sourceDisplayID: nil, sourceSpaceID: nil,
                           overlay: nil, overlayID: nil, hide: .hidden, pid: pid, bundleID: "test.reveal", appName: "test",
                           title: "test", appearanceMode: .nativeScreenshot, lifecycleStage: .folded, previewImage: nil,
                           quickLookReopenURL: nil, ignoreAppRevealUntil: .distantPast, observer: nil)
    owner.shaded[id] = state
    let stamp = owner.foldCallbackStamp(id: id, state: state)
    precondition(owner.foldRevealIsSameFold(stamp, step: "test"), "刚唤回时：是同一次收起")

    owner.foldPresentationID = UUID()   // 系统切到了原窗口所在的桌面
    precondition(!owner.foldCallbackIsCurrent(stamp), "切桌面以后，按呈现编号核对的回调算过期")
    precondition(owner.foldRevealIsSameFold(stamp, step: "test"),
                 "切了桌面仍是同一次收起：唤回之后的复查和重试照常进行")

    owner.shaded[id] = nil
    precondition(!owner.foldRevealIsSameFold(stamp, step: "test"), "窗口已经展开或清理：不再处理")
    print("PASS FoldRevealTests")
  }
}

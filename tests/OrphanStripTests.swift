// 需求：R3（docs/design.md）。原窗口在别处被关掉、关闭通知又没收到时，卷帘条要在定时核对里自己撤掉。
// 依据：上游 surfine/WindowShade 343fdfa（真机：收起后用辅助功能按关闭，应用程序仍在运行，卷帘条一直留着）。
import Cocoa

@main
struct OrphanStripTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    let owner = AppDelegate()
    // 一个一定在运行、runningApp(pid:) 找得到的应用程序：程序坞。
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
      preconditionFailure("the Dock is not running")
    }
    func state(window: CGWindowID, hide: HideMethod) -> ShadeState {
      ShadeState(element: AXUIElementCreateApplication(pid), sourceWindowID: window, originalPosition: .zero,
                 originalSize: CGSize(width: 400, height: 300), sourceDisplayID: nil, sourceSpaceID: nil,
                 overlay: nil, overlayID: nil, hide: hide, pid: pid, bundleID: "test.orphan", appName: "test",
                 title: "test", appearanceMode: .nativeScreenshot, lifecycleStage: .folded, previewImage: nil,
                 quickLookReopenURL: nil, ignoreAppRevealUntil: .distantPast, observer: nil)
    }
    // 窗口服务器里没有这个编号的窗口；应用程序还在运行。
    let missing: CGWindowID = 0x7FFF_FFF0
    let closed = state(window: missing, hide: .offscreen)
    precondition(!owner.sourceWindowMissingShouldCleanup(id: missing, state: closed),
                 "第一轮查不到窗口：先不撤，窗口服务器可能还没更新")
    precondition(owner.sourceWindowMissingShouldCleanup(id: missing, state: closed),
                 "连续两轮读不到窗口、窗口服务器也查不到：窗口已经在别处被关掉，撤掉卷帘条")

    // 快速查看的收起本来就是把窗口关掉：查不到窗口也不撤。
    let quickLookID: CGWindowID = 0x7FFF_FFF1
    let quickLook = state(window: quickLookID, hide: .quickLookClosed)
    _ = owner.sourceWindowMissingShouldCleanup(id: quickLookID, state: quickLook)
    precondition(!owner.sourceWindowMissingShouldCleanup(id: quickLookID, state: quickLook),
                 "快速查看的收起：查不到窗口是正常的，不撤")
    print("PASS OrphanStripTests")
  }
}

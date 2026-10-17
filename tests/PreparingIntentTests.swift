// 恢复记录还停在“准备”这一步时，WindowShade 重新启动后怎样处理那扇窗口。
// 只看窗口位置在屏幕上不够：隐藏应用程序、最小化窗口的请求可能在 WindowShade 退出前发出、退出后才生效，
// 这时窗口位置在屏幕上，也要放回来。
// 依据：2026-10-17 CI 场景 L03（dd40ef5），kill -9 之后测试应用程序才隐藏，重新启动后应用程序一直隐藏着。
// J5 测 WindowShade 运行期间的后台扫描：写回之前再核对一次记录和正在收起的窗口。依据：2026-10-17 CI 场景 A07（54f1aa1）。

@main
struct PreparingIntentTests {
    static func main() {
        var suite = TestSuite("preparing-intent")

        suite.section("J1", "窗口在屏幕上、应用程序没隐藏、窗口没最小化：完好，删掉记录")
        suite.expect(preparingIntentOutcome(windowOnScreen: true, appHidden: false, minimized: false) == .intact,
                     "a visible window is left alone")

        suite.section("J2", "应用程序已隐藏：取消隐藏，即使窗口位置在屏幕上（L03）")
        suite.expect(preparingIntentOutcome(windowOnScreen: true, appHidden: true, minimized: false) == .unhideApp,
                     "a hidden app is unhidden although its window frame is on screen")
        suite.expect(preparingIntentOutcome(windowOnScreen: false, appHidden: true, minimized: false) == .unhideApp,
                     "a hidden app with its window off screen is unhidden")

        suite.section("J3", "窗口已最小化：解除最小化")
        suite.expect(preparingIntentOutcome(windowOnScreen: true, appHidden: false, minimized: true) == .unminimize,
                     "a minimized window is brought back from the Dock")

        suite.section("J4", "窗口在屏幕外：放回原处")
        suite.expect(preparingIntentOutcome(windowOnScreen: false, appHidden: false, minimized: false) == .moveBack,
                     "a window parked off screen is moved back")

        suite.section("J5", "扫描开始后记录已经删掉或窗口正在收起：写回时不再动它（A07）")
        suite.expect(rescueActionStillApplies(id: 7, liveJournalIDs: [7], inFlightIDs: []),
                     "the entry is still there and nothing is in flight: apply")
        suite.expect(!rescueActionStillApplies(id: 7, liveJournalIDs: [], inFlightIDs: []),
                     "the entry was removed during the scan (the window was unfolded): skip")
        suite.expect(!rescueActionStillApplies(id: 7, liveJournalIDs: [7], inFlightIDs: [7]),
                     "the window is being folded: skip")

        suite.finish()
    }
}

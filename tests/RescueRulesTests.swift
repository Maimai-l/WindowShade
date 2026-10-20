// 覆盖 R1 R5
// 恢复记录（Recovery/）在 WindowShade 运行期间怎样处理：什么时候删、什么时候还要动窗口。
// 原则：用户已经看见窗口以后，恢复记录不再移动、取消隐藏或拉回它；匹配不上的记录不一直重试。

@main
struct RescueRulesTests {
    /// 按顺序给出观察结果的假验证环境：时钟随每次安排前进，安排的检查依次执行。
    final class VerifierHarness {
        var clock = 0.0
        var queue: [() -> Void] = []
        var acknowledged = 0
        var results: [Bool] = []
        var observations: [RestoreObservation]
        let fallback: RestoreObservation

        init(_ observations: [RestoreObservation], then fallback: RestoreObservation) {
            self.observations = observations
            self.fallback = fallback
        }

        func run() {
            let verifier = RestoreVerifier(
                now: { self.clock },
                schedule: { delay, action in
                    self.clock += delay
                    self.queue.append(action)
                },
                isCurrent: { true },
                observe: { reply in
                    reply(self.observations.isEmpty ? self.fallback : self.observations.removeFirst())
                },
                acknowledge: { self.acknowledged += 1 },
                completion: { self.results.append($0) })
            verifier.start()
            var steps = 0
            while !queue.isEmpty, steps < 1000 {
                queue.removeFirst()()
                steps += 1
            }
        }
    }

    static func main() {
        var suite = TestSuite("rescue-rules")

        suite.section("V1", "展开后窗口回到记录的位置：删掉恢复记录")
        let back = VerifierHarness([.pending], then: .visible)
        back.run()
        suite.expect(back.acknowledged == 1 && back.results == [true], "the record is removed once the window is back")

        suite.section("V2", "展开后用户看得见窗口，但位置或大小一直对不上（macOS 把窗口限制在屏幕内、用户拖走或最小化了它）：到时限也删掉恢复记录")
        let clamped = VerifierHarness([], then: .shown)
        clamped.run()
        suite.expect(clamped.results == [false], "the check reports that the window is not at its place")
        suite.expect(clamped.acknowledged == 1,
                     "the record is removed: a later rescue must not move the window the user already sees")
        let minimizedAfterwards = VerifierHarness([.shown, .shown], then: .pending)
        minimizedAfterwards.run()
        suite.expect(minimizedAfterwards.acknowledged == 1,
                     "the user saw the window, then minimized or hid it: the record is removed, the window stays as the user left it")

        suite.section("V3", "展开后窗口一次都没出现：恢复记录留着，交给找回")
        let neverShown = VerifierHarness([], then: .pending)
        neverShown.run()
        suite.expect(neverShown.results == [false] && neverShown.acknowledged == 0,
                     "a window that never came back keeps its record")

        suite.section("R1", "记录停在已收起或展开中、用户已经看得见窗口：只删记录，不再移动、取消隐藏或升起")
        suite.expect(windowUserVisible(windowOnScreen: true, appHidden: false, minimized: false, transparent: false),
                     "a window on screen, not hidden, not minimized and opaque is already back")
        suite.expect(!windowUserVisible(windowOnScreen: false, appHidden: false, minimized: false, transparent: false),
                     "a window parked off screen still needs the rescue")
        suite.expect(!windowUserVisible(windowOnScreen: true, appHidden: true, minimized: false, transparent: false),
                     "a window of a hidden app still needs the rescue")
        suite.expect(!windowUserVisible(windowOnScreen: true, appHidden: false, minimized: true, transparent: false),
                     "a minimized window still needs the rescue")
        suite.expect(!windowUserVisible(windowOnScreen: true, appHidden: false, minimized: false, transparent: true),
                     "a transparent window in place still needs the rescue")

        suite.section("R2", "透明度：低于 0.05 算看不见；读不到不算透明")
        suite.expect(windowLooksTransparent(alpha: 0), "alpha 0 is transparent")
        suite.expect(!windowLooksTransparent(alpha: 1), "alpha 1 is not")
        suite.expect(!windowLooksTransparent(alpha: nil), "an unreadable alpha is not treated as transparent")
        suite.expect(!windowLooksTransparent(alpha: .nan), "a broken alpha is not treated as transparent")

        suite.section("R3", "找回之后窗口仍然看不见：最多试 3 次，之后删掉记录，不再每 30 秒挪一次窗口")
        suite.expect(!journalRescueGivesUp(attempts: 1), "the first unverified attempt is retried")
        suite.expect(!journalRescueGivesUp(attempts: 2), "the second unverified attempt is retried")
        suite.expect(journalRescueGivesUp(attempts: 3), "after the third the record is dropped")

        suite.section("R4", "对不上的恢复记录直接删掉，不留到 14 天后过期：进程已退出、应用程序在记录之后重新打开过、窗口已经关掉")
        let created = 1_000_000.0
        suite.expect(journalEntryCanStillMatch(processRunning: true, processLaunchedAt: created - 3600,
                                               createdAt: created, windowExists: true),
                     "the app that wrote the record still runs and the window exists: keep")
        suite.expect(!journalEntryCanStillMatch(processRunning: false, processLaunchedAt: nil,
                                                createdAt: created, windowExists: nil),
                     "the process that wrote the record has quit (or the Mac restarted): drop")
        suite.expect(!journalEntryCanStillMatch(processRunning: true, processLaunchedAt: created + 60,
                                                createdAt: created, windowExists: true),
                     "the process id now belongs to an app launched after the record: drop")
        suite.expect(!journalEntryCanStillMatch(processRunning: true, processLaunchedAt: created - 3600,
                                                createdAt: created, windowExists: false),
                     "the window server no longer has the window: drop")
        suite.expect(journalEntryCanStillMatch(processRunning: true, processLaunchedAt: nil,
                                               createdAt: created, windowExists: nil),
                     "the launch time or the window lookup is unknown: keep")

        suite.section("R5", "别的窗口收起着时，上次退出留下的记录照样找回；收起着、正在收起的窗口的记录不动")
        let folded: UInt32 = 30, foldingNow: UInt32 = 31, leftOver: UInt32 = 32
        let inUse: Set<UInt32> = [folded, foldingNow]
        suite.expect(journalHasOrphanEntries(journalIDs: [folded, leftOver], inUse: inUse),
                     "a record left by the last run is due even while another window is folded")
        suite.expect(!journalHasOrphanEntries(journalIDs: [folded, foldingNow], inUse: inUse),
                     "records of windows folded right now are not rescued")
        suite.expect(rescueActionStillApplies(id: leftOver, liveJournalIDs: [folded, leftOver], inFlightIDs: inUse),
                     "the rescue of the left-over window is applied although a fold happened during the scan")
        suite.expect(!rescueActionStillApplies(id: foldingNow, liveJournalIDs: [foldingNow], inFlightIDs: inUse),
                     "a window being folded is not moved back")
        suite.expect(!parkedWindowScanAllowed(inUse: inUse),
                     "windows parked without a record are not touched while anything is folded")
        suite.expect(parkedWindowScanAllowed(inUse: []), "with nothing folded the parked-window scan runs")

        suite.finish()
    }
}

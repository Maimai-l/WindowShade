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

        suite.finish()
    }
}

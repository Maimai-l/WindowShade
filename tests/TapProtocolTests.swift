// 鼠标钩子进程和 WindowShade 之间的询问：编码来回不变、坏数据不认、过时的询问不处理、回话只认“拦下”。
import CoreGraphics
import Foundation

@main
struct TapProtocolTests {
    static func main() {
        var t = TestSuite("TapProtocol")

        t.section("T1", "询问编码后原样解出")
        let request = TapRequest(point: CGPoint(x: 620.5, y: 154), clicks: 2, sentAt: 781_000_123.25)
        t.expect(TapRequest(request.encoded()) == request, "双击的询问来回不变")
        let triple = TapRequest(point: CGPoint(x: -300, y: 1200), clicks: 3, sentAt: 1)
        t.expect(TapRequest(triple.encoded()) == triple, "副屏上的负坐标、三击也不变")
        let withDeadline = TapRequest(point: .zero, clicks: 2, sentAt: 50, answerBy: 50.25)
        t.expect(TapRequest(withDeadline.encoded())?.answerBy == 50.25, "answerBy 也来回不变")

        t.section("T2", "坏数据不当成询问")
        t.expect(TapRequest(Data()) == nil, "空数据")
        t.expect(TapRequest(Data(repeating: 0, count: 39)) == nil, "少一个字节")
        t.expect(TapRequest(Data(repeating: 0, count: 41)) == nil, "多一个字节")
        let zeroClicks = [0.0, 0.0, 0.0, 1.0, 1.3].withUnsafeBytes { Data($0) }
        t.expect(TapRequest(zeroClicks) == nil, "点击次数为 0")
        let notANumber = [Double.nan, 0.0, 2.0, 1.0, 1.3].withUnsafeBytes { Data($0) }
        t.expect(TapRequest(notANumber) == nil, "坐标不是数")

        t.section("T3", "过了钩子的时限的询问不处理")
        t.expect(TapProtocol.isFresh(sentAt: 100, now: 100), "刚发出")
        t.expect(TapProtocol.isFresh(sentAt: 100, now: 100.3), "0.3 秒后还算数")
        t.expect(TapProtocol.isFresh(sentAt: 100, now: 100.34), "0.34 秒后还算数")
        t.expect(!TapProtocol.isFresh(sentAt: 100, now: 100.36), "0.36 秒后不算：钩子 0.4 秒就放行，回话路上还要时间")
        t.expect(!TapProtocol.isFresh(sentAt: 100, now: 100 + TapProtocol.replyTimeout),
                 "钩子不再等回话时，WindowShade 已经不处理这次询问")
        t.expect(!TapProtocol.isFresh(sentAt: 100, now: 102), "WindowShade 停住 2 秒后才收到")
        t.expect(!TapProtocol.isFresh(sentAt: 100, now: 99), "时刻在未来：不认")
        t.expect(TapProtocol.deadline <= 0.5, "钩子的时限远小于系统停用钩子的约 2 秒")

        // 缺陷回归（2026-10-20 代码审查）：送出询问不花时间时，钩子进程在事件产生后约 0.3 秒放行，
        // isFresh 却把 0.35 秒以内的询问都算作按时；决定回话时还要读别的应用程序的标题栏，回话晚了，
        // WindowShade 仍会收起系统已经缩放过的窗口。answerInTime 按询问带来的 answerBy 判断，决定回话之前和之后各查一次。
        t.section("T9", "按钩子进程实际放行的时刻判断回话是否及时")
        let asked = TapRequest(point: .zero, clicks: 2, sentAt: 100, answerBy: 100.3)
        t.expect(TapProtocol.answerInTime(asked, now: 100.1), "钩子进程还在等")
        t.expect(TapProtocol.answerInTime(asked, now: 100.27), "离钩子进程放行还有 30 毫秒：来得及")
        t.expect(!TapProtocol.answerInTime(asked, now: 100.29), "离钩子进程放行不到 20 毫秒：回话可能送不到，按放行处理")
        t.expect(!TapProtocol.answerInTime(asked, now: 100.32), "钩子进程已经放行（0.32 秒，isFresh 仍算作按时）")
        t.expect(TapProtocol.isFresh(sentAt: 100, now: 100.32) && !TapProtocol.answerInTime(asked, now: 100.32),
                 "isFresh 算作按时，answerInTime 算作不按时")
        t.expect(!TapProtocol.answerInTime(asked, now: 99), "时刻在未来：不认")
        let defaulted = TapRequest(point: .zero, clicks: 2, sentAt: 100)
        t.expect(abs(defaulted.answerBy - (100 + TapProtocol.deadline - TapProtocol.sendTimeout)) < 1e-9,
                 "没带 answerBy 时按最早放行的时刻算")

        t.section("T4", "回话只认“拦下”这一种")
        t.expect(TapReply.swallow(TapReply.encoded(swallow: true)), "拦下")
        t.expect(!TapReply.swallow(TapReply.encoded(swallow: false)), "放行")
        t.expect(!TapReply.swallow(nil), "没有回话：放行")
        t.expect(!TapReply.swallow(Data([1, 1])), "长度不对：放行")
        t.expect(!TapReply.swallow(Data([2])), "不认识的值：放行")

        t.section("T6", "WindowShade 一次没回话，接下来的双击不再等它（CI A33-Safari：两次等待叠起来，探测点击晚了 1.08 秒）")
        var gate = TapAskGate()
        t.expect(gate.shouldAsk(now: 100), "平时照常问")
        gate.recordUnanswered(now: 100.4)
        t.expect(!gate.shouldAsk(now: 100.5), "刚没回话：0.1 秒后的双击直接放行，不再等 0.4 秒")
        t.expect(!gate.shouldAsk(now: 101.3), "1 秒之内都不问")
        t.expect(gate.shouldAsk(now: 101.5), "过了 1 秒再问")
        gate.recordUnanswered(now: 101.9)
        gate.recordAnswered()
        t.expect(gate.shouldAsk(now: 102.0), "回话了就恢复照常问")
        t.expect(TapProtocol.deadline + 0.05 < 1.0,
                 "一次点击最多被挡一次等待的时间，加上余量也在 1 秒（I2）之内")

        t.section("T7", "从事件产生算起总共只等 deadline，扣掉排队的时间（场景 A33-Safari）")
        let fresh = TapProtocol.waits(eventAge: 0)
        t.expect(fresh.map { abs($0.send + $0.reply - TapProtocol.deadline) < 1e-9 } ?? false, "刚产生的事件：两段等待合起来就是 deadline")
        t.expect(fresh.map { $0.send <= TapProtocol.sendTimeout } ?? false, "送出那一段不超过 sendTimeout")
        let queued = TapProtocol.waits(eventAge: 0.3)
        t.expect(queued.map { abs($0.send + $0.reply - 0.1) < 1e-9 } ?? false, "排队 0.3 秒的事件只剩 0.1 秒可等")
        t.expect(TapProtocol.waits(eventAge: 0.36) == nil, "剩下的不够 50 毫秒：不问，直接放行")
        t.expect(TapProtocol.waits(eventAge: 5) == nil, "排了很久的事件：不问")
        t.expect(TapProtocol.waits(eventAge: -1).map { abs($0.send + $0.reply - TapProtocol.deadline) < 1e-9 } ?? false,
                 "时间戳在未来：按刚产生处理")
        // 时间戳两种编码：纳秒，或 mach 时钟的计数（Apple 芯片上一个计数约 41.67 纳秒）。
        let ticksPerSecond = UInt64(24_000_000)
        let now = 1_000 * ticksPerSecond
        let age = TapProtocol.eventAge(timestamp: now - ticksPerSecond / 4, nowTicks: now, numer: 125, denom: 3)
        t.expect(age.map { abs($0 - 0.25) < 1e-6 } ?? false, "时间戳是 mach 计数：0.25 秒")
        let nowNanos = UInt64(Double(now) * 125 / 3)
        let ageNanos = TapProtocol.eventAge(timestamp: nowNanos - 250_000_000, nowTicks: now, numer: 125, denom: 3)
        t.expect(ageNanos.map { abs($0 - 0.25) < 1e-6 } ?? false, "时间戳是纳秒：0.25 秒")
        let intel = TapProtocol.eventAge(timestamp: 5_000_000_000 - 100_000_000, nowTicks: 5_000_000_000, numer: 1, denom: 1)
        t.expect(intel.map { abs($0 - 0.1) < 1e-6 } ?? false, "计数就是纳秒的机器：0.1 秒")
        t.expect(TapProtocol.eventAge(timestamp: 0, nowTicks: now, numer: 125, denom: 3) == nil, "换算结果不在 0 到 10 秒之间：返回 nil")

        t.section("T8", "点击排队超过 0.25 秒才到钩子时记日志（场景 A33-Safari）")
        t.expect(!TapProtocol.isLate(eventAge: 0.1), "排队 0.1 秒：不记")
        t.expect(TapProtocol.isLate(eventAge: 0.3), "排队 0.3 秒：记")
        t.expect(TapProtocol.isLate(eventAge: 1.18), "排队 1.18 秒：记")

        t.section("T5", "两个 WindowShade 各用各的端口")
        t.expect(TapProtocol.portName(appPID: 100) != TapProtocol.portName(appPID: 101), "端口名带进程号")
        t.finish()
    }
}

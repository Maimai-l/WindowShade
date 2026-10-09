// 鼠标钩子进程和 WindowShade 之间的询问：编码来回不变、坏数据不认、过时的询问不处理、回话只认“吞掉”。
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

        t.section("T2", "坏数据不当成询问")
        t.expect(TapRequest(Data()) == nil, "空数据")
        t.expect(TapRequest(Data(repeating: 0, count: 31)) == nil, "少一个字节")
        t.expect(TapRequest(Data(repeating: 0, count: 33)) == nil, "多一个字节")
        let zeroClicks = [0.0, 0.0, 0.0, 1.0].withUnsafeBytes { Data($0) }
        t.expect(TapRequest(zeroClicks) == nil, "点击次数为 0")
        let notANumber = [Double.nan, 0.0, 2.0, 1.0].withUnsafeBytes { Data($0) }
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
        t.expect(TapProtocol.sendTimeout + TapProtocol.replyTimeout <= 0.5, "钩子的时限远小于系统停用钩子的约 2 秒")

        t.section("T4", "回话只认“吞掉”这一种")
        t.expect(TapReply.swallow(TapReply.encoded(swallow: true)), "吞掉")
        t.expect(!TapReply.swallow(TapReply.encoded(swallow: false)), "放行")
        t.expect(!TapReply.swallow(nil), "没有回话：放行")
        t.expect(!TapReply.swallow(Data([1, 1])), "长度不对：放行")
        t.expect(!TapReply.swallow(Data([2])), "不认识的值：放行")

        t.section("T5", "两个 WindowShade 各用各的端口")
        t.expect(TapProtocol.portName(appPID: 100) != TapProtocol.portName(appPID: 101), "端口名带进程号")
        t.finish()
    }
}

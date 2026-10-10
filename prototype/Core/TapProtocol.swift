// 鼠标钩子进程（TapHelper/main.swift）和 WindowShade 之间的一问一答（docs/design.md 第 5.9 节）。
//
// 主动钩子挡着全系统的点击。它放在 WindowShade 里时，WindowShade 一停住（崩溃时系统生成报告会把它挂起、
// 调试器暂停），全系统的点击就要等系统约 2 秒后停用钩子才放行（场景 X11）。钩子放进一个只做这件事的小进程：
// 遇到双击、三击才问 WindowShade，最多等 deadline；WindowShade 没回话就放行。
// 只依赖 Foundation 和 CoreGraphics：两边都编进去，也能单测（tests/TapProtocolTests.swift）。

import CoreGraphics
import Foundation

enum TapProtocol {
    /// 从事件产生算起，钩子进程最多等 WindowShade 回话多久。系统在钩子约 2 秒不回话时才停用它，这里要远小于那个值。
    static let deadline: TimeInterval = 0.4
    /// 询问送进 WindowShade 的端口最多等多久：端口排满（WindowShade 停住、积了很多询问）时才会等。
    static let sendTimeout: TimeInterval = 0.1
    /// 旧的固定回话时限，只有测试还在用；钩子实际的两段等待见 waits，合计不超过 deadline。
    static let replyTimeout: TimeInterval = deadline
    /// 钩子进程等回话时只跑这个运行循环模式：等的时候不处理钩子自己的事件。
    static let replyMode = "com.windowshade.prototype.tap.reply"
    /// 问的是“这次双击（三击）要不要拦下”。
    static let askMessageID: Int32 = 1
    /// 钩子进程在 WindowShade 包里的文件名（Contents/MacOS/）。
    static let helperName = "WindowShadeTapHelper"
    /// 钩子进程建不了钩子（没有辅助功能权限等）时的退出码：WindowShade 改用自己的钩子。
    static let cannotCreateTapExitCode: Int32 = 2

    /// WindowShade 收询问的端口名，带上它的进程号：同时开着两个 WindowShade 时各问各的。
    static func portName(appPID: pid_t) -> String { "com.windowshade.prototype.tap.\(appPID)" }

    /// 这次询问的两段等待各给多少：从事件产生算起，钩子总共只等 deadline。前面的询问占着钩子线程时，
    /// 后面的事件已经排了一段队；如果每次询问都再等一个完整时限，等待就会累加，超过系统允许钩子占用的时间，
    /// 系统会停用钩子（2026-10-09 CI 场景 A33-Safari：探测点击晚了 1.24 秒，钩子被停用一次）。
    /// 剩下的时间不够 minimumWait 就不问，直接放行。
    static func waits(eventAge: TimeInterval) -> (send: TimeInterval, reply: TimeInterval)? {
        let budget = deadline - max(0, eventAge)
        guard budget >= minimumWait else { return nil }
        let send = min(sendTimeout, budget / 2)
        return (send, budget - send)
    }
    static let minimumWait: TimeInterval = 0.05

    /// 事件从产生到现在过了多久（秒）。CGEvent 的时间戳在有的系统上是纳秒，在有的系统上是 mach 时钟的计数，
    /// 两种都换算一次，先看按计数换算的结果，不在 0 到 10 秒之间再看按纳秒换算的；都不在就返回 nil，调用方按刚产生处理。
    static func eventAge(timestamp: UInt64, nowTicks: UInt64, numer: UInt32, denom: UInt32) -> TimeInterval? {
        let scale = Double(numer) / Double(denom)
        let nowNanos = Double(nowTicks) * scale
        let fromTicks = (nowNanos - Double(timestamp) * scale) / 1e9
        let fromNanos = (nowNanos - Double(timestamp)) / 1e9
        for age in [fromTicks, fromNanos] where age >= 0 && age < 10 { return age }
        return nil
    }

    /// WindowShade 开始处理时，这次询问还算不算数。钩子过了时限就放行了；再按它收起，
    /// 用户就会同时看到系统的双击动作（缩放）和收起。留 50 毫秒余量给回话路上的时间。
    static func isFresh(sentAt: CFAbsoluteTime, now: CFAbsoluteTime) -> Bool {
        let age = now - sentAt
        return age >= 0 && age < deadline - 0.05
    }
}

/// 要不要问 WindowShade。它一次没在时限内回话（主线程在等一个无响应的应用程序之类），接下来 quietPeriod
/// 之内的双击直接放行，不再等：不然连着几次双击，每次都等满时限，后面的点击要等前面几次加起来的时间
/// （2026-10-09 CI 场景 A33-Safari：探测点击晚了 1.08 秒）。这段时间里双击标题栏不收起。
struct TapAskGate {
    static let quietPeriod: TimeInterval = 1.0
    private var quietUntil: CFAbsoluteTime = 0

    init() {}

    func shouldAsk(now: CFAbsoluteTime) -> Bool { now >= quietUntil }
    mutating func recordUnanswered(now: CFAbsoluteTime) { quietUntil = now + Self.quietPeriod }
    mutating func recordAnswered() { quietUntil = 0 }
}

/// 一次询问：点在哪里、第几下（2 是双击，3 是三击）、事件产生的时刻。WindowShade 按这个时刻判断询问是否过时。
struct TapRequest: Equatable, Sendable {
    var point: CGPoint
    var clicks: Int64
    var sentAt: CFAbsoluteTime

    /// 四个 Double：x、y、点击次数、时刻。
    func encoded() -> Data {
        [Double(point.x), Double(point.y), Double(clicks), sentAt].withUnsafeBytes { Data($0) }
    }

    init(point: CGPoint, clicks: Int64, sentAt: CFAbsoluteTime) {
        self.point = point
        self.clicks = clicks
        self.sentAt = sentAt
    }

    init?(_ data: Data) {
        guard data.count == 4 * MemoryLayout<Double>.size else { return nil }
        let values: [Double] = data.withUnsafeBytes { raw in
            (0..<4).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Double>.size, as: Double.self) }
        }
        guard values.allSatisfy(\.isFinite), values[2] >= 1, values[2] <= 1000 else { return nil }
        self.init(point: CGPoint(x: values[0], y: values[1]), clicks: Int64(values[2]), sentAt: values[3])
    }
}

/// 回话：一个字节，1 是拦下，其他都是放行。
enum TapReply {
    static func encoded(swallow: Bool) -> Data { Data([swallow ? 1 : 0]) }
    static func swallow(_ data: Data?) -> Bool { data?.count == 1 && data?.first == 1 }
}

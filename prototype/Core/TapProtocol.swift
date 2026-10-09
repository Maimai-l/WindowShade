// 鼠标钩子进程（TapHelper/main.swift）和 WindowShade 之间的一问一答（docs/design.md 第 5.9 节）。
//
// 主动钩子挡着全系统的点击。它放在 WindowShade 里时，WindowShade 一停住（崩溃时系统生成报告会把它挂起、
// 调试器暂停），全系统的点击就要等系统约 2 秒后停用钩子才放行（场景 X11）。钩子放进一个只做这件事的小进程：
// 遇到双击、三击才问 WindowShade，最多等 deadline；WindowShade 没回话就放行。
// 只依赖 Foundation 和 CoreGraphics：两边都编进去，也能单测（tests/TapProtocolTests.swift）。

import CoreGraphics
import Foundation

enum TapProtocol {
    /// 钩子进程等 WindowShade 回话的时限。系统在钩子约 2 秒不回话时才停用它，这里要远小于那个值。
    static let deadline: TimeInterval = 0.4
    /// 询问送进 WindowShade 的端口最多等多久（端口排满时才会等）；剩下的时间等回话，两段加起来不超过 deadline。
    static let sendTimeout: TimeInterval = 0.1
    static let replyTimeout: TimeInterval = deadline - sendTimeout
    /// 钩子进程等回话时只跑这个运行循环模式：等的时候不处理钩子自己的事件。
    static let replyMode = "com.windowshade.prototype.tap.reply"
    /// 问的是“这次双击（三击）要不要吞掉”。
    static let askMessageID: Int32 = 1
    /// 钩子进程在 WindowShade 包里的文件名（Contents/MacOS/）。
    static let helperName = "WindowShadeTapHelper"
    /// 钩子进程建不了钩子（没有辅助功能权限等）时的退出码：WindowShade 改用自己的钩子。
    static let cannotCreateTapExitCode: Int32 = 2

    /// WindowShade 收询问的端口名，带上它的进程号：同时开着两个 WindowShade 时各问各的。
    static func portName(appPID: pid_t) -> String { "com.windowshade.prototype.tap.\(appPID)" }

    /// WindowShade 开始处理时，这次询问还算不算数。钩子过了时限就放行了；再按它收起，
    /// 用户就会同时看到系统的双击动作（缩放）和收起。留 50 毫秒余量给回话路上的时间。
    static func isFresh(sentAt: CFAbsoluteTime, now: CFAbsoluteTime) -> Bool {
        let age = now - sentAt
        return age >= 0 && age < deadline - 0.05
    }
}

/// 一次询问：点在哪里、第几下（2 是双击，3 是三击）、钩子发出的时刻。
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

/// 回话：一个字节，1 是吞掉，其他都是放行。
enum TapReply {
    static func encoded(swallow: Bool) -> Data { Data([swallow ? 1 : 0]) }
    static func swallow(_ data: Data?) -> Bool { data?.count == 1 && data?.first == 1 }
}

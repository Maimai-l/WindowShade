// WindowShadeTapHelper：替 WindowShade 持有全系统的鼠标钩子（docs/design.md 第 5.9 节）。
//
// 主动钩子挡着全系统的点击和排在后面的按键。钩子放在 WindowShade 里时，WindowShade 一停住
// （崩溃时系统生成报告会把它挂起、调试器暂停），点击就要等系统停用钩子才放行（场景 X11）；
// 2026-10-08 用户那次，点击和快捷键一直不响应，只能强制重启。
// 这个进程只做一件事：单击直接放行；双击、三击问 WindowShade 要不要吞掉，最多等 TapProtocol.deadline，
// 没回话就放行。不碰界面、不做辅助功能查询、不写文件。WindowShade 退出它就退出。
//
// 用法：WindowShadeTapHelper <WindowShade 的进程号> <端口名>
// 退出码：0 WindowShade 已退出；2 建不了钩子（WindowShade 改用自己的钩子）；64 参数不对。

import CoreGraphics
import Foundation

enum TapHelper {
    nonisolated(unsafe) static var portName: CFString = "" as CFString
    nonisolated(unsafe) static var tapPort: CFMachPort?
    nonisolated(unsafe) static var remotePort: CFMessagePort?
    /// 吞掉了一次按下，就把跟它配对的松开也吞掉（见 App/EventTapCallback.swift）。只在钩子线程上读写。
    nonisolated(unsafe) static var swallowNextMouseUp = false
    static let logQueue = DispatchQueue(label: "tap-helper.log")

    /// 给 WindowShade 的日志（它读这个进程的标准输出）。写在后台队列上，标准输出设为不阻塞：
    /// WindowShade 停住、管道写满时丢掉这一行，钩子线程不等。
    static func say(_ line: String) {
        logQueue.async {
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        }
    }

    /// 问 WindowShade：这次双击（三击）要不要吞掉。送出最多 0.1 秒，等回话最多 0.4 秒；没回话、出错一律放行。
    static func ask(_ request: TapRequest) -> Bool {
        if remotePort.map({ !CFMessagePortIsValid($0) }) ?? true {
            remotePort = CFMessagePortCreateRemote(nil, portName)
        }
        guard let remotePort else {
            say("pass: WindowShade has no port")
            return false
        }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remotePort, TapProtocol.askMessageID, request.encoded() as CFData,
                                              TapProtocol.sendTimeout, TapProtocol.replyTimeout,
                                              TapProtocol.replyMode as CFString, &reply)
        let data = reply.map { $0.takeRetainedValue() as Data }
        guard Int(status) == Int(kCFMessagePortSuccess) else {
            say("pass: WindowShade did not answer in time status=\(status) clicks=\(request.clicks)")
            return false
        }
        return TapReply.swallow(data)
    }

    static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout:
            // 不该发生（每次最多等 deadline）；发生了就马上接着管，并记下来。
            if let tap = TapHelper.tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
            TapHelper.say("tap: re-enabled after the system disabled it for a timeout")
            return pass
        case .tapDisabledByUserInput:
            // 输入洪泛时系统停用钩子：立刻重开会和系统来回争，过一会儿再开。
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if let tap = TapHelper.tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return pass
        case .leftMouseUp:
            guard TapHelper.swallowNextMouseUp else { return pass }
            TapHelper.swallowNextMouseUp = false
            return nil
        case .leftMouseDown:
            TapHelper.swallowNextMouseUp = false
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            guard clicks >= 2 else { return pass }   // 单击：不问
            let request = TapRequest(point: event.location, clicks: clicks, sentAt: CFAbsoluteTimeGetCurrent())
            guard TapHelper.ask(request) else { return pass }
            TapHelper.swallowNextMouseUp = true
            return nil
        default:
            return pass
        }
    }

    static func run() -> Never {
        // 不用 CommandLine.arguments：Swift 6.0 把它算作共享的可变状态，编不过。
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 3, let parentPID = pid_t(arguments[1]) else {
            FileHandle.standardError.write(Data("usage: WindowShadeTapHelper <pid> <port>\n".utf8))
            exit(64)
        }
        portName = arguments[2] as CFString
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)

        // WindowShade 退出（包括崩溃、被强制结束）就跟着退出：钩子随进程一起撤掉。
        let parentWatch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
        parentWatch.setEventHandler { exit(0) }
        parentWatch.resume()
        if kill(parentPID, 0) != 0 { exit(0) }

        let mask = (CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.leftMouseUp.rawValue))
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { _, type, event, _ in TapHelper.handle(type, event) },
                                          userInfo: nil) else {
            say("tap: cannot create the event tap")
            logQueue.sync {}
            exit(TapProtocol.cannotCreateTapExitCode)
        }
        tapPort = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        say("ready pid=\(getpid())")
        withExtendedLifetime(parentWatch) { CFRunLoopRun() }
        exit(0)
    }
}

TapHelper.run()

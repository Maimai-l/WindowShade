// 和鼠标钩子进程（TapHelper/main.swift）打交道：启动它、回答它的询问、它意外退出就重新启动，
// 实在用不了就改用 WindowShade 自己的钩子（docs/design.md 第 5.9 节）。
//
// 钩子在另一个进程里，WindowShade 停住、卡住都不再挡全系统的点击：钩子进程问不到回话就放行（场景 X11）。

import Cocoa

@MainActor
enum TapHelperLink {
    private static var localPort: CFMessagePort?
    private static var process: Process?
    private static var output: Pipe?
    /// 钩子进程意外退出的时刻：一分钟内退出 3 次就不再启动它。
    private static var recentExits: [CFAbsoluteTime] = []
    /// 不再用钩子进程（建不了钩子、反复退出）：改用 WindowShade 自己的钩子，直到下次启动。
    private static var gaveUp = false
    private static var stopping = false

    /// 钩子进程在运行：全系统的点击由它管。
    static var isRunning: Bool { process != nil }

    private static var helperURL: URL? {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(TapProtocol.helperName),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// 启动钩子进程。返回 false：钩子进程用不了，调用方改用自己的钩子。
    static func start() -> Bool {
        if process != nil { return true }
        guard !gaveUp, !stopping else { return false }
        guard let url = helperURL else {
            wlog("tap-helper: not in the bundle; using the in-process tap")
            gaveUp = true
            return false
        }
        guard openPort() else {
            wlog("tap-helper: cannot open the port; using the in-process tap")
            gaveUp = true
            return false
        }
        let task = Process()
        task.executableURL = url
        task.arguments = [String(getpid()), TapProtocol.portName(appPID: getpid())]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.isEmpty {
                wlog("tap-helper: \(line)")
            }
        }
        task.terminationHandler = { finished in
            let pid = finished.processIdentifier
            let status = finished.terminationStatus
            let bySignal = finished.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TapHelperLink.exited(pid: pid, status: status, bySignal: bySignal) }
            }
        }
        do {
            try task.run()
        } catch {
            wlog("tap-helper: cannot launch (\(error.localizedDescription)); using the in-process tap")
            pipe.fileHandleForReading.readabilityHandler = nil
            gaveUp = true
            return false
        }
        process = task
        output = pipe
        wlog("tap-helper: launched pid=\(task.processIdentifier)")
        return true
    }

    /// 退出 WindowShade 前调用。钩子进程自己也会在 WindowShade 退出后退出，这里只是不等它发现。
    static func stop() {
        stopping = true
        process?.terminate()
    }

    private static func openPort() -> Bool {
        if localPort != nil { return true }
        let name = TapProtocol.portName(appPID: getpid()) as CFString
        guard let port = CFMessagePortCreateLocal(nil, name, tapHelperRequestCallback, nil, nil),
              let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        localPort = port
        return true
    }

    private static func exited(pid: pid_t, status: Int32, bySignal: Bool) {
        guard let current = process, current.processIdentifier == pid else { return }
        process = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        guard !stopping, let delegate = appDelegate else { return }
        let how = bySignal ? "signal \(status)" : "status \(status)"
        if !bySignal, status == TapProtocol.cannotCreateTapExitCode {
            wlog("tap-helper: exited (\(how)) without a tap; using the in-process tap")
            gaveUp = true
            _ = delegate.setupEventTap()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        recentExits = recentExits.filter { now - $0 < 60 } + [now]
        if recentExits.count >= 3 {
            wlog("tap-helper: exited (\(how)) 3 times within a minute; using the in-process tap")
            gaveUp = true
            _ = delegate.setupEventTap()
            return
        }
        wlog("tap-helper: exited (\(how)); launching it again")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { _ = appDelegate?.setupEventTap() }
        }
    }

    /// 钩子进程问：这次双击（三击）要不要吞掉。钩子过了时限就放行了，过时的询问不处理。
    fileprivate static func answer(messageID: Int32, data: Data?) -> Bool {
        guard messageID == TapProtocol.askMessageID, let data, let request = TapRequest(data) else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard TapProtocol.isFresh(sentAt: request.sentAt, now: now) else {
            wlog("tap-helper: question arrived \(Int((now - request.sentAt) * 1000))ms after the click; the click already passed")
            return false
        }
        guard let delegate = appDelegate else { return false }
        if request.clicks >= 3 {
            return delegate.handleTitleBarTripleClick(at: request.point, clickCount: request.clicks)
        }
        return delegate.handleTitleBarDoubleClick(at: request.point)   // 吞掉，阻止系统「双击缩放」
    }
}

/// 端口的运行循环源挂在主线程上，回调也在主线程上。
private func tapHelperRequestCallback(port: CFMessagePort?, messageID: Int32, data: CFData?,
                                      info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    let bytes = data.map { $0 as Data }
    let swallow = MainActor.assumeIsolated { TapHelperLink.answer(messageID: messageID, data: bytes) }
    return Unmanaged.passRetained(TapReply.encoded(swallow: swallow) as CFData)
}

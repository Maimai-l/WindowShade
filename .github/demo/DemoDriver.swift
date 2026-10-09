// CI 演示录屏的驱动：把指定 App（默认文本编辑）的窗口摆好，录下整块屏幕，
// 用合成的鼠标事件双击标题栏收起、停在卷帘条上看一眼、再双击展开。
// 第二个参数是 close-unsaved 时跑场景 E13：关闭一个收起的、有未保存内容的窗口，检查系统输入不被挡住。
// 在 GitHub Actions 的 macOS 机器上跑，也可以用测试包在自己的 Mac 上跑（run-on-this-mac.sh）；不进 App。

import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import ScreenCaptureKit

private let logClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

/// 每行带时刻，便于和 WindowShade 的日志、录像对上。
func log(_ message: String) {
    FileHandle.standardError.write("[driver \(logClock.string(from: Date()))] \(message)\n".data(using: .utf8)!)
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

var pointer = CGPoint(x: 900, y: 600)

func post(_ type: CGEventType, at point: CGPoint, clicks: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    // 不带修饰键：source 为 nil 时事件沿用当前的修饰键状态，前面合成过 ⌃⌥⌘ 的快捷键就会变成 Option、Command 单击
    // （Option 单击别的应用程序会隐藏当前应用程序，Command 单击不激活应用程序；见 docs/testing.md 场景 A34、C13）。
    event.flags = []
    event.post(tap: .cghidEventTap)
}

/// 指针用 0.6 秒滑过去，像人手一样，而不是瞬移。
func glide(to target: CGPoint, duration: Double = 0.6) async {
    let start = pointer
    let steps = max(1, Int(duration * 60))
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let point = CGPoint(x: start.x + (target.x - start.x) * eased,
                            y: start.y + (target.y - start.y) * eased)
        post(.mouseMoved, at: point)
        pointer = point
        await pause(1.0 / 60)
    }
}

func doubleClick(at point: CGPoint) async {
    post(.leftMouseDown, at: point, clicks: 1)
    post(.leftMouseUp, at: point, clicks: 1)
    await pause(0.09)
    post(.leftMouseDown, at: point, clicks: 2)
    post(.leftMouseUp, at: point, clicks: 2)
}

func firstWindow(of bundleID: String) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else { return nil }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first { window in
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXStandardWindowSubrole as String)
    }
}

func place(_ window: AXUIElement, origin: CGPoint, size: CGSize) {
    var origin = origin
    var size = size
    if let value = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }
    if let value = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
}

/// 录下整块屏幕。macOS 15 起用系统的录像输出（SCRecordingOutput）；macOS 14 没有它，
/// 自己把屏幕帧写进 AVAssetWriter（用户的 macOS 14.5 机器上 2026-10-09 编不过，见 docs/testing.md 第 5 节）。
/// SDK 里有没有 SCRecordingOutput 由 record.sh 查头文件决定（DEMO_SDK_HAS_RECORDING_OUTPUT），
/// 和 prototype/build.sh 判断玻璃接口的办法一样：旧 SDK 里连这个类型名都没有，只靠 #available 编不过。
/// 写录像的状态只在 writerQueue 上读写（macOS 14 的写法）。
final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?
    /// ReplayKit 报错时录像文件不完整（没有 moov），record.sh 据此重录一次。
    private(set) var failed = false
    private var recordingDelegate: AnyObject?
    // macOS 14 的写法：屏幕帧在 writerQueue 上逐帧写入。
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false
    /// 录像第一帧的时刻：macOS 14 的录像从这一帧算起，不从开始录像算起。stop() 之后读。
    private(set) var firstFrameAt: Date?
    private let writerQueue = DispatchQueue(label: "demo.recorder.writer")

    func start(to url: URL) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw NSError(domain: "demo", code: 1) }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        var usesRecordingOutput = false
        #if DEMO_SDK_HAS_RECORDING_OUTPUT
        if #available(macOS 15.0, *) {
            let output = SCRecordingOutputConfiguration()
            output.outputURL = url
            output.outputFileType = .mp4
            output.videoCodecType = .h264
            let delegate = RecordingOutputDelegate(recorder: self)
            recordingDelegate = delegate
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: delegate))
            usesRecordingOutput = true
        }
        #endif
        if !usesRecordingOutput {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: configuration.width,
                AVVideoHeightKey: configuration.height,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw NSError(domain: "demo", code: 2) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? NSError(domain: "demo", code: 3) }
            self.writer = writer
            writerInput = input
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        log("recording \(display.width)x\(display.height) to \(url.path)"
            + (usesRecordingOutput ? "" : " (AVAssetWriter, macOS 14)"))
    }

    func stop() async {
        guard let stream else { return }
        guard let writer else {
            await withCheckedContinuation { continuation in
                finished = continuation
                Task { try? await stream.stopCapture() }
            }
            return
        }
        try? await stream.stopCapture()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 排在已经送来的帧后面：写完这些帧再收尾。
            writerQueue.async {
                guard self.sessionStarted, writer.status == .writing else {
                    log("recording failed: no frames were written (status \(writer.status.rawValue))")
                    self.failed = true
                    writer.cancelWriting()
                    continuation.resume()
                    return
                }
                self.writerInput?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        log("recording finished")
                    } else {
                        log("recording failed: \(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")")
                        self.failed = true
                    }
                    continuation.resume()
                }
            }
        }
    }

    /// macOS 14：每一帧写进录像。画面没变时系统送来的是没有图像的空闲帧，跳过。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let input = writerInput,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
            firstFrameAt = Date()
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    fileprivate func recordingFinished(error: Error?) {
        if let error {
            log("recording failed: \(error)")
            failed = true
        } else {
            log("recording finished")
        }
        finished?.resume()
        finished = nil
    }
}

#if DEMO_SDK_HAS_RECORDING_OUTPUT
@available(macOS 15.0, *)
private final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate {
    private weak var recorder: Recorder?

    init(recorder: Recorder) { self.recorder = recorder }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        recorder?.recordingFinished(error: nil)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        recorder?.recordingFinished(error: error)
    }
}
#endif

// MARK: - 场景 E13：关闭一个收起的、有未保存内容的窗口（docs/testing.md 第 4 节）

/// 输入是否还在流动：驱动程序发的探测点击带上标记，一个只听不改、排在所有钩子最后的钩子记下它们到达的时刻。
/// WindowShade 的钩子卡住时，探测点击迟迟到不了这里。
final class InputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived: [Int64: Date] = [:]
    private var tap: CFMachPort?

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, _, event, refcon in
            if let refcon {
                let probe = Unmanaged<InputProbe>.fromOpaque(refcon).takeUnretainedValue()
                let tag = event.getIntegerValueField(.eventSourceUserData)
                if tag != 0 { probe.note(tag) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.start()
        return true
    }

    func note(_ tag: Int64) { lock.withLock { arrived[tag] = Date() } }
    func arrival(_ tag: Int64) -> Date? { lock.withLock { arrived[tag] } }
}

func postTagged(_ type: CGEventType, at point: CGPoint, clicks: Int64, tag: Int64) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.setIntegerValueField(.eventSourceUserData, value: tag)
    event.flags = []
    event.post(tap: .cghidEventTap)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

func axString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return value as? String ?? ""
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func windowTitles(of bundleID: String) -> [String] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                  kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement] ?? []).map { axString($0, kAXTitleAttribute as String) }
}

/// 在文本编辑里新建一个文档并打几个字，让它有未保存的内容。新建经由菜单栏的“新建”（辅助功能）。
func makeUnsavedDocument(_ bundleID: String) async -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
    app.activate()
    await pause(0.8)
    var barRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                        kAXMenuBarAttribute as CFString, &barRef) == .success,
          let barRef else { return false }
    var pressed = false
    outer: for barItem in axChildren(barRef as! AXUIElement) {
        for menu in axChildren(barItem) {
            for item in axChildren(menu) where axString(item, kAXMenuItemCmdCharAttribute as String) == "N" {
                var modifiers: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
                guard (modifiers as? NSNumber)?.intValue == 0 else { continue }
                pressed = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                break outer
            }
        }
    }
    guard pressed else { return false }
    await pause(1.2)
    for character in "Unsaved text for scenario E13." {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            let units = Array(String(character).utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        await pause(0.02)
    }
    await pause(0.5)
    return true
}

/// 收起文本编辑里一个没保存的新文档，点卷帘条上的关闭按钮，在“是否保存”里选删除。
/// 全过程中不停地发探测点击，检查系统的输入没有被挡住。结果写进 json，有一项不合格就以 5 退出。
func closeUnsavedScenario(video: URL) async {
    let bundleID = "com.apple.TextEdit"
    var results: [String: Any] = [:]
    var failures: [String] = []
    let probe = InputProbe()
    guard probe.start() else { log("cannot install the input probe"); exit(2) }

    guard await makeUnsavedDocument(bundleID) else { log("cannot create an unsaved TextEdit document"); exit(2) }
    guard let window = firstWindow(of: bundleID) else { log("no unsaved TextEdit window"); exit(2) }
    let title = axString(window, kAXTitleAttribute as String)
    let origin = CGPoint(x: 160, y: 120)
    let size = CGSize(width: 700, height: 460)
    place(window, origin: origin, size: size)
    await pause(1)
    var closeButtonRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef)
    guard let closeButtonRef, let closeFrame = axFrame(closeButtonRef as! AXUIElement) else {
        log("no close button on \(title)"); exit(2)
    }
    let closeCenter = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
    let screen = CGDisplayBounds(CGMainDisplayID())
    // 探测点击落在桌面的空白处：离开所有窗口，也在程序坞上方。
    let neutral = CGPoint(x: screen.maxX - 200, y: screen.maxY - 200)
    results["window"] = ["title": title, "x": origin.x, "y": origin.y, "w": size.width, "h": size.height]

    let recorder = Recorder()
    do { try await recorder.start(to: video) } catch { log("cannot record: \(error)"); exit(3) }

    var nextTag: Int64 = 0x5e13_0000
    var latencies: [Double] = []
    var lost = 0
    /// 发一次探测点击（单击或双击），等它穿过所有钩子；最多等 2 秒。
    func probeInput(clicks: Int64) async {
        nextTag += 1
        let tag = nextTag
        let sent = Date()
        postTagged(.leftMouseDown, at: neutral, clicks: clicks, tag: tag)
        postTagged(.leftMouseUp, at: neutral, clicks: clicks, tag: 0)
        while Date().timeIntervalSince(sent) < 2 {
            if let arrived = probe.arrival(tag) {
                latencies.append(arrived.timeIntervalSince(sent))
                return
            }
            await pause(0.01)
        }
        lost += 1
    }

    log("fold the unsaved window \(title)")
    let titleBar = CGPoint(x: origin.x + size.width * 0.72, y: origin.y + 14)
    await glide(to: titleBar)
    await pause(0.3)
    await doubleClick(at: titleBar)
    await pause(2.0)
    await probeInput(clicks: 1)

    log("click the close button on the strip at \(closeCenter)")
    await glide(to: closeCenter)
    await pause(0.4)
    post(.leftMouseDown, at: closeCenter)
    post(.leftMouseUp, at: closeCenter)

    var sheet: AXUIElement?
    let asked = Date()
    while sheet == nil, Date().timeIntervalSince(asked) < 4 {
        await pause(0.1)
        sheet = axChildren(window).first { axString($0, kAXRoleAttribute as String) == "AXSheet" }
    }
    results["sheetAppeared"] = sheet != nil
    if sheet == nil { failures.append("the save sheet did not appear within 4 s") }

    // 对话框开着的这段时间正是 2026-10-08 卡死的时候：单击、双击都要能穿过钩子。
    log("probe input while the save sheet is open")
    for clicks: Int64 in [1, 2, 1, 2, 1, 2] {
        await probeInput(clicks: clicks)
        await pause(0.25)
    }
    let sheets = axChildren(window).filter { axString($0, kAXRoleAttribute as String) == "AXSheet" }.count
    results["sheetsWhileOpen"] = sheets
    if sheets > 1 { failures.append("more than one save sheet (\(sheets))") }

    if let sheet {
        // macOS 26 的对话框把按钮放在几层分组里：逐层往下找，不只看直接的子元素。
        func buttons(in element: AXUIElement, depth: Int) -> [AXUIElement] {
            guard depth < 6 else { return [] }
            return axChildren(element).flatMap { child in
                axString(child, kAXRoleAttribute as String) == "AXButton" ? [child] : buttons(in: child, depth: depth + 1)
            }
        }
        func name(_ button: AXUIElement) -> String {
            let title = axString(button, kAXTitleAttribute as String)
            return title.isEmpty ? axString(button, kAXDescriptionAttribute as String) : title
        }
        let found = buttons(in: sheet, depth: 0)
        let names = found.map(name)
        results["sheetButtons"] = names
        let deleteWords = ["Delete", "Don’t Save", "Don't Save", "删除", "不存储"]
        if let delete = found.first(where: { button in deleteWords.contains { name(button).contains($0) } }) {
            log("press \(name(delete)) in the save sheet")
            AXUIElementPerformAction(delete, kAXPressAction as CFString)
        } else {
            failures.append("no delete button in the save sheet (\(names))")
        }
    }

    let pressed = Date()
    var closed = false
    while !closed, Date().timeIntervalSince(pressed) < 3 {
        await pause(0.1)
        closed = !windowTitles(of: bundleID).contains(title)
    }
    results["windowClosed"] = closed
    if !closed { failures.append("the window \(title) is still open 3 s after Delete") }
    await probeInput(clicks: 2)
    await pause(1.0)
    await recorder.stop()

    results["probeLatencies"] = latencies
    results["probesLost"] = lost
    let worst = latencies.max() ?? 0
    results["probeWorstLatency"] = worst
    if lost > 0 { failures.append("\(lost) probe click(s) never got through the event taps") }
    // WindowShade 的钩子最多等主线程 0.4 秒（Core/TapDecision.swift），再留出虚拟机的余量。
    if worst > 1.0 { failures.append("a probe click took \(worst) s to get through the event taps") }
    results["failures"] = failures
    results["passed"] = failures.isEmpty
    let resultURL = video.deletingPathExtension().appendingPathExtension("json")
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: resultURL)
    }
    log(failures.isEmpty ? "close-unsaved passed" : "close-unsaved failed: \(failures)")
    exit(failures.isEmpty ? (recorder.failed ? 4 : 0) : 5)
}

/// 在自己的 Mac 上跑之前的检查（.github/demo/run-on-this-mac.sh）：驱动程序的权限、是否登录在桌面、
/// 屏幕是否锁着、有没有显示器。缺的权限请求一次，系统就把驱动程序列进系统设置的名单，用户只需打开开关。
func preflight() -> Never {
    var missing: [String] = []
    if !AXIsProcessTrusted() {
        missing.append("辅助功能")
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    if !CGPreflightScreenCaptureAccess() {
        missing.append("录屏与系统录音")
        _ = CGRequestScreenCaptureAccess()
    }
    if !CGPreflightListenEventAccess() {
        missing.append("输入监控")
        _ = CGRequestListenEventAccess()
    }
    if !CGPreflightPostEventAccess() {
        if !missing.contains("辅助功能") { missing.append("辅助功能") }
        _ = CGRequestPostEventAccess()
    }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool ?? false
    let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
    let screens = NSScreen.screens.count
    print("preflight driver-missing=\(missing.joined(separator: ",")) on-console=\(onConsole) locked=\(locked) screens=\(screens)")
    exit(missing.isEmpty && onConsole && !locked && screens > 0 ? 0 : 1)
}

@main
struct DemoDriver {
    static func main() async {
        // 参数：视频路径 [App 的 bundle id] [窗口宽] [窗口高] [双击点离窗口上沿的距离]
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "preflight" { preflight() }
        // 跑完以后把外观改回用户原来的深色或浅色（场景 E05 最后停在浅色）。
        if args.count == 2, args[0] == "appearance" {
            exit(setDarkMode(args[1] == "dark") ? 0 : 1)
        }
        let video = URL(fileURLWithPath: args.first ?? "/tmp/demo.mp4")
        if args.count > 1, args[1] == "close-unsaved" {
            await closeUnsavedScenario(video: video)
            return
        }
        // scenarios：逐条场景和不变式检查（Scenarios*.swift）。参数：ProbeApp.app 路径、WindowShade.app 路径，
        // 可选的逗号分隔场景编号，或者 shard:i/n（只跑主组里序号除以 n 余 i 的场景，供 CI 分成几个任务并行）。
        if args.count > 3, args[1] == "scenarios" {
            var only: Set<String>?
            var shard: (index: Int, count: Int)?
            if args.count > 4 {
                if args[4].hasPrefix("shard:") {
                    let parts = args[4].dropFirst(6).split(separator: "/").compactMap { Int($0) }
                    if parts.count == 2, parts[1] > 0 { shard = (parts[0], parts[1]) }
                } else {
                    only = Set(args[4].split(separator: ",").map(String.init))
                }
            }
            await runScenarioSuite(output: video, probeApp: args[2], shadeApp: args[3], only: only, shard: shard)
            return
        }
        let bundleID = args.count > 1 ? args[1] : "com.apple.TextEdit"
        let size = CGSize(width: args.count > 2 ? Double(args[2]) ?? 700 : 700,
                          height: args.count > 3 ? Double(args[3]) ?? 460 : 460)
        let barY = args.count > 4 ? Double(args[4]) ?? 14 : 14
        log("accessibility trusted: \(AXIsProcessTrusted()), screen capture: \(CGPreflightScreenCaptureAccess())")

        var window: AXUIElement?
        for _ in 0..<40 {
            window = firstWindow(of: bundleID)
            if window != nil { break }
            await pause(0.25)
        }
        guard let window else { log("no \(bundleID) window"); exit(2) }
        let origin = CGPoint(x: 160, y: 120)
        place(window, origin: origin, size: size)
        await pause(1)

        let recorder = Recorder()
        do { try await recorder.start(to: video) } catch { log("cannot record: \(error)"); exit(3) }
        // 双击的时刻（从开始录像算起的秒数），连同窗口位置一起写给逐帧检查（.github/demo/check_frames.py）。
        let recordingStarted = Date()
        var events: [String: Any] = [
            "window": ["x": origin.x, "y": origin.y, "w": size.width, "h": size.height],
            "screen": ["w": CGDisplayBounds(CGMainDisplayID()).width, "h": CGDisplayBounds(CGMainDisplayID()).height],
            "scale": 2,
        ]
        func mark(_ name: String) { events[name] = Date().timeIntervalSince(recordingStarted) }
        await pause(1.5)

        // 标题栏上靠右的一点：避开中间的标题文字和左边的红绿灯；有工具栏的窗口点在按钮上面的空白。
        let titleBar = CGPoint(x: origin.x + size.width * 0.72, y: origin.y + barY)
        log("double-click title bar at \(titleBar)")
        await glide(to: titleBar)
        await pause(0.3)
        mark("fold")
        await doubleClick(at: titleBar)
        await pause(2.0)

        log("move away, then rest on the strip to glance")
        await glide(to: CGPoint(x: origin.x + size.width * 0.5, y: origin.y + 340))
        await pause(1.0)
        await glide(to: titleBar)
        await pause(3.0)

        log("move away so the glance rolls back up")
        await glide(to: CGPoint(x: origin.x + size.width + 120, y: origin.y + 260))
        await pause(1.5)

        log("double-click the strip to unroll")
        await glide(to: titleBar)
        await pause(0.4)
        mark("unfold")
        await doubleClick(at: titleBar)
        await pause(2.5)

        await recorder.stop()
        // macOS 14 的录像从第一帧算起：双击的时刻跟着挪，逐帧检查才对得上画面
        // （2026-10-09 本机运行：没挪时检查说双击后 2.4 秒内窗口没变）。
        if let first = recorder.firstFrameAt {
            let offset = first.timeIntervalSince(recordingStarted)
            for name in ["fold", "unfold"] {
                if let at = events[name] as? Double { events[name] = at - offset }
            }
            events["firstFrameOffset"] = offset
            log("first frame \(Int(offset * 1000))ms after the recording started")
        }
        let eventsURL = video.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: eventsURL)
        }
        log("done")
        exit(recorder.failed ? 4 : 0)
    }
}

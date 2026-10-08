// 不变式检查器和逐条场景（docs/test-catalog.md 第 1、10 节）。与 DemoDriver.swift 一起编译。
//
// 每个场景结束时检查全部不变式：
//   I1 不丢窗口   I2 不挡输入（探测点击 1 秒内穿过所有钩子）   I3 不合成输入（没有来自 WindowShade 进程的事件）
//   I4 不可撤销的动作至多一次   I5 状态转换合法   I6 主线程单次阻塞不超过 500 毫秒   I9 WindowShade 没有退出
// 结果写进 scenarios.json，record.sh 据此判定 CI 是否通过。

import AppKit
import ApplicationServices

let windowShadeBundleID = "com.windowshade.prototype"
let windowShadeLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/WindowShade/windowshade.log")

// MARK: - 事件旁听（I2、I3）

/// 排在所有钩子之后、只听不改的钩子：记下探测点击的到达时刻（I2），以及来自 WindowShade 进程的任何事件（I3）。
final class EventAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived: [Int64: Date] = [:]
    private var fromWatched: [String] = []
    private var watched: pid_t = 0
    private var tap: CFMachPort?

    func watch(_ pid: pid_t) { lock.withLock { watched = pid } }

    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved,
                                    .leftMouseDragged, .rightMouseDragged, .keyDown, .keyUp, .flagsChanged,
                                    .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
            if let refcon {
                Unmanaged<EventAudit>.fromOpaque(refcon).takeUnretainedValue().observe(type, event)
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

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        let source = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let tag = event.getIntegerValueField(.eventSourceUserData)
        lock.withLock {
            if tag != 0, type == .leftMouseDown { arrived[tag] = Date() }
            if watched != 0, source == watched { fromWatched.append("type=\(type.rawValue)") }
        }
    }

    func arrival(_ tag: Int64) -> Date? { lock.withLock { arrived[tag] } }

    /// 取走到现在为止记下的、来自 WindowShade 的事件。
    func takeSynthetic() -> [String] {
        lock.withLock {
            defer { fromWatched.removeAll() }
            return fromWatched
        }
    }
}

// MARK: - WindowShade 的日志和窗口

/// 从场景开始时的位置往后读 WindowShade 的日志。
struct LogTail {
    private var offset: UInt64

    init() {
        offset = (try? FileManager.default.attributesOfItem(atPath: windowShadeLog.path)[.size] as? UInt64) ?? 0
    }

    func lines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: windowShadeLog) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

func windowShadePID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: windowShadeBundleID).first?.processIdentifier
}

/// 屏幕上 WindowShade 的卷帘条（高度不超过 60 点、宽于 100 点的 WindowShade 窗口）。
func stripFrames() -> [CGRect] {
    guard let pid = windowShadePID(),
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    return list.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.height <= 60, rect.width > 100 else { return nil }
        return rect
    }
}

// MARK: - ProbeApp

/// 一个 ProbeApp 进程：启动、发命令、读它记下的事件。
final class Probe {
    let pid: pid_t
    private let eventsPath: String

    private init(pid: pid_t, eventsPath: String) {
        self.pid = pid
        self.eventsPath = eventsPath
    }

    static func launch(_ appPath: String, name: String, options: [String]) async -> Probe? {
        let eventsPath = NSTemporaryDirectory() + "probe-\(name)-\(UUID().uuidString).jsonl"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", appPath, "--args", "--events=\(eventsPath)"] + options
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        for _ in 0..<60 {
            await pause(0.1)
            if let launched = readEvents(eventsPath).first(where: { $0["event"] as? String == "launched" }),
               let pid = (launched["pid"] as? NSNumber)?.int32Value {
                await pause(0.8)
                return Probe(pid: pid, eventsPath: eventsPath)
            }
        }
        return nil
    }

    private static func readEvents(_ path: String) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    func events() -> [[String: Any]] { Self.readEvents(eventsPath) }
    func count(_ event: String) -> Int { events().filter { $0["event"] as? String == event }.count }

    func send(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.windowshade.probe.command"), object: command, userInfo: nil, deliverImmediately: true)
    }

    func window(_ title: String = "Probe 1") -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return (value as? [AXUIElement] ?? []).first { axString($0, kAXTitleAttribute as String).hasPrefix(title) }
    }

    var isRunning: Bool { kill(pid, 0) == 0 }

    func forceQuit() { kill(pid, SIGKILL) }
}

// MARK: - 场景和不变式

struct ScenarioResult {
    let id: String
    let title: String
    var violations: [String] = []
    var notes: [String: Any] = [:]

    var json: [String: Any] {
        ["id": id, "title": title, "passed": violations.isEmpty, "violations": violations, "notes": notes]
    }
}

/// 一个场景运行时的状态：探测点击、日志、违反了哪些不变式。
final class Harness {
    let audit: EventAudit
    let probeApp: String
    let neutral: CGPoint
    var result: ScenarioResult
    private let log = LogTail()
    private var nextTag: Int64
    private var latencies: [Double] = []

    init(id: String, title: String, audit: EventAudit, probeApp: String, tagBase: Int64) {
        self.audit = audit
        self.probeApp = probeApp
        let screen = CGDisplayBounds(CGMainDisplayID())
        neutral = CGPoint(x: screen.maxX - 200, y: screen.maxY - 200)
        result = ScenarioResult(id: id, title: title)
        nextTag = tagBase
        _ = audit.takeSynthetic()
    }

    func expect(_ condition: Bool, _ message: String) {
        if !condition { result.violations.append(message) }
    }

    /// I2：发一次探测点击（单击或双击）到桌面空白处，等它穿过所有钩子，最多 2 秒。
    func probeInput(clicks: Int64 = 1) async {
        nextTag += 1
        let tag = nextTag
        let sent = Date()
        postTagged(.leftMouseDown, at: neutral, clicks: clicks, tag: tag)
        postTagged(.leftMouseUp, at: neutral, clicks: clicks, tag: 0)
        while Date().timeIntervalSince(sent) < 2 {
            if let arrived = audit.arrival(tag) {
                let latency = arrived.timeIntervalSince(sent)
                latencies.append(latency)
                expect(latency <= 1.0, "I2: a probe click took \(String(format: "%.2f", latency)) s to get through the event taps")
                return
            }
            await pause(0.01)
        }
        result.violations.append("I2: a probe click (clicks=\(clicks)) never got through the event taps")
    }

    /// 连续探测，覆盖一段时间。
    func probeFor(_ seconds: Double) async {
        let start = Date()
        var clicks: Int64 = 1
        while Date().timeIntervalSince(start) < seconds {
            await probeInput(clicks: clicks)
            clicks = clicks == 1 ? 2 : 1
            await pause(0.25)
        }
    }

    func logLines() -> [String] { log.lines() }

    /// 等日志里出现某一行，最多等 timeout 秒。
    func waitForLog(_ fragment: String, timeout: Double) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if log.lines().contains(where: { $0.contains(fragment) }) { return true }
            await pause(0.1)
        }
        return false
    }

    /// 场景结束时都要成立的不变式：I3、I5、I6、I9。
    func finish() -> ScenarioResult {
        for event in Set(audit.takeSynthetic()) {
            result.violations.append("I3: WindowShade posted an input event (\(event))")
        }
        let lines = log.lines()
        for line in lines where line.contains("illegal transition") {
            result.violations.append("I5: \(line)")
        }
        for line in lines {
            guard let range = line.range(of: #"main-thread stall ≈(\d+)ms"#, options: .regularExpression) else { continue }
            let digits = line[range].filter(\.isNumber)
            if let ms = Int(digits), ms > 500 { result.violations.append("I6: \(line)") }
        }
        if windowShadePID() == nil { result.violations.append("I9: WindowShade is not running") }
        result.notes["probeLatencies"] = latencies
        result.notes["probeWorstLatency"] = latencies.max() ?? 0
        return result
    }
}

// MARK: - 共用的操作

let probeOrigin = CGPoint(x: 160, y: 140)
let probeSize = CGSize(width: 640, height: 420)

/// 收起前记下的东西：窗口、位置、标题栏上的双击点、关闭按钮的中心（卷帘条上的按钮和它对齐）。
struct Folded {
    let window: AXUIElement
    let frame: CGRect
    let titleBar: CGPoint
    let close: CGPoint?
}

/// 摆好窗口，记下收起前的位置，双击标题栏收起，等日志里出现这次收起。
func foldProbe(_ probe: Probe, _ harness: Harness) async -> Folded? {
    guard let window = probe.window() else {
        harness.result.violations.append("setup: no Probe window")
        return nil
    }
    place(window, origin: probeOrigin, size: probeSize)
    await pause(0.6)
    guard let frame = axFrame(window) else { return nil }
    let titleBar = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
    let close = closeButtonCenter(window)
    await glide(to: titleBar, duration: 0.3)
    await pause(0.2)
    await doubleClick(at: titleBar)
    let folded = await harness.waitForLog(">>> shade", timeout: 3)
    harness.expect(folded, "setup: the Probe window did not fold")
    await pause(1.2)
    await glide(to: harness.neutral, duration: 0.3)
    return Folded(window: window, frame: frame, titleBar: titleBar, close: close)
}

/// I1：窗口回到收起前的位置和大小（误差 2 点），应用程序没有隐藏。
func expectRestored(_ probe: Probe, _ frame: CGRect, _ harness: Harness, within seconds: Double) async {
    let start = Date()
    var last: CGRect?
    while Date().timeIntervalSince(start) < seconds {
        if let window = probe.window(), let now = axFrame(window) {
            last = now
            let hidden = NSRunningApplication(processIdentifier: probe.pid)?.isHidden ?? false
            if abs(now.minX - frame.minX) <= 2, abs(now.minY - frame.minY) <= 2,
               abs(now.width - frame.width) <= 2, abs(now.height - frame.height) <= 2, !hidden { return }
        }
        await pause(0.2)
    }
    harness.result.violations.append("I1: the window is not back at \(frame) after \(seconds) s (now \(last.map { "\($0)" } ?? "unknown"))")
}

/// 卷帘条在 seconds 秒内消失。
func expectNoStrip(_ harness: Harness, within seconds: Double) async {
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        if stripFrames().isEmpty { return }
        await pause(0.2)
    }
    harness.result.violations.append("I1: a strip is still on screen after \(seconds) s (\(stripFrames()))")
}

/// 在 AX 树里逐层找标题含 name 的按钮。
func findButton(_ element: AXUIElement, _ name: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 7 else { return nil }
    for child in axChildren(element) {
        if axString(child, kAXRoleAttribute as String) == "AXButton",
           axString(child, kAXTitleAttribute as String).contains(name) { return child }
        if let found = findButton(child, name, depth: depth + 1) { return found }
    }
    return nil
}

func closeButtonCenter(_ window: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &ref) == .success,
          let ref, let frame = axFrame(ref as! AXUIElement) else { return nil }
    return CGPoint(x: frame.midX, y: frame.midY)
}

func click(_ point: CGPoint) async {
    await glide(to: point, duration: 0.3)
    await pause(0.3)
    post(.leftMouseDown, at: point)
    post(.leftMouseUp, at: point)
}

// MARK: - 场景

struct Scenario {
    let id: String
    let title: String
    let options: [String]
    let run: (Probe, Harness) async -> Void
}

let scenarios: [Scenario] = [
    Scenario(id: "X01", title: "应用程序卡住 3 秒时双击卷帘条展开", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        probe.send("freeze:3")
        await pause(0.3)
        await doubleClick(at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await h.probeFor(3)
        await expectRestored(probe, folded.frame, h, within: 6)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "X02", title: "应用程序一直卡住时展开，然后被强制结束", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        probe.send("freeze:60")
        await pause(0.3)
        await doubleClick(at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await h.probeFor(4)
        probe.forceQuit()
        await expectNoStrip(h, within: 4)
        await h.probeFor(1)
    },
    Scenario(id: "X03", title: "点卷帘条上的关闭按钮，应用程序弹出独立的提示框", options: ["--alert-on-close"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard let close = folded.close else { h.result.violations.append("setup: no close button"); return }
        await click(close)
        await glide(to: h.neutral, duration: 0.2)
        var shown = false
        for _ in 0..<40 where !shown {
            await pause(0.1)
            shown = probe.count("alert-shown") > 0
        }
        h.expect(shown, "C04/X03: the alert did not appear within 4 s")
        await h.probeFor(2)
        h.expect(probe.count("alert-shown") == 1, "I4: the alert appeared \(probe.count("alert-shown")) times")
        if let button = findButton(AXUIElementCreateApplication(probe.pid), "Close Window") {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        } else if shown {
            h.result.violations.append("setup: no Close Window button in the alert")
        }
        var closed = false
        for _ in 0..<30 where !closed {
            await pause(0.1)
            closed = probe.count("closed") > 0
        }
        h.expect(closed, "C04/X03: the window did not close after the alert")
        h.expect(probe.count("close-request") == 1, "I4: close was requested \(probe.count("close-request")) times")
        let forwarded = h.logLines().filter { $0.contains("traffic: close forwarded") }.count
        h.expect(forwarded == 1, "I4: WindowShade forwarded close \(forwarded) times")
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "X04", title: "按下关闭的请求超时，但应用程序随后关掉了窗口", options: ["--slow-close=1.5"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard let close = folded.close else { h.result.violations.append("setup: no close button"); return }
        await click(close)
        await glide(to: h.neutral, duration: 0.2)
        await h.probeFor(3)
        var closed = false
        for _ in 0..<30 where !closed {
            await pause(0.1)
            closed = probe.count("closed") > 0
        }
        h.expect(closed, "X04: the window did not close")
        h.expect(probe.count("close-request") == 1, "I4: close was requested \(probe.count("close-request")) times")
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "X05", title: "窗口没有红绿灯按钮：点卷帘条左端，再双击展开", options: ["--no-buttons"]) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await click(CGPoint(x: folded.frame.minX + 23, y: folded.frame.minY + 14))
        await glide(to: h.neutral, duration: 0.2)
        await h.probeFor(1.5)
        h.expect(probe.count("closed") == 0 && probe.count("minimized") == 0,
                 "X05: a click on the strip closed or minimized a window without buttons")
        await doubleClick(at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 2)
    },
    Scenario(id: "P01", title: "收起后应用程序正常退出", options: []) { probe, h in
        guard await foldProbe(probe, h) != nil else { return }
        probe.send("quit")
        await expectNoStrip(h, within: 4)
        await h.probeFor(1)
    },
    Scenario(id: "P02", title: "收起后应用程序崩溃", options: []) { probe, h in
        guard await foldProbe(probe, h) != nil else { return }
        probe.send("crash")
        await expectNoStrip(h, within: 4)
        await h.probeFor(1)
    },
    Scenario(id: "A22", title: "1 秒内连续双击标题栏 5 次", options: []) { probe, h in
        guard let window = probe.window() else { return }
        place(window, origin: probeOrigin, size: probeSize)
        await pause(0.6)
        guard let frame = axFrame(window) else { return }
        let titleBar = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
        await glide(to: titleBar, duration: 0.3)
        for _ in 0..<5 {
            await doubleClick(at: titleBar)
            await pause(0.12)
        }
        await glide(to: h.neutral, duration: 0.2)
        await pause(3)
        let strips = stripFrames().count
        // 稳定状态只有两种：收起（一条卷帘条），或展开（没有卷帘条、窗口在原处）。
        if strips == 0 {
            await expectRestored(probe, frame, h, within: 2)
        } else {
            h.expect(strips == 1, "A22: \(strips) strips on screen")
            await doubleClick(at: titleBar)
            await glide(to: h.neutral, duration: 0.2)
            await expectRestored(probe, frame, h, within: 4)
        }
        await h.probeFor(1)
    },
    Scenario(id: "B16", title: "收起后连续双击卷帘条 5 次", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        let frame = folded.frame
        let titleBar = folded.titleBar
        await glide(to: titleBar, duration: 0.3)
        for _ in 0..<5 {
            await doubleClick(at: titleBar)
            await pause(0.12)
        }
        await glide(to: h.neutral, duration: 0.2)
        await pause(3)
        let strips = stripFrames().count
        if strips == 0 {
            await expectRestored(probe, frame, h, within: 2)
        } else {
            h.expect(strips == 1, "B16: \(strips) strips on screen")
            await doubleClick(at: titleBar)
            await glide(to: h.neutral, duration: 0.2)
            await expectRestored(probe, frame, h, within: 4)
        }
        await h.probeFor(1)
    },
]

/// 逐条运行场景，每条用一个新的 ProbeApp；结果写进 json。有一条不合格就以 6 退出。
func runScenarioSuite(output: URL, probeApp: String, only: Set<String>?) async {
    let audit = EventAudit()
    guard audit.start() else { log("cannot install the event audit tap"); exit(2) }
    guard let shadePID = windowShadePID() else { log("WindowShade is not running"); exit(2) }
    audit.watch(shadePID)

    let recorder = Recorder()
    do { try await recorder.start(to: output.deletingPathExtension().appendingPathExtension("mp4")) }
    catch { log("cannot record: \(error)") }

    var results: [[String: Any]] = []
    var failed = 0
    for (index, scenario) in scenarios.enumerated() where only?.contains(scenario.id) ?? true {
        log("scenario \(scenario.id): \(scenario.title)")
        let harness = Harness(id: scenario.id, title: scenario.title, audit: audit, probeApp: probeApp,
                              tagBase: Int64(0x5e00_0000 + index * 0x1000))
        if let probe = await Probe.launch(probeApp, name: scenario.id, options: scenario.options) {
            await scenario.run(probe, harness)
            if probe.isRunning { probe.forceQuit() }
            await pause(1.0)
        } else {
            harness.result.violations.append("setup: ProbeApp did not start")
        }
        let result = harness.finish()
        if !result.violations.isEmpty { failed += 1 }
        log("scenario \(scenario.id): \(result.violations.isEmpty ? "passed" : "failed \(result.violations)")")
        results.append(result.json)
    }

    await recorder.stop()
    let summary: [String: Any] = ["scenarios": results, "failed": failed]
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output)
    }
    exit(failed == 0 ? 0 : 6)
}

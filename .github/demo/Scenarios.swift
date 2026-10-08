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
              rect.height <= 60, rect.width > 100,
              // 还没显示出来的卷帘条（等“已藏好”确认时是透明的）不算：点它会穿过去（2026-10-08 A05）。
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05 else { return nil }
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
        // CI 虚拟机忙的时候启动一个应用程序可能要好几秒：等到 15 秒。
        for _ in 0..<150 {
            await pause(0.1)
            if let launched = readEvents(eventsPath).first(where: { $0["event"] as? String == "launched" }),
               let pid = (launched["pid"] as? NSNumber)?.int32Value {
                await pause(0.8)
                let probe = Probe(pid: pid, eventsPath: eventsPath)
                await probe.bringToFront()
                return probe
            }
        }
        log("ProbeApp \(name) did not report launched; running ProbeApps: "
            + "\(NSRunningApplication.runningApplications(withBundleIdentifier: "com.windowshade.probe").map(\.processIdentifier))")
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

    /// 命令只发给这一个 ProbeApp：通知是广播的，不带进程号时同时运行的 ProbeApp 都会执行
    /// （2026-10-08 P07 让一个卡住，结果两个都卡住了）。
    func send(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.windowshade.probe.command"), object: command,
            userInfo: ["pid": String(pid)], deliverImmediately: true)
    }

    func window(_ title: String = "Probe 1") -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return (value as? [AXUIElement] ?? []).first { axString($0, kAXTitleAttribute as String).hasPrefix(title) }
    }

    var isRunning: Bool { kill(pid, 0) == 0 }

    func forceQuit() { kill(pid, SIGKILL) }

    /// 让 ProbeApp 成为当前应用程序、第一扇窗口在最上面：前面的场景留下的文本编辑、访达窗口可能盖在它上面，
    /// 双击会落到别的窗口上。用辅助功能设置（驱动程序是后台应用程序，激活别的应用程序可能被系统拒绝）。
    func bringToFront() async {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = window() { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        _ = await eventually(2) { frontmostPID() == pid }
    }
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

    /// 场景失败时记下当时的样子：截图、当前应用程序、屏幕上的窗口、这段时间 WindowShade 的日志。
    func diagnose(_ probe: Probe? = nil) {
        guard result.notes["diagnosis"] == nil else { return }
        let shot = "\(Suite.outputDir)/fail-\(result.id).png"
        run("/usr/sbin/screencapture", ["-x", shot])
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                        as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) < 1000 }
            .prefix(20)
            .map { info -> String in
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let name = info[kCGWindowName as String] as? String ?? ""
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                return "\(owner) \"\(name)\" layer=\(layer) \(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))x\(Int(bounds.height))"
            }
        result.notes["diagnosis"] = [
            "screenshot": shot,
            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
            "windows": Array(windows),
            "log": Array(log.lines().suffix(40)),
            "probeEvents": (probe?.events().suffix(20) ?? []).map { event in
                event.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            },
        ] as [String: Any]
    }

    /// 等日志里出现某一行，最多等 timeout 秒。
    func waitForLog(_ fragment: String, timeout: Double) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if log.lines().contains(where: { $0.contains(fragment) }) { return true }
            await pause(0.1)
        }
        return false
    }

    /// I3：被监视的进程（WindowShade）发出的输入事件，每种一条。检查的检查（K01）直接调用它。
    static func inputViolations(_ synthetic: [String]) -> [String] {
        Set(synthetic).sorted().map { "I3: WindowShade posted an input event (\($0))" }
    }

    /// I5、I6：日志里的非法状态转换、超过 500 毫秒的主线程停顿。检查的检查（K04）直接调用它。
    static func logViolations(_ lines: [String]) -> [String] {
        var violations: [String] = []
        for line in lines where line.contains("illegal transition") {
            violations.append("I5: \(line)")
        }
        for line in lines {
            guard let range = line.range(of: #"main-thread stall ≈(\d+)ms"#, options: .regularExpression) else { continue }
            let digits = line[range].filter(\.isNumber)
            if let ms = Int(digits), ms > 500 { violations.append("I6: \(line)") }
        }
        return violations
    }

    /// I4：不可撤销的动作（关闭、退出、弹出对话框）正好一次。检查的检查（K03）直接调用它。
    static func onceViolation(_ what: String, _ count: Int) -> String? {
        count == 1 ? nil : "I4: \(what) \(count) times"
    }

    func expectOnce(_ what: String, _ count: Int) {
        if let violation = Self.onceViolation(what, count) { result.violations.append(violation) }
    }

    /// 场景结束时都要成立的不变式：I3、I5、I6、I9。
    func finish() -> ScenarioResult {
        result.violations += Self.inputViolations(audit.takeSynthetic())
        result.violations += Self.logViolations(log.lines())
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
    await probe.bringToFront()
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

// MARK: - 驱动 WindowShade：重启、快捷键、菜单

/// 整个场景套件共用：两个 App 的路径，以及场景结束后要恢复的 WindowShade 设置。
enum Suite {
    /// 结果、失败截图放在这里（和 scenarios.json 同一目录）。
    nonisolated(unsafe) static var outputDir = ""
    nonisolated(unsafe) static var probeApp = ""
    nonisolated(unsafe) static var shadeApp = ""
    nonisolated(unsafe) static var audit: EventAudit?
}

/// 快捷键（Carbon 修饰键：Command 256、Shift 512、Option 2048、Control 4096）。
let controlOptionCommand: (carbon: Int, flags: CGEventFlags) = (6400, [.maskControl, .maskAlternate, .maskCommand])
let toggleKey: CGKeyCode = 40     // K
let arrangeKey: CGKeyCode = 38    // J

/// 套件开头写进 WindowShade 的设置：两个快捷键、按编号展开。每次重启都带上。
let baselineDefaults: [[String]] = [
    ["GlobalShortcut.toggleShade", "-array", "-integer", "\(toggleKey)", "-integer", "\(controlOptionCommand.carbon)"],
    ["GlobalShortcut.arrangeOrFocus", "-array", "-integer", "\(arrangeKey)", "-integer", "\(controlOptionCommand.carbon)"],
    ["GlobalShortcut.numberedExpand", "-bool", "true"],
    ["GlanceEnabled", "-bool", "true"],
    ["ShadeTitlebarDoubleClickEnabled", "-bool", "true"],
    ["ShadeAppearanceMode", "-string", "nativeScreenshot"],
    ["ShadeFloatingOnTop", "-bool", "true"],
    ["ShadeOnboardingShown", "-bool", "true"],
]

/// 运行一个命令行工具，最多等 timeout 秒：`open -a` 遇到启动时停住的应用程序会一直不返回
/// （2026-10-08 A33-Chrome 让整个分片停了 19 分钟），到时就结束它，场景按自己的检查判定。
func run(_ tool: String, _ arguments: [String], timeout: Double = 30) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        log("\(tool) \(arguments.joined(separator: " ")) did not finish within \(Int(timeout)) s; terminated")
        process.terminate()
    }
}

/// 系统自己弹出来、盖在测试窗口上的东西：“从互联网下载的应用程序”确认框（CoreServicesUIAgent）、
/// 提示（Tips）的使用手册窗口。2026-10-08 打开 Chrome 时弹出确认框，之后 13 个场景的标题栏都被它盖住，双击收不起来。
func clearSystemPopups() {
    let onScreenOwners = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { $0[kCGWindowOwnerName as String] as? String })
    // 确认框只结束进程会被系统重新弹出来：先按它的“取消”。
    if onScreenOwners.contains("CoreServicesUIAgent"),
       let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.coreservices.uiagent").first,
       let cancel = findElement(AXUIElementCreateApplication(agent.processIdentifier), maxDepth: 8, {
           axString($0, kAXRoleAttribute as String) == "AXButton"
               && ["取消", "Cancel"].contains(axString($0, kAXTitleAttribute as String))
       }) {
        log("pressing Cancel on CoreServicesUIAgent's dialog")
        AXUIElementPerformAction(cancel, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.5)
    }
    let stillOnScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { $0[kCGWindowOwnerName as String] as? String })
    for name in ["CoreServicesUIAgent", "Tips"] where onScreenOwners.contains(name) && stillOnScreen.contains(name) {
        log("closing \(name), which has a window on screen")
        run("/usr/bin/killall", [name], timeout: 5)
    }
}

/// 场景看门狗：一个场景超过 limit 秒还没结束（驱动程序自己停在某个同步调用里），
/// 截一张图，把已有结果连同这一条“没有结束”写进结果文件，然后退出，不让整个任务等到超时。
final class ScenarioWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[String: Any]] = []
    private var failed = 0
    private var current: (id: String, title: String, startedAt: Date, limit: TimeInterval)?
    private let output: URL

    init(output: URL) {
        self.output = output
        let thread = Thread { [weak self] in
            while let self {
                Thread.sleep(forTimeInterval: 5)
                self.check()
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func begin(_ id: String, _ title: String, limit: TimeInterval) {
        lock.withLock { current = (id, title, Date(), limit) }
    }

    func end(results: [[String: Any]], failed: Int) {
        lock.withLock { self.results = results; self.failed = failed; current = nil }
    }

    private func check() {
        let hung: (results: [[String: Any]], failed: Int, id: String, title: String, limit: TimeInterval)? = lock.withLock {
            guard let current, Date().timeIntervalSince(current.startedAt) > current.limit else { return nil }
            return (results, failed, current.id, current.title, current.limit)
        }
        guard let hung else { return }
        let shot = "\(Suite.outputDir)/fail-\(hung.id).png"
        run("/usr/sbin/screencapture", ["-x", shot], timeout: 10)
        let violation = "setup: the scenario did not finish within \(Int(hung.limit)) s (the driver is blocked)"
        let entry: [String: Any] = ["id": hung.id, "title": hung.title, "passed": false, "violations": [violation],
                                    "notes": ["diagnosis": ["screenshot": shot,
                                                            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"]]]
        writeSuite(hung.results + [entry], failed: hung.failed + 1, finished: false, to: output)
        log("scenario \(hung.id): \(violation); stopping the shard")
        exit(7)
    }
}

func writeDefaults(_ entries: [[String]], domain: String = windowShadeBundleID) {
    for entry in entries { run("/usr/bin/defaults", ["write", domain] + entry) }
}

/// 从菜单栏里 WindowShade 的菜单按下标题含 fragment 的一项（辅助功能）。找不到返回 false。
@discardableResult
func pressWindowShadeMenu(_ fragment: String) async -> Bool {
    guard let pid = windowShadePID() else { return false }
    let app = AXUIElementCreateApplication(pid)
    var extras: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
          let extras, let item = axChildren(extras as! AXUIElement).first else { return false }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    await pause(0.4)
    func search(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        guard depth < 4 else { return nil }
        for child in axChildren(element) {
            if axString(child, kAXRoleAttribute as String) == "AXMenuItem",
               axString(child, kAXTitleAttribute as String).contains(fragment) { return child }
            if let found = search(child, depth + 1) { return found }
        }
        return nil
    }
    guard let target = search(item, 0) else {
        AXUIElementPerformAction(item, kAXCancelAction as CFString)
        post(.keyDown, key: 53)
        return false
    }
    AXUIElementPerformAction(target, kAXPressAction as CFString)
    await pause(0.4)
    return true
}

/// 发一个按键（驱动程序自己合成；WindowShade 不合成任何输入）。
func post(_ type: CGEventType, key: CGKeyCode, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func pressKey(_ key: CGKeyCode, _ flags: CGEventFlags = []) async {
    post(.keyDown, key: key, flags: flags)
    post(.keyUp, key: key, flags: flags)
    releaseModifiers()
    await pause(0.15)
}

/// 松开全部修饰键：按下、松开事件里带的修饰键会留在系统的修饰键状态里，之后合成的事件跟着带上。
func releaseModifiers() {
    guard let event = CGEvent(source: nil) else { return }
    event.type = .flagsChanged
    event.flags = []
    event.post(tap: .cghidEventTap)
}

func pressShortcut(_ key: CGKeyCode) async { await pressKey(key, controlOptionCommand.flags) }

func typeText(_ text: String) async {
    for character in text {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            let units = Array(String(character).utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        await pause(0.03)
    }
}

/// 退出 WindowShade（菜单里的“退出”，会先展开全部窗口），写设置，再启动，等它准备好。
func relaunchWindowShade(_ extra: [[String]] = []) async -> Bool {
    if windowShadePID() != nil {
        if !(await pressWindowShadeMenu("退出")) {
            if let pid = windowShadePID() { kill(pid, SIGTERM) }
        }
        for _ in 0..<50 where windowShadePID() != nil { await pause(0.1) }
        if let pid = windowShadePID() { kill(pid, SIGKILL); await pause(0.5) }
    }
    writeDefaults(baselineDefaults + extra)
    run("/usr/bin/open", [Suite.shadeApp])
    for _ in 0..<80 {
        await pause(0.1)
        if let pid = windowShadePID() {
            await pause(2.5)
            Suite.audit?.watch(pid)
            return true
        }
    }
    return false
}

/// 拖动：按下、分几步移动、松开。
func drag(from start: CGPoint, to end: CGPoint) async {
    await glide(to: start, duration: 0.3)
    await pause(0.2)
    post(.leftMouseDown, at: start)
    for step in 1...20 {
        let t = Double(step) / 20
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        post(.leftMouseDragged, at: point)
        await pause(0.02)
    }
    post(.leftMouseUp, at: end)
    pointer = end
    await pause(0.4)
}

/// 屏幕上 WindowShade 的大窗口（看一眼的画面卡片）：和 frame 有重叠、比卷帘条高。
func glanceVisible(over frame: CGRect) -> Bool {
    guard let pid = windowShadePID(),
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.1 else { return false }
        return rect.height > 100 && rect.intersects(frame)
    }
}

/// 某个 App 的窗口在屏幕上的前后次序：数字越小越靠前；不在屏幕上为 nil。
func zOrder(ofOwner pid: pid_t, intersecting frame: CGRect) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    return list.firstIndex { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        return rect.intersects(frame)
    }
}

func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

extension Probe {
    /// 某扇窗口最后一次记下的文字。
    func text(of title: String) -> String? {
        events().last { $0["event"] as? String == "text" && $0["title"] as? String == title }?["string"] as? String
    }

    /// 最后一次成为键盘焦点的窗口。
    var keyWindow: String? {
        events().last { $0["event"] as? String == "key-window" }?["title"] as? String
    }

    func allWindows() -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }
}

/// 等某个条件成立，最多 seconds 秒。
func eventually(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        if condition() { return true }
        await pause(0.1)
    }
    return condition()
}

/// 摆好一扇指定的窗口并收起它，返回收起前的信息。
func fold(_ window: AXUIElement, at origin: CGPoint, size: CGSize, _ harness: Harness) async -> Folded? {
    place(window, origin: origin, size: size)
    await pause(0.6)
    guard let frame = axFrame(window) else { return nil }
    let titleBar = CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14)
    let close = closeButtonCenter(window)
    let before = stripFrames().count
    await glide(to: titleBar, duration: 0.3)
    await pause(0.2)
    await doubleClick(at: titleBar)
    let folded = await eventually(3) { stripFrames().count > before }
    harness.expect(folded, "setup: the window did not fold")
    await pause(1.0)
    await glide(to: harness.neutral, duration: 0.3)
    return Folded(window: window, frame: frame, titleBar: titleBar, close: close)
}

/// 卷帘条上标准按钮的位置：截图样式和原窗口的按钮对齐；没取到时按统一标题栏的排法。
func stripButton(_ folded: Folded, _ index: Int) -> CGPoint {
    if index == 0, let close = folded.close { return close }
    let base = folded.close ?? CGPoint(x: folded.frame.minX + 23, y: folded.frame.minY + 14)
    return CGPoint(x: base.x + CGFloat(index) * 20, y: base.y)
}

// MARK: - 场景

struct Scenario {
    let id: String
    let title: String
    let options: [String]
    /// 场景里重启了 WindowShade 或改了它的设置：跑完要恢复基准设置。
    var changesSettings = false
    /// 需要先撤销某项权限的场景另成一组，由 record.sh 撤销权限后按编号单独运行。
    let group: String
    /// 看门狗等多久（秒）：超过就判定驱动程序停住了。随机操作一条要跑十几分钟。
    let timeLimit: TimeInterval
    let run: (Probe, Harness) async -> Void

    init(id: String, title: String, options: [String], changesSettings: Bool = false, group: String = "main",
         timeLimit: TimeInterval = 240, run: @escaping (Probe, Harness) async -> Void) {
        self.id = id
        self.title = title
        self.options = options
        self.changesSettings = changesSettings
        self.group = group
        self.timeLimit = timeLimit
        self.run = run
    }
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
        h.expectOnce("the alert appeared", probe.count("alert-shown"))
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
        h.expectOnce("close was requested", probe.count("close-request"))
        let forwarded = h.logLines().filter { $0.contains("traffic: close forwarded") }.count
        h.expectOnce("WindowShade forwarded close", forwarded)
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
        h.expectOnce("close was requested", probe.count("close-request"))
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
func runScenarioSuite(output: URL, probeApp: String, shadeApp: String, only: Set<String>?,
                      shard: (index: Int, count: Int)? = nil) async {
    let audit = EventAudit()
    guard audit.start() else { log("cannot install the event audit tap"); exit(2) }
    Suite.outputDir = output.deletingLastPathComponent().path
    Suite.probeApp = probeApp
    Suite.shadeApp = shadeApp
    Suite.audit = audit
    guard await relaunchWindowShade() else { log("WindowShade did not start"); exit(2) }

    let recorder = Recorder()
    do { try await recorder.start(to: output.deletingPathExtension().appendingPathExtension("mp4")) }
    catch { log("cannot record: \(error)") }

    var results: [[String: Any]] = []
    var failed = 0
    let all = scenarios + foldScenarios + unfoldScenarios + stripScenarios + glanceScenarios + systemScenarios
        + checkScenarios + randomScenarios
    var needsRelaunch = false
    let watchdog = ScenarioWatchdog(output: output)
    func selected(_ index: Int, _ scenario: Scenario) -> Bool {
        if let only { return only.contains(scenario.id) }
        guard scenario.group == "main" else { return false }
        guard let shard else { return true }
        return index % shard.count == shard.index
    }
    for (index, scenario) in all.enumerated() where selected(index, scenario) {
        // 改过设置的场景之后，回到基准设置再跑下一个。
        if needsRelaunch || windowShadePID() == nil { _ = await relaunchWindowShade() }
        clearSystemPopups()
        needsRelaunch = scenario.changesSettings
        log("scenario \(scenario.id): \(scenario.title)")
        watchdog.begin(scenario.id, scenario.title, limit: scenario.timeLimit)
        let harness = Harness(id: scenario.id, title: scenario.title, audit: audit, probeApp: probeApp,
                              tagBase: Int64(0x5e00_0000 + index * 0x1000))
        if let probe = await Probe.launch(probeApp, name: scenario.id, options: scenario.options) {
            await scenario.run(probe, harness)
            if !harness.result.violations.isEmpty { harness.diagnose(probe) }
            if probe.isRunning { probe.forceQuit() }
            await pause(1.0)
        } else {
            harness.result.violations.append("setup: ProbeApp did not start")
        }
        if !harness.result.violations.isEmpty { harness.diagnose() }
        var result = harness.finish()
        if !result.violations.isEmpty, result.notes["diagnosis"] == nil {
            harness.diagnose()
            result = harness.result
        }
        if !result.violations.isEmpty { failed += 1 }
        log("scenario \(scenario.id): \(result.violations.isEmpty ? "passed" : "failed \(result.violations)")")
        // 场景结束时还留着卷帘条（多半是这一条失败了）：从菜单退出 WindowShade，窗口全部放回原处，
        // 免得后面的场景数卷帘条时把它算进去（2026-10-08 A03 留下的访达卷帘条让 D06、E05、L01、X08 跟着失败）。
        if !stripFrames().isEmpty {
            log("scenario \(scenario.id): left \(stripFrames().count) strips on screen; relaunching WindowShade")
            needsRelaunch = true
        }
        results.append(result.json)
        // 每条场景之后都写一次：整个任务超时被停掉时，已经跑完的结果仍在。
        writeSuite(results, failed: failed, finished: false, to: output)
        watchdog.end(results: results, failed: failed)
    }

    await recorder.stop()
    writeSuite(results, failed: failed, finished: true, to: output)
    exit(failed == 0 ? 0 : 6)
}

func writeSuite(_ results: [[String: Any]], failed: Int, finished: Bool, to output: URL) {
    let summary: [String: Any] = ["scenarios": results, "failed": failed, "finished": finished]
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output)
    }
}

// 故障注入用的测试应用程序（docs/test-catalog.md 第 10 节）。只在 CI 里编译，不进 WindowShade。
//
// 启动参数（--键=值）决定它怎样“不听话”：
//   --events=路径        把收到的每件事写成一行 JSON（驱动程序据此检查不变式）
//   --windows=N          开几扇窗口，标题 “Probe 1”…
//   --alert-on-close     关窗口时弹出独立的提示框（runModal），选第一个按钮才关
//   --slow-close=秒      关窗口前主线程停这么久（按下关闭的辅助功能请求会超时，但窗口照样关掉）
//   --no-buttons         窗口没有关闭、最小化、缩放按钮
//   --title-churn        每 0.1 秒改一次窗口标题
// 运行中接受分布式通知 com.windowshade.probe.command，内容是命令：
//   freeze:秒   主线程停这么久（期间不回答任何辅助功能请求）
//   quit        正常退出
//   crash       立即崩溃

import AppKit

final class ProbeApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var options: [String: String] = [:]
    private var windows: [NSWindow] = []
    private var eventsFile: FileHandle?
    private var churn: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private func record(_ event: String, _ extra: [String: Any] = [:]) {
        var line = extra
        line["event"] = event
        line["time"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: line),
              let eventsFile else { return }
        eventsFile.write(data + Data("\n".utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for argument in CommandLine.arguments.dropFirst() where argument.hasPrefix("--") {
            let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
            options[parts[0]] = parts.count > 1 ? parts[1] : "1"
        }
        if let path = options["events"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            eventsFile = FileHandle(forWritingAtPath: path)
        }
        let count = Int(options["windows"] ?? "1") ?? 1
        var style: NSWindow.StyleMask = [.titled, .resizable]
        if options["no-buttons"] == nil { style.formUnion([.closable, .miniaturizable]) }
        for index in 0..<count {
            let window = NSWindow(contentRect: NSRect(x: 200 + index * 40, y: 300 - index * 40, width: 640, height: 420),
                                  styleMask: style, backing: .buffered, defer: false)
            window.title = "Probe \(index + 1)"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let text = NSTextView(frame: window.contentLayoutRect)
            text.string = "Probe window \(index + 1)"
            text.autoresizingMask = [.width, .height]
            window.contentView = text
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        if options["title-churn"] != nil {
            var tick = 0
            churn = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                tick += 1
                self?.windows.first?.title = "Probe 1 · \(tick)"
            }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)),
            name: Notification.Name("com.windowshade.probe.command"), object: nil,
            suspensionBehavior: .deliverImmediately)
        NSApp.activate(ignoringOtherApps: true)
        record("launched", ["pid": ProcessInfo.processInfo.processIdentifier, "windows": count])
    }

    @objc private func command(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        record("command", ["command": command])
        if command.hasPrefix("freeze:"), let seconds = Double(command.dropFirst(7)) {
            Thread.sleep(forTimeInterval: seconds)
            record("unfrozen")
        } else if command == "quit" {
            NSApp.terminate(nil)
        } else if command == "crash" {
            abort()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        record("close-request", ["title": sender.title])
        if let seconds = options["slow-close"].flatMap(Double.init) {
            Thread.sleep(forTimeInterval: seconds)
        }
        if options["alert-on-close"] != nil {
            record("alert-shown", ["title": sender.title])
            let alert = NSAlert()
            alert.messageText = "Probe alert"
            alert.addButton(withTitle: "Close Window")
            alert.addButton(withTitle: "Keep")
            let answer = alert.runModal()
            record("alert-answered", ["close": answer == .alertFirstButtonReturn])
            return answer == .alertFirstButtonReturn
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        record("closed", ["title": (notification.object as? NSWindow)?.title ?? ""])
    }

    func windowDidMiniaturize(_ notification: Notification) {
        record("minimized", ["title": (notification.object as? NSWindow)?.title ?? ""])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

ProbeApp.main()

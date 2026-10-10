// 故障注入用的测试应用程序（docs/test-catalog.md 第 10 节）。只在 CI 和本机测试包（run-on-this-mac.sh）里编译，不进 WindowShade。
//
// 启动参数（--键=值）：
//   --events=路径        把收到的每件事写成一行 JSON（驱动程序据此检查不变式）
//   --windows=N          开几扇窗口，标题 “Probe 1”…，从左上往右下错开
//   --size=宽,高         窗口大小（默认 640,420）
//   --alert-on-close     关窗口时弹出独立的提示框（runModal），选 “Close Window” 才关
//   --sheet-on-close     关窗口时像未保存的文档一样挂出对话框：Delete / Cancel / Save
//   --slow-close=秒      关窗口前主线程停这么久（按下关闭的辅助功能请求会超时，但窗口照样关掉）
//   --no-buttons         窗口没有关闭、最小化、缩放按钮
//   --title-churn        每 0.1 秒改一次第一扇窗口的标题
// 运行中接受分布式通知 com.windowshade.probe.command，内容是命令：
//   freeze:秒   主线程停这么久          quit / crash      正常退出 / 立即崩溃
//   alert       弹出独立的提示框         sheet             在第一扇窗口上挂一个对话框
//   move:x,y    把第一扇窗口移到 (x,y)（屏幕坐标，原点在左上）  pin    之后不再接受移动
//   fullscreen  第一扇窗口进入全屏       close             关掉第一扇窗口（不经过确认）
//   new-window  新开一扇窗口             hide / minimize   隐藏应用程序 / 最小化第一扇窗口

import AppKit

final class ProbeWindow: NSWindow {
    var pinned = false
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !pinned else { return }
        super.setFrame(frameRect, display: flag)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        guard !pinned else { return }
        super.setFrameOrigin(point)
    }
}

final class ProbeApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var options: [String: String] = [:]
    private var windows: [ProbeWindow] = []
    private var eventsFile: FileHandle?
    private var churn: Timer?
    private var created = 0

    static func main() {
        // 每个场景结束时直接结束 ProbeApp：不保存窗口状态，下次启动不弹“是否重新打开窗口”（它会挡住启动和标题栏）。
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false, "ApplePersistenceIgnoreState": true])
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
        guard let data = try? JSONSerialization.data(withJSONObject: line), let eventsFile else { return }
        eventsFile.write(data + Data("\n".utf8))
    }

    private func installMenus() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String)]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for (name, action, key) in items {
                menu.addItem(NSMenuItem(title: name, action: action, keyEquivalent: key))
            }
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        _ = submenu("ProbeApp", [("Hide ProbeApp", #selector(NSApplication.hide(_:)), "h"),
                                 ("Quit ProbeApp", #selector(NSApplication.terminate(_:)), "q")])
        let file = submenu("File", [("New", #selector(newWindowAction(_:)), "n"),
                                    ("Close", #selector(NSWindow.performClose(_:)), "w")])
        file.items.first?.target = self
        let window = submenu("Window", [("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                                        ("Zoom", #selector(NSWindow.performZoom(_:)), "")])
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
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
        installMenus()
        let count = Int(options["windows"] ?? "1") ?? 1
        for _ in 0..<count { makeWindow() }
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

    @discardableResult
    private func makeWindow() -> ProbeWindow {
        created += 1
        let index = created
        let size = (options["size"] ?? "640,420").split(separator: ",").compactMap { Double($0) }
        var style: NSWindow.StyleMask = [.titled, .resizable]
        if options["no-buttons"] == nil { style.formUnion([.closable, .miniaturizable]) }
        let offset = CGFloat((index - 1) * 50)
        let width = CGFloat(size.first ?? 640)
        let height = CGFloat(size.last ?? 420)
        let frame = NSRect(x: 160 + offset, y: 520 - offset, width: width, height: height)
        let window = ProbeWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "Probe \(index)"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        let text = NSTextView(frame: window.contentLayoutRect)
        text.string = "Probe window \(index)"
        text.autoresizingMask = [.width, .height]
        text.delegate = self
        window.contentView = text
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        return window
    }

    @objc func newWindowAction(_ sender: Any?) {
        let window = makeWindow()
        record("new-window", ["title": window.title])
    }

    @objc private func command(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        // 发给别的 ProbeApp 的命令不执行。
        if let target = notification.userInfo?["pid"] as? String,
           target != String(ProcessInfo.processInfo.processIdentifier) { return }
        record("command", ["command": command])
        let first = windows.first { $0.isVisible || $0.isMiniaturized } ?? windows.first
        if command.hasPrefix("freeze:"), let seconds = Double(command.dropFirst(7)) {
            Thread.sleep(forTimeInterval: seconds)
            record("unfrozen")
        } else if command.hasPrefix("move:") {
            let xy = command.dropFirst(5).split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let first, let screen = NSScreen.screens.first else { return }
            // 屏幕坐标是左上原点，NSWindow 用左下原点。
            first.setFrameTopLeftPoint(NSPoint(x: xy[0], y: screen.frame.maxY - xy[1]))
        } else {
            switch command {
            case "quit": NSApp.terminate(nil)
            case "crash": abort()
            case "pin": first?.pinned = true
            case "fullscreen": first?.toggleFullScreen(nil)
            case "close": first?.close()
            case "new-window": newWindowAction(nil)
            case "hide": NSApp.hide(nil)
            case "minimize": first?.miniaturize(nil)
            case "alert":
                DispatchQueue.main.async { [weak self] in
                    self?.record("alert-shown", ["title": "command"])
                    let alert = NSAlert()
                    alert.messageText = "Probe alert"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    self?.record("alert-answered", [:])
                }
            case "sheet":
                guard let first else { return }
                record("sheet-shown", ["title": first.title])
                let alert = NSAlert()
                alert.messageText = "Probe sheet"
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: first) { [weak self] _ in self?.record("sheet-answered", [:]) }
            default: break
            }
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
        if options["sheet-on-close"] != nil {
            record("sheet-shown", ["title": sender.title])
            let alert = NSAlert()
            alert.messageText = "Do you want to keep this document?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete")
            alert.beginSheetModal(for: sender) { [weak self] answer in
                switch answer {
                case .alertFirstButtonReturn:
                    self?.record("sheet-answered", ["answer": "save"])
                    self?.record("saved", ["title": sender.title])
                    sender.close()
                case .alertThirdButtonReturn:
                    self?.record("sheet-answered", ["answer": "delete"])
                    sender.close()
                default:
                    self?.record("sheet-answered", ["answer": "cancel"])
                }
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        record("closed", ["title": (notification.object as? NSWindow)?.title ?? ""])
    }

    func windowDidMiniaturize(_ notification: Notification) {
        record("minimized", ["title": (notification.object as? NSWindow)?.title ?? ""])
    }

    func windowDidBecomeKey(_ notification: Notification) {
        record("key-window", ["title": (notification.object as? NSWindow)?.title ?? ""])
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        record("fullscreen", ["title": (notification.object as? NSWindow)?.title ?? ""])
    }

    func applicationDidBecomeActive(_ notification: Notification) { record("activated") }
    // 记下是哪个事件让它隐藏的（按键、单击、Apple 事件……），分得清是 WindowShade、系统还是测试本身。
    func applicationDidHide(_ notification: Notification) {
        var trigger = "none"
        if let event = NSApp.currentEvent {
            let chars: String = event.type == .keyDown ? (event.charactersIgnoringModifiers ?? "") : ""
            trigger = "type=\(event.type.rawValue) flags=\(event.modifierFlags.rawValue) chars=\(chars)"
        }
        var appleEvent = "none"
        if let descriptor = NSAppleEventManager.shared().currentAppleEvent {
            appleEvent = "\(descriptor.eventClass)/\(descriptor.eventID)"
        }
        record("hidden", ["trigger": trigger, "appleEvent": appleEvent,
                          "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"])
    }
    func applicationDidUnhide(_ notification: Notification) { record("unhidden") }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView else { return }
        record("text", ["title": text.window?.title ?? "", "string": text.string])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 有 --sheet-on-close 时像文档应用程序一样：退出前在第一扇还开着的窗口上问一次。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("quit-request")
        guard options["sheet-on-close"] != nil,
              let window = windows.first(where: { $0.isVisible || $0.isMiniaturized }) else { return .terminateNow }
        record("sheet-shown", ["title": window.title, "for": "quit"])
        let alert = NSAlert()
        alert.messageText = "Do you want to keep this document?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.beginSheetModal(for: window) { [weak self] answer in
            self?.record("sheet-answered", ["answer": answer == .alertSecondButtonReturn ? "cancel" : "quit"])
            sender.reply(toApplicationShouldTerminate: answer != .alertSecondButtonReturn)
        }
        return .terminateLater
    }
}

ProbeApp.main()

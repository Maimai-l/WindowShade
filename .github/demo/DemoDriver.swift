// CI 演示录屏的驱动：把指定 App（默认文本编辑）的窗口摆好，录下整块屏幕，
// 用合成的鼠标事件双击标题栏收起、停在卷帘条上看一眼、再双击展开。
// 只在 GitHub Actions 的 macOS 机器上跑，不进 App。

import AppKit
import ApplicationServices
import ScreenCaptureKit

func log(_ message: String) {
    FileHandle.standardError.write("[driver] \(message)\n".data(using: .utf8)!)
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

var pointer = CGPoint(x: 900, y: 600)

func post(_ type: CGEventType, at point: CGPoint, clicks: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
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

final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?

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
        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mp4
        output.videoCodecType = .h264
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        log("recording \(display.width)x\(display.height) to \(url.path)")
    }

    func stop() async {
        guard let stream else { return }
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { try? await stream.stopCapture() }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        log("recording finished")
        finished?.resume()
        finished = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        log("recording failed: \(error)")
        finished?.resume()
        finished = nil
    }
}

@main
struct DemoDriver {
    static func main() async {
        // 参数：视频路径 [App 的 bundle id] [窗口宽] [窗口高] [双击点离窗口上沿的距离]
        let args = Array(CommandLine.arguments.dropFirst())
        let video = URL(fileURLWithPath: args.first ?? "/tmp/demo.mp4")
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
        let eventsURL = video.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: eventsURL)
        }
        log("done")
        exit(0)
    }
}

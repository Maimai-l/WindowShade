// CI 演示录屏的驱动：把文本编辑的窗口摆好，录下整块屏幕，
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

func textEditWindow() -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
    else { return nil }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first
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

/// 用 App 收起时同一个接口、同样的选项截文本编辑的窗口，存成 PNG，对照卷帘条上的画面。
func saveWindowCapture(next video: URL) {
    typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID,
                                            CGWindowImageOption) -> Unmanaged<CGImage>?
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let symbol = dlsym(handle, "CGWindowListCreateImage") else { log("no CGWindowListCreateImage"); return }
    let createImage = unsafeBitCast(symbol, to: CreateImage.self)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let info = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "TextEdit"
                                          && ($0[kCGWindowLayer as String] as? Int) == 0 }),
          let number = info[kCGWindowNumber as String] as? NSNumber else { log("no TextEdit window id"); return }
    log("TextEdit window \(number) bounds=\(info[kCGWindowBounds as String] ?? "-") "
        + "screen scale=\(NSScreen.main?.backingScaleFactor ?? 0)")
    let variants: [(String, CGWindowImageOption)] = [
        ("framing-ignored", [.boundsIgnoreFraming, .bestResolution]),
        ("with-framing", [.bestResolution]),
    ]
    for (name, options) in variants {
        guard let image = createImage(.null, .optionIncludingWindow, number.uint32Value, options)?
            .takeRetainedValue() else { log("capture \(name): nil"); continue }
        log("capture \(name): \(image.width)x\(image.height)")
        let url = video.deletingLastPathComponent().appendingPathComponent("capture-\(name).png")
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
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
        let video = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/demo.mp4")
        log("accessibility trusted: \(AXIsProcessTrusted()), screen capture: \(CGPreflightScreenCaptureAccess())")

        var window: AXUIElement?
        for _ in 0..<40 {
            window = textEditWindow()
            if window != nil { break }
            await pause(0.25)
        }
        guard let window else { log("no TextEdit window"); exit(2) }
        let origin = CGPoint(x: 160, y: 120)
        let size = CGSize(width: 700, height: 460)
        place(window, origin: origin, size: size)
        await pause(1)
        saveWindowCapture(next: video)

        let recorder = Recorder()
        do { try await recorder.start(to: video) } catch { log("cannot record: \(error)"); exit(3) }
        await pause(1.5)

        // 标题栏上靠右的一点：避开中间的标题文字和左边的红绿灯。
        let titleBar = CGPoint(x: origin.x + size.width * 0.72, y: origin.y + 14)
        log("double-click title bar at \(titleBar)")
        await glide(to: titleBar)
        await pause(0.3)
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
        await doubleClick(at: titleBar)
        await pause(2.5)

        await recorder.stop()
        log("done")
        exit(0)
    }
}

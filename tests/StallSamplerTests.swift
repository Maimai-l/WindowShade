// 卡顿采样器：一次长卡顿要能分段抓多张栈（以前只抓一张，一秒多的卡顿只看得到开头那一下）。
// 这里在主线程上真的阻塞 1.1 秒，看日志里是不是留下了 ≥2 张带序号的采样。
// 再让主线程在跟踪循环里等 0.8 秒输入（菜单、拖动就是这样），看它是不是被认成跟踪、不写成卡顿。
import Cocoa
import Foundation

@main
struct StallSamplerTests {
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    @MainActor static func main() {
        // 日志只写进专用、0700、路径上没有符号链接的目录；/var 是指向 /private/var 的链接，先解析掉。
        // 不能用 resolvingSymlinksInPath：它会把 /private/var 又改回 /var。
        guard let real = realpath(NSTemporaryDirectory(), nil) else { print("FAIL cannot resolve the temp dir"); exit(1) }
        let directory = URL(fileURLWithPath: String(cString: real), isDirectory: true)
            .appendingPathComponent("windowshade-stall-\(UUID().uuidString)", isDirectory: true)
        free(real)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("windowshade.log").path
        setenv("WINDOWSHADE_LOG_PATH", path, 1)

        wlog("stall-test: log is writable")
        MainThreadSampler.shared.start()
        MainThreadSampler.shared.beat(waiting: false)
        Thread.sleep(forTimeInterval: 1.1)          // 主线程真的卡住
        expect(!MainThreadSampler.shared.busyPeriodWasOnlyTracking(), "a real block is not taken for tracking")
        MainThreadSampler.shared.beat(waiting: false)

        // 跟踪循环（菜单、拖动）：主线程在私有的 RunLoop 模式里等输入，哨兵看不到它入睡，结束时量出一段长间隔。
        // 它不是卡顿，不能写成 stall（CI 场景 B17：菜单收起前的 0.5 秒被记成了卡顿，场景判为不合格）。
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        MainThreadSampler.shared.beat(waiting: false)
        let trackingEnds = Date(timeIntervalSinceNow: 0.8)
        while Date() < trackingEnds {
            _ = app.nextEvent(matching: .any, until: trackingEnds, inMode: .eventTracking, dequeue: true)
        }
        let onlyTracking = MainThreadSampler.shared.busyPeriodWasOnlyTracking()
        expect(onlyTracking, "a 0.8 s wait for input in a tracking loop is recognised as tracking")
        let trackingLine = MainThreadStallSentinel.line(milliseconds: 800, blame: "未标记", onlyTracking: onlyTracking)
        expect(trackingLine.range(of: #"main-thread stall ≈(\d+)ms"#, options: .regularExpression) == nil,
               "the tracking period is not written as a stall: \(trackingLine)")
        let stallLine = MainThreadStallSentinel.line(milliseconds: 1100, blame: "未标记", onlyTracking: false)
        expect(stallLine.range(of: #"main-thread stall ≈(\d+)ms"#, options: .regularExpression) != nil,
               "a real block is still written as a stall: \(stallLine)")
        MainThreadSampler.shared.beat(waiting: false)
        Thread.sleep(forTimeInterval: 0.4)          // 等采样线程把最后一张交给日志
        WindowShadeLogger.shared.flushAndClose()    // 排空日志队列再读

        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        let samples = lines.filter { $0.contains("main-thread stall sample") }
        let trackingLines = lines.filter { $0.contains("main-thread tracking ≈") }
        expect(!trackingLines.isEmpty, "the sampler logs the tracking period as tracking (lines=\(trackingLines.count))")
        expect(lines.contains { $0.contains("stall-test: log is writable") }, "the log file can be written at \(path)")
        expect(!samples.isEmpty, "a 1.1s block gets sampled at all (lines=\(samples.count))")
        expect(samples.count >= 2, "a long block is sampled more than once (lines=\(samples.count))")
        expect(samples.allSatisfy { $0.contains("/4") }, "each sample line carries its index, e.g. 1/4")
        if let first = samples.first { print("     first: \(first.prefix(120))") }
        if samples.count < 2 || trackingLines.isEmpty || !onlyTracking {
            print("     log (\(lines.count) lines):")
            lines.forEach { print("       \($0.prefix(200))") }
        }

        if failures == 0 { print("PASS: the stall sampler takes several samples across one long block and tells tracking from a stall") }
        else { print("FAILED \(failures)"); exit(1) }
    }
}

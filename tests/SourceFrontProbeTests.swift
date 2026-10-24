// 展开后判断原窗口是否已排到最前：向窗口服务器查窗口列表的那一步在后台队列上做，主线程只发起查询、读最近一次的结果。
// 为什么这样做见 prototype/Window/SourceFrontProbe.swift 开头的注释。
// 这里用一个测试调用 release() 之前不返回的假查询，检查发起查询不等它、查询期间主线程照常运行、同一时间只有一次查询；
// 再检查判断原窗口是否已排到最前的条件（P4、P5）。
import Cocoa

/// 假查询：测试调用 release() 之前一直等着，不返回。不用固定的等待时间：CI 的机器慢，固定 0.5 秒时，
/// P2 的循环还没跑完，第一次查询就结束了，第二次查询正常发起，P2 却报同一时间有两次查询（CI 的 Test runners 任务，54f1aa1）。
final class HeldQuery: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var held = true
    var answer = SourceFrontProbe.Answer(inFront: true, ownerPID: 42)
    func run(_ id: CGWindowID) -> SourceFrontProbe.Answer {
        condition.lock(); defer { condition.unlock() }
        calls += 1
        while held { condition.wait() }
        return answer
    }
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    var count: Int { condition.lock(); defer { condition.unlock() }; return calls }
}

@main
struct SourceFrontProbeTests {
    @MainActor static func main() {
        var suite = TestSuite("source-front-probe")

        suite.section("P1", "发起查询不等窗口服务器回话")
        let slow = HeldQuery()
        var frontmost: pid_t? = 42
        let probe = SourceFrontProbe(id: 7, query: { slow.run($0) }, frontmostPID: { frontmost })
        let started = Date()
        probe.poll()
        let pollTook = Date().timeIntervalSince(started)
        suite.expect(pollTook < 0.05, "poll() returned in \(Int(pollTook * 1000)) ms while the query is still waiting")
        suite.expect(!probe.ready, "no answer yet: not ready")

        suite.section("P2", "查询期间每帧照常调用 poll()，主线程不等；同一时间只有一次查询")
        var slowest: TimeInterval = 0
        for _ in 0..<15 {            // 每 20 毫秒发起一次，共约 0.3 秒，模拟展开后每帧发起一次
            let before = Date()
            probe.poll()
            slowest = max(slowest, Date().timeIntervalSince(before))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        suite.expect(slowest < 0.05, "every poll() during the query returned quickly (slowest \(Int(slowest * 1000)) ms)")
        suite.expect(slow.count == 1, "one query in flight at a time (\(slow.count) started)")

        suite.section("P3", "查询结束后，结果写进 latest")
        slow.release()
        let deadline = Date().addingTimeInterval(2)
        while probe.latest == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        suite.expect(probe.latest?.inFront == true, "the answer arrived on the main thread")
        suite.expect(probe.ready, "in front and its app is frontmost: ready")

        suite.section("P4", "应用程序不在前台或原窗口没排到最前时，ready 为 false")
        frontmost = 99
        suite.expect(!probe.ready, "another app is frontmost: not ready")
        frontmost = 42
        slow.answer = SourceFrontProbe.Answer(inFront: false, ownerPID: 42)
        probe.poll()
        let deadline2 = Date().addingTimeInterval(2)
        while probe.latest?.inFront != false, Date() < deadline2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        suite.expect(!probe.ready, "not in front: not ready")

        suite.section("P5", "窗口顺序：原窗口标题栏之上没有别的应用程序的普通窗口")
        func row(_ id: CGWindowID, pid: pid_t, layer: Int = 0, _ rect: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
        }
        let source = row(7, pid: 42, CGRect(x: 100, y: 100, width: 400, height: 300))
        let coverTitle = row(8, pid: 50, CGRect(x: 120, y: 90, width: 200, height: 40))
        let belowTitle = row(9, pid: 50, CGRect(x: 120, y: 200, width: 200, height: 40))
        let ownStrip = row(10, pid: 1, CGRect(x: 100, y: 100, width: 400, height: 32))
        let menuBar = row(11, pid: 50, layer: 25, CGRect(x: 0, y: 0, width: 1000, height: 120))
        suite.expect(SourceFrontProbe.inFront(7, windows: [source, coverTitle], selfPID: 1) == true,
                     "a window listed after the source does not count")
        suite.expect(SourceFrontProbe.inFront(7, windows: [coverTitle, source], selfPID: 1) == false,
                     "another app's window over the title bar: not in front")
        suite.expect(SourceFrontProbe.inFront(7, windows: [belowTitle, ownStrip, menuBar, source], selfPID: 1) == true,
                     "windows below the title bar, WindowShade's own windows and other layers do not count")
        suite.expect(SourceFrontProbe.inFront(7, windows: [coverTitle], selfPID: 1) == false,
                     "the source is not on screen: not in front")

        suite.finish()
    }
}

import Cocoa

private final class Provider: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Set<WindowListCache.Kind> = []
    /// 只阻塞第一次读取（模拟一次迟迟不返回的刷新），之后的读取照常返回。
    private var firstCallBlocked: Set<WindowListCache.Kind> = []
    private var calls: [WindowListCache.Kind: Int] = [:]
    private var values: [WindowListCache.Kind: [[String: Any]]] = [:]
    func set(_ kind: WindowListCache.Kind, _ rows: [[String: Any]], blocked shouldBlock: Bool = false) {
        condition.lock(); defer { condition.unlock() }
        values[kind] = rows
        if shouldBlock { blocked.insert(kind) } else { blocked.remove(kind) }
        condition.broadcast()
    }
    func read(_ kind: WindowListCache.Kind) -> [[String: Any]] {
        condition.lock(); defer { condition.unlock() }
        calls[kind, default: 0] += 1
        condition.broadcast()
        while blocked.contains(kind) { condition.wait() }
        if calls[kind] == 1 { while firstCallBlocked.contains(kind) { condition.wait() } }
        return values[kind] ?? []
    }
    func blockFirstCall(_ kind: WindowListCache.Kind, _ shouldBlock: Bool) {
        condition.lock(); defer { condition.unlock() }
        if shouldBlock { firstCallBlocked.insert(kind) } else { firstCallBlocked.remove(kind) }
        condition.broadcast()
    }
    func count(_ kind: WindowListCache.Kind) -> Int {
        condition.lock(); defer { condition.unlock() }
        return calls[kind, default: 0]
    }
    func waitForCall(_ kind: WindowListCache.Kind) {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while calls[kind, default: 0] == 0 {
            precondition(condition.wait(until: deadline), "provider did not start")
        }
    }
}

@main
struct WindowListCacheTests {
    static func row(_ id: UInt32, _ pid: Int32) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid)]
    }
    static func main() {
        // Slow on-screen lookup; all 12 concurrent callers must receive one result.
        let provider = Provider()
        provider.set(.onScreen, [row(1, 10)], blocked: true)
        provider.set(.all, [row(2, 20)])
        let cache = WindowListCache(ttl: 10, provider: provider.read)
        let done = DispatchGroup()
        let started = DispatchGroup()
        for _ in 0..<12 {
            started.enter(); done.enter()
            DispatchQueue.global().async {
                started.leave()
                precondition(cache.onScreenIDs() == [1])
                done.leave()
            }
        }
        precondition(started.wait(timeout: .now() + 2) == .success)
        provider.waitForCall(.onScreen)
        // While onScreen is deliberately blocked, all must finish independently.
        let otherDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            precondition(cache.allWindows(ofPID: 20).count == 1)
            otherDone.signal()
        }
        precondition(otherDone.wait(timeout: .now() + 2) == .success, "one kind blocked the other")
        precondition(done.wait(timeout: .now() + 0.15) == .timedOut, "on-screen provider should still be blocked")
        provider.set(.onScreen, [row(1, 10)])
        precondition(done.wait(timeout: .now() + 3) == .success, "not all concurrent waiters woke")
        precondition(provider.count(.onScreen) == 1 && provider.count(.all) == 1)
        precondition(cache.onScreenWindows(ofPID: 10).count == 1 && cache.isOnScreen(1))
        precondition(!cache.isOnScreen(99))

        // The cache must expire, and both the list and its indexes must change together.
        let freshProvider = Provider()
        freshProvider.set(.all, [row(3, 30), row(4, 30), row(5, 50)])
        let expiring = WindowListCache(ttl: 0.1, provider: freshProvider.read)
        precondition(expiring.allWindows().count == 3)
        precondition(expiring.allWindows(ofPID: 30).count == 2)
        precondition(expiring.pidsWithWindows() == [30, 50])
        precondition(freshProvider.count(.all) == 1)
        freshProvider.set(.all, [row(6, 60)])
        Thread.sleep(forTimeInterval: 0.15)
        precondition(expiring.pidsWithWindows() == [60])
        precondition(expiring.allWindows(ofPID: 30).isEmpty)
        precondition(freshProvider.count(.all) == 2)

        // R6：正在刷新的那一方迟迟不回来，别的调用方最多等 refreshWait，然后自己取一份（不无限等）。
        let stuck = Provider()
        stuck.set(.all, [row(7, 70)])
        stuck.blockFirstCall(.all, true)
        let bounded = WindowListCache(ttl: 10, provider: stuck.read)
        DispatchQueue.global().async { _ = bounded.allWindows() }
        stuck.waitForCall(.all)
        let start = Date()
        let rows = bounded.allWindows()
        let elapsed = Date().timeIntervalSince(start)
        precondition(rows.count == 1, "the waiting caller reads the list itself")
        precondition(elapsed >= WindowListCache.refreshWait - 0.05 && elapsed < WindowListCache.refreshWait + 0.5,
                     "the waiting caller gives up after refreshWait (\(elapsed) s)")
        precondition(stuck.count(.all) == 2, "exactly one extra read")
        stuck.blockFirstCall(.all, false)

        // 双击标题栏时问谁：要现查的前后顺序。一个应用程序刚到前面，缓存里的列表最多晚 TTL，
        // 前面的还是原来那个应用程序；照缓存问，就问错了应用程序（CI 场景 B16：问了文本编辑，
        // 双击放行给系统，系统把刚展开的窗口放大）。
        func placed(_ id: UInt32, _ pid: Int32, _ rect: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: layer), kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let textEdit = placed(31, 31, CGRect(x: 79, y: 56, width: 673, height: 439))
        let probeWindow = placed(32, 32, CGRect(x: 160, y: 140, width: 640, height: 420))
        let order = Provider()
        order.set(.onScreen, [textEdit, probeWindow])
        let ordered = WindowListCache(ttl: 10, provider: order.read)
        let titleBar = CGPoint(x: 620, y: 154)
        precondition(ordinaryWindowOwner(at: titleBar, in: ordered.onScreenWindows()) == 31, "before: the other app is in front")
        order.set(.onScreen, [probeWindow, textEdit])
        precondition(ordinaryWindowOwner(at: titleBar, in: ordered.onScreenWindows()) == 31,
                     "the cached list still has the old order within its TTL")
        precondition(ordinaryWindowOwner(at: titleBar, in: ordered.onScreenWindowsNow()) == 32,
                     "the live list sees the app that just came to the front")
        precondition(ordinaryWindowOwner(at: titleBar, in: ordered.onScreenWindows()) == 32,
                     "reading the live list also refreshes the cache")

        // 程序坞（层级 20，铺满屏幕）、透明窗口不算；点不在任何窗口上时不属于任何应用程序。
        let dock = placed(40, 40, CGRect(x: 0, y: 0, width: 1024, height: 768), layer: 20)
        let invisible = placed(41, 41, CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 0)
        precondition(ordinaryWindowOwner(at: titleBar, in: [dock, invisible, probeWindow, textEdit]) == 32,
                     "the Dock and transparent windows are skipped")
        precondition(ordinaryWindowOwner(at: CGPoint(x: 1000, y: 700), in: [dock, probeWindow, textEdit]) == nil,
                     "no ordinary window under the point")

        // 缺陷回归（2026-10-20 代码审查发现）：appWindows 对每扇窗口判断是不是桌面小组件，
        // 以前每扇都单独问一次窗口服务器（收起时在主线程上，应用程序有 15 扇窗口就问 15 次）。
        // 现在层级在共用的全部窗口列表里查，列表里没有的窗口才单独问。
        let widgetLayer = -2147483601
        let layered = Provider()
        layered.set(.all, (1...15).map { placed(UInt32(100 + $0), 50, CGRect(x: 0, y: 0, width: 400, height: 300)) }
                    + [placed(200, 60, CGRect(x: 0, y: 0, width: 160, height: 160), layer: widgetLayer)])
        let shared = WindowListCache(ttl: 10, provider: layered.read)
        var liveQueries = 0
        let live: (CGWindowID) -> [String: Any]? = { id in
            liveQueries += 1
            return id == 300 ? placed(300, 60, CGRect(x: 0, y: 0, width: 160, height: 160), layer: widgetLayer) : nil
        }
        for id in 101...115 {
            precondition(!isDesktopWidgetWindow(id: CGWindowID(id), cache: shared, liveInfo: live), "an ordinary window is not a widget")
        }
        precondition(isDesktopWidgetWindow(id: 200, cache: shared, liveInfo: live), "a widget in the list is recognized")
        precondition(liveQueries == 0, "windows in the list need no query of their own (made \(liveQueries))")
        precondition(layered.count(.all) == 1, "one list query serves every window")
        precondition(isDesktopWidgetWindow(id: 300, cache: shared, liveInfo: live) && liveQueries == 1,
                     "a window missing from the list is asked about directly")
        // 双击标题栏的预过滤只看点击所在的那扇窗口（最前面包含这个点的普通窗口）。
        // 缺陷回归（2026-10-20 代码审查）：浏览器铺满屏幕，后面一扇访达窗口的顶部在点下面；
        // 在浏览器内容区里双击选词，也被当成可能的标题栏双击，去问浏览器做辅助功能命中测试，全系统的输入等着它。
        let browser = placed(50, 50, CGRect(x: 0, y: 25, width: 1440, height: 875))
        let finderBehind = placed(51, 51, CGRect(x: 100, y: 200, width: 800, height: 500))
        let ownPID: pid_t = 99
        precondition(!titlebarBandMayContain(CGPoint(x: 300, y: 450), in: [browser, finderBehind], ownPID: ownPID),
                     "a double click in the front window's content is not near a title bar, whatever lies behind it")
        precondition(titlebarBandMayContain(CGPoint(x: 300, y: 40), in: [browser, finderBehind], ownPID: ownPID),
                     "a double click near the top of the front window may be on its title bar")
        precondition(titlebarBandMayContain(CGPoint(x: 300, y: 450), in: [dock, finderBehind, browser], ownPID: ownPID),
                     "the Dock is skipped; the window the click lands on decides")
        // WindowShade 自己的窗口（卷帘条的投影等）不挡后面的窗口；点在它的顶部带里照样算。
        let ownShadow = placed(60, ownPID, CGRect(x: 0, y: 25, width: 1440, height: 875))
        precondition(!titlebarBandMayContain(CGPoint(x: 300, y: 450), in: [ownShadow, browser, finderBehind], ownPID: ownPID),
                     "WindowShade's own window does not decide for the window behind it")
        precondition(titlebarBandMayContain(CGPoint(x: 300, y: 40), in: [ownShadow, browser], ownPID: ownPID),
                     "a double click near the top of WindowShade's own window may be on its title bar")
        precondition(!titlebarBandMayContain(CGPoint(x: 300, y: 40), in: [dock], ownPID: ownPID),
                     "no ordinary window under the point: not a title bar")
        print("PASS: WindowListCache — 12 concurrent callers, one refresh, independent kinds, TTL, indexes, bounded wait, live order, widget layer, title-bar band")
    }
}

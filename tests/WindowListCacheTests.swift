import Cocoa

private final class Provider: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Set<WindowListCache.Kind> = []
    /// 只卡住第一次读取（模拟一个迟迟不回来的刷新者），之后的读取照常返回。
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
        print("PASS: WindowListCache — 12 concurrent callers, one refresh, independent kinds, TTL, indexes, bounded wait")
    }
}

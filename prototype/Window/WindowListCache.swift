// WindowServer 窗口列表：全量列表短 TTL 缓存与单窗口实时查询。

import Cocoa

// 全量窗口列表的短时缓存（150 毫秒）。一次收起或展开会多次枚举全部窗口（辅助功能元素对应窗口号、
// 屏幕上的窗口、应用程序的窗口数、标题栏预筛……），这些读取应当看到同一份列表，只向窗口服务器要一次。
// windowID(of:) 先读元素自己的窗口号；这里的列表只用来查找和兼容匹配，不用来证明移动或隐藏已经完成。
// 单窗口查询 cgWindowInfo(_:) 不经过这里：Reconcile 的定时核对和收起验证必须看到实时值。
// 线程安全：后台 AX 队列也会走 windowID(of:)，缓存读写用锁保护。
// 可变状态只在持有 `lock` 时读写；`provider` 构造后不变。
final class WindowListCache: @unchecked Sendable {
    static let shared = WindowListCache()
    /// 等另一方刷新的时限（秒）。
    static let refreshWait: TimeInterval = 1.0

    private struct Snapshot {
        let windows: [[String: Any]]
        let byID: [CGWindowID: [String: Any]]
        let byPID: [pid_t: [[String: Any]]]
    }

    private struct Entry {
        let snapshot: Snapshot
        let at: CFAbsoluteTime
    }

    // 快照种类。internal 以便可注入的 provider 在测试中区分两种查询。
    enum Kind: Hashable {
        case onScreen   // [.optionOnScreenOnly, .excludeDesktopElements]
        case all        // [.optionAll, .excludeDesktopElements]
    }

    // 窗口列表 provider。默认直连 WindowServer，测试可注入可控阻塞的假 provider。
    private let provider: (Kind) -> [[String: Any]]

    // 单一状态锁保护缓存与 in-flight 标记；provider 调用一律在锁外进行，
    // 慢 provider 不会阻塞其他读写者。
    private let lock = NSCondition()
    private let ttl: TimeInterval
    private var onScreenEntry: Entry?
    private var allEntry: Entry?
    // 两种列表各有一个“正在刷新”标记：多个队列可能同时发现缓存过期，每种列表只发一次枚举，
    // 其余调用在条件变量上等，刷新完一起被唤醒，再查一次是否过期，不各自重新枚举。
    private var onScreenRefreshing = false
    private var allRefreshing = false

    init(ttl: TimeInterval = 0.15,
         provider: @escaping (Kind) -> [[String: Any]] = WindowListCache.systemProvider) {
        self.ttl = ttl
        self.provider = provider
    }

    private static func systemProvider(for kind: Kind) -> [[String: Any]] {
        let options: CGWindowListOption = kind == .onScreen
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    func onScreenWindows() -> [[String: Any]] {
        snapshot(.onScreen).windows
    }

    /// 现查一次在屏列表，顺带刷新缓存。只给要看准前后顺序的少数地方用（双击标题栏时问哪个应用程序）：
    /// 缓存最多晚 ttl，一个应用程序刚到前面时，缓存里排在前面的还是原来那个。
    func onScreenWindowsNow() -> [[String: Any]] {
        let fresh = build(provider(.onScreen))
        lock.lock()
        setEntry(.onScreen, Entry(snapshot: fresh, at: CFAbsoluteTimeGetCurrent()))
        lock.unlock()
        return fresh.windows
    }

    func onScreenWindows(ofPID pid: pid_t) -> [[String: Any]] {
        snapshot(.onScreen).byPID[pid] ?? []
    }

    func allWindows() -> [[String: Any]] {
        snapshot(.all).windows
    }

    func allWindows(ofPID pid: pid_t) -> [[String: Any]] {
        snapshot(.all).byPID[pid] ?? []
    }

    // 拥有至少一个窗口的进程集合。用于在耗时的辅助功能枚举之前筛掉纯后台进程：
    // 一个窗口都没有的进程，appWindows(pid:) 只可能返回空数组，却要为此做一次同步的辅助功能调用；
    // 目标进程无响应时，最多要等满一次辅助功能超时（axMessagingTimeout，1 秒）。
    func pidsWithWindows() -> Set<pid_t> {
        Set(snapshot(.all).byPID.keys)
    }

    func onScreenIDs() -> Set<CGWindowID> {
        let snapshot = snapshot(.onScreen)
        var ids = Set<CGWindowID>()
        ids.reserveCapacity(snapshot.windows.count)
        for info in snapshot.windows {
            if let n = info[kCGWindowNumber as String] as? NSNumber {
                ids.insert(CGWindowID(n.uint32Value))
            }
        }
        return ids
    }

    func isOnScreen(_ id: CGWindowID) -> Bool {
        snapshot(.onScreen).byID[id] != nil
    }

    private func snapshot(_ kind: Kind) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        while true {
            let now = CFAbsoluteTimeGetCurrent()

            // 命中未过期缓存：直接返回同一份列表（同步语义，不发 IPC）。
            if let entry = cacheEntry(kind), now - entry.at < ttl {
                return entry.snapshot
            }

            // 已有调用在锁外刷新同一种快照：等待其完成（锁在此期间被释放，
            // 因此慢 provider 不会阻塞状态锁），被唤醒后回到循环顶部重查 TTL。
            // 最多等 refreshWait：另一方迟迟没有结果时自己取一份，不再等下去。
            if isRefreshing(kind) {
                if lock.wait(until: Date(timeIntervalSinceNow: Self.refreshWait)) { continue }
                lock.unlock()
                let fresh = build(provider(kind))
                lock.lock()
                return fresh
            }

            // 成为该 kind 的唯一刷新者。锁外取数，完成后写回缓存并广播唤醒全部等待者。
            setRefreshing(kind, true)
            lock.unlock()
            let fresh = build(provider(kind))
            lock.lock()
            setEntry(kind, Entry(snapshot: fresh, at: CFAbsoluteTimeGetCurrent()))
            setRefreshing(kind, false)
            lock.broadcast()
            return fresh
        }
    }

    private func cacheEntry(_ kind: Kind) -> Entry? {
        kind == .onScreen ? onScreenEntry : allEntry
    }

    private func setEntry(_ kind: Kind, _ entry: Entry) {
        if kind == .onScreen {
            onScreenEntry = entry
        } else {
            allEntry = entry
        }
    }

    private func isRefreshing(_ kind: Kind) -> Bool {
        kind == .onScreen ? onScreenRefreshing : allRefreshing
    }

    private func setRefreshing(_ kind: Kind, _ value: Bool) {
        if kind == .onScreen {
            onScreenRefreshing = value
        } else {
            allRefreshing = value
        }
    }

    private func build(_ windows: [[String: Any]]) -> Snapshot {
        var byID: [CGWindowID: [String: Any]] = [:]
        var byPID: [pid_t: [[String: Any]]] = [:]
        for info in windows {
            if let n = info[kCGWindowNumber as String] as? NSNumber {
                byID[CGWindowID(n.uint32Value)] = info
            }
            if let p = info[kCGWindowOwnerPID as String] as? NSNumber {
                byPID[pid_t(p.int32Value), default: []].append(info)
            }
        }
        return Snapshot(windows: windows, byID: byID, byPID: byPID)
    }
}

/// 点落在哪个应用程序的普通窗口上：按窗口列表从前到后，找第一扇层级在 0–19、不透明度大于 0、包含这个点的窗口，返回它所属的进程。
/// Dock（层级 20，一扇铺满屏幕的透明窗口）、菜单栏等系统层级不算：它们不接点击。
/// 要看准前后顺序时传 onScreenWindowsNow()（场景 B16）。
func ordinaryWindowOwner(at point: CGPoint, in windows: [[String: Any]]) -> pid_t? {
    for info in windows {
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard layer >= 0, layer < 20,
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
              let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point) else { continue }
        return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }
    return nil
}

func cgWindowInfo(_ id: CGWindowID) -> [String: Any]? {
    // 单窗口直接查询，不走 WindowListCache：Reconcile 的定时核对、收起验证、读回 SkyLight 透明度
    // 都要实时值，而且每次只查一个窗口，开销很小。
    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
    return info?.first
}

func cgWindowLayer(_ id: CGWindowID) -> Int32? {
    guard let raw = cgWindowInfo(id)?[kCGWindowLayer as String] else { return nil }
    if let number = raw as? NSNumber { return number.int32Value }
    if let int = raw as? Int { return Int32(int) }
    return nil
}

func isDesktopWidgetWindow(id: CGWindowID) -> Bool {
    let desktopWidgetLayer: Int32 = -2147483601
    let layer = cgWindowLayer(id)
    return layer == desktopWidgetLayer
}

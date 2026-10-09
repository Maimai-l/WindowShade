// 诊断基础设施：日志、主线程活动标记、慢调用门限日志与卡顿哨兵。

import Cocoa

/// @unchecked Sendable 的理由：全部可变成员只在 queue 内访问；write 只捕获不可变字符串和 Date。
final class WindowShadeLogger: @unchecked Sendable {
    static let shared = WindowShadeLogger()
    private let queue = DispatchQueue(label: "WindowShade.log", qos: .utility)
    private var writer: SecureLogFile?
    private var disabled = false
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    func write(_ s: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self, !self.disabled else { return }
            do {
                if self.writer == nil { self.writer = try self.openWriter() }
                let line = "\(self.timeFormatter.string(from: now)) \(s)\n"
                try self.writer?.append(Data(line.utf8))
            } catch {
                // 不递归 wlog；不向公用位置回退，也不把这一行交给统一日志。
                self.writer?.closeFiles(); self.writer = nil; self.disabled = true
            }
        }
    }
    func flushAndClose() {
        // 只能从日志队列以外调用（这里用 queue.sync）。关闭以后不再打开文件。
        queue.sync { writer?.closeFiles(); writer = nil; disabled = true }
    }
    private func openWriter() throws -> SecureLogFile {
        if let override = getenv("WINDOWSHADE_LOG_PATH") {
            // 开发覆盖仍支持，但必须给专用、受保护、已存在的父目录。
            return try SecureLogFile(path: String(cString: override))
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WindowShade", isDirectory: true)
        // 创建只保证路径存在。SecureLogFile 随后逐级用 descriptor + NOFOLLOW 验证，未验证前不写日志。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return try SecureLogFile(path: directory.appendingPathComponent("windowshade.log").path)
    }
}

func wlog(_ s: String) {
    WindowShadeLogger.shared.write(s)
}

// 记下主线程正在做什么。卡顿哨兵要等阻塞结束才能运行，只报时长定位不到原因；
// 有了当前活动的标记，日志里的“stall ≈1054ms”就能写成“stall ≈1054ms 期间=fold: 折叠窗口”。
// 只在主线程记录，不需要加锁。
enum MainThreadActivity {
    private struct Span {
        let label: String
        let start: CFAbsoluteTime
        let end: CFAbsoluteTime
    }

    /// 只在主线程读写：push/pop 先查 Thread.isMainThread，attribution 只由主线程上的卡顿哨兵调用。
    nonisolated(unsafe) private static var stack: [(label: String, start: CFAbsoluteTime)] = []
    nonisolated(unsafe) private static var recent: [Span] = []
    private static let maxSpans = 512

    static func push(_ label: String) {
        guard Thread.isMainThread else { return }
        stack.append((label, CFAbsoluteTimeGetCurrent()))
    }

    static func pop() {
        guard Thread.isMainThread, let item = stack.popLast() else { return }
        recent.append(Span(label: item.label, start: item.start, end: CFAbsoluteTimeGetCurrent()))
        if recent.count > maxSpans { recent.removeFirst(recent.count - maxSpans) }
    }

    /// 卡顿窗口里累计占用最久的标记，附带次数与占比。
    /// 报最后结束的那一个会误导：几秒的连续忙碌通常由几十次短调用组成，
    /// 排在最后的那次往往只是碰巧，并不是占时最多的。
    static func attribution(since: CFAbsoluteTime, until: CFAbsoluteTime) -> String {
        var totals: [String: (seconds: Double, count: Int)] = [:]
        func accumulate(_ label: String, from start: CFAbsoluteTime, to end: CFAbsoluteTime) {
            let overlap = min(end, until) - max(start, since)
            guard overlap > 0 else { return }
            var entry = totals[label] ?? (0, 0)
            entry.seconds += overlap
            entry.count += 1
            totals[label] = entry
        }
        for span in recent { accumulate(span.label, from: span.start, to: span.end) }
        for active in stack { accumulate(active.label, from: active.start, to: until) }
        guard let top = totals.max(by: { $0.value.seconds < $1.value.seconds }) else { return "未标记" }
        let window = until - since
        let share = window > 0 ? Int((top.value.seconds / window * 100).rounded()) : 0
        return "\(top.key)×\(top.value.count) 占 \(share)%"
    }
}

/// 给主线程上那些自己不打日志的同步段落加标记，只为卡顿归因，不产生日志。
@discardableResult
func marking<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    MainThreadActivity.push(label)
    defer { MainThreadActivity.pop() }
    return try body()
}

// 包住可能耗时的同步代码；超过阈值才记日志，免得日志太多。
@discardableResult
func logIfSlow<T>(_ label: String, threshold: TimeInterval = 0.05, _ body: () -> T) -> T {
    let start = CFAbsoluteTimeGetCurrent()
    MainThreadActivity.push(label)
    let result = body()
    MainThreadActivity.pop()
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    if elapsed >= threshold {
        wlog("slow: \(label) took \(Int(elapsed * 1000))ms")
    }
    return result
}

// 主线程卡顿哨兵：主 RunLoop 每有一次活动，就计算和上一次活动的间隔。
// 上一次不是休眠等待、且间隔超过 0.5 秒，才算卡顿。由主线程恢复后自己报告，
// 所以空闲休眠和 App Nap 不会误报，也不需要后台计时器（后台计时器会被 App Nap 节流，量出假的长间隔）。
// 状态只在主线程访问，不加锁；每次 RunLoop 活动只取一次时间、比较一次。
final class MainThreadStallSentinel {
    /// 见上：只在主线程访问。
    nonisolated(unsafe) static let shared = MainThreadStallSentinel()

    private var observer: CFRunLoopObserver?
    private var lastActivityAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var wasWaiting = true

    func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) { [weak self] _, activity in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // 真正阻塞时（停在回调或同步调用里），RunLoop 不会进入休眠，恢复后的第一个回调
            // 一定不是 afterWaiting；反过来，以 afterWaiting 结束的长间隔都是休眠后被唤醒
            // （即使因回调时序没先看到 beforeWaiting），不是卡顿，不报告。
            if !self.wasWaiting, activity != .afterWaiting, now - self.lastActivityAt > 0.5 {
                let blame = MainThreadActivity.attribution(since: self.lastActivityAt, until: now)
                wlog(MainThreadStallSentinel.line(milliseconds: Int((now - self.lastActivityAt) * 1000), blame: blame,
                                                  onlyTracking: MainThreadSampler.shared.busyPeriodWasOnlyTracking()))
            }
            self.lastActivityAt = now
            self.wasWaiting = activity == .beforeWaiting
            MainThreadSampler.shared.beat(waiting: self.wasWaiting)
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, CFRunLoopMode.commonModes)
        MainThreadSampler.shared.start()
    }

    /// 菜单、拖动这类跟踪循环跑在私有的 RunLoop 模式里，哨兵看不到它入睡，结束时会量出一段长间隔。
    /// 采样器在这段时间里只看到主线程在等输入时，它不是卡顿，不写成 stall
    /// （CI 场景 B17：从菜单栏选“全部展开”后，菜单收起前的 0.5 秒被记成了卡顿）。
    static func line(milliseconds: Int, blame: String, onlyTracking: Bool) -> String {
        onlyTracking
            ? "main-thread tracking ended ≈\(milliseconds)ms (menu or drag tracking; waiting for input, not a stall)"
            : "main-thread stall ≈\(milliseconds)ms 期间=\(blame)"
    }
}

// 卡顿时抓主线程的调用栈。哨兵只能在卡顿结束后报时长，日志写着“期间=未标记”时看不出是谁。
// 这里另开一条看门狗线程：主线程超过 250 毫秒没回到 RunLoop、又不在休眠时，暂停它，
// 沿帧指针链记下返回地址，立即恢复，再在看门狗线程上查符号写进日志。
// 一次卡顿最多抓 4 张（每张至少隔 200 毫秒），长卡顿的后半段也能抓到。
// 看门狗平时每 200 毫秒醒一次，只读一个时间戳。本程序的帧记“镜像+偏移”，用 atos 对着构建出来的程序就能还原到行。
final class MainThreadSampler: @unchecked Sendable {
    static let shared = MainThreadSampler()

    private var lock = os_unfair_lock()
    private var beatAt = CFAbsoluteTimeGetCurrent()
    private var busy = false
    private var samples = 0
    private var lastSampleAt: CFAbsoluteTime = 0
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private var started = false
    /// 这段忙碌期里抓到的栈：在等输入的几张，在执行代码的几张。下一次 beat 清零。
    private var trackingSamples = 0
    private var workSamples = 0

    /// 在主线程上调用一次。
    func start() {
        guard Thread.isMainThread, !started else { return }
        started = true
        mainThread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        let watchdog = Thread { [weak self] in self?.watch() }
        watchdog.name = "WindowShade.stall-sampler"
        // 不用 .utility：机器繁忙时（CI 上同时在录屏），这一档的线程得不到调度，半秒的卡顿结束了它还没运行，
        // 一张调用栈也抓不到（2026-10-08 场景 A26 的 551 毫秒卡顿没有采样）。每秒仍只唤醒 5 次。
        watchdog.qualityOfService = .userInitiated
        watchdog.start()
    }

    /// 主线程每次 RunLoop 活动时调用。
    func beat(waiting: Bool) {
        os_unfair_lock_lock(&lock)
        beatAt = CFAbsoluteTimeGetCurrent()
        busy = !waiting
        samples = 0
        lastSampleAt = 0
        trackingSamples = 0
        workSamples = 0
        os_unfair_lock_unlock(&lock)
    }

    /// 这段忙碌期抓到过栈，而且每一张都是在等输入（跟踪循环），没有一张在执行代码。
    func busyPeriodWasOnlyTracking() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return trackingSamples > 0 && workSamples == 0
    }

    /// 抓栈期间主线程没有回到 RunLoop 时才记账；它已经回来过，这张栈属于上一段忙碌期，不算进新的一段。
    private func count(tracking: Bool, periodStartedAt: CFAbsoluteTime) {
        os_unfair_lock_lock(&lock)
        if beatAt == periodStartedAt {
            if tracking { trackingSamples += 1 } else { workSamples += 1 }
        }
        os_unfair_lock_unlock(&lock)
    }

    private func watch() {
        while true {
            // 每 200 毫秒醒一次：卡顿阈值是 250 毫秒，这个间隔足够（检测时刻落在 250–450 毫秒之间，
            // 报的仍是实际卡顿时长）；唤醒次数只有每 50 毫秒醒一次时的四分之一，
            // 锁屏空闲时的唤醒有相当一部分来自这类定时器（2026-10-01 测量）。
            usleep(200_000)
            let now = CFAbsoluteTimeGetCurrent()
            os_unfair_lock_lock(&lock)
            let stuck = busy ? now - beatAt : 0
            let takeSample = busy && stuck > 0.25 && samples < 4 && now - lastSampleAt >= 0.2
            if takeSample { samples += 1; lastSampleAt = now }
            let index = samples
            let periodStartedAt = beatAt
            os_unfair_lock_unlock(&lock)
            guard takeSample else { continue }
            let frames = captureMainStack()
            guard !frames.isEmpty else { continue }
            let described = frames.prefix(32).map(Self.describe)
            // 主线程其实在等输入：菜单、拖动这类跟踪循环跑在私有的 RunLoop 模式里，看不到它入睡，但它是空闲的，不算卡顿。
            let tracking = described.contains { $0.contains("ReceiveNextEventCommon") || $0.contains("BlockUntilNextEventMatchingListInMode") }
            count(tracking: tracking, periodStartedAt: periodStartedAt)
            if tracking {
                // 哨兵只看 RunLoop 活动，分不出跟踪循环和真正的卡顿，会和这里写出互相矛盾的两行日志，
                // 所以这里如实记成 tracking。
                if index == 1 {
                    wlog("main-thread tracking ≈\(Int(stuck * 1000))ms (menu or drag tracking; main thread is waiting for input, not frozen)")
                }
                continue
            }
            wlog("main-thread stall sample \(index)/4 ≈\(Int(stuck * 1000))ms: \(described.joined(separator: " ← "))")
        }
    }

    /// 暂停主线程，抄下返回地址，立刻放开。暂停期间不做任何可能拿锁的事（查符号放在放开之后）。
    private func captureMainStack() -> [UInt] {
        guard mainThread != 0, thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        var frames: [UInt] = []
        frames.reserveCapacity(64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            frames.append(Self.strip(UInt(state.__pc)))
            frames.append(Self.strip(UInt(state.__lr)))
            var fp = UInt(state.__fp)
            for _ in 0..<60 {
                guard fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0,
                      let slot = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = slot[0]
                let ret = Self.strip(slot[1])
                if ret == 0 { break }
                frames.append(ret)
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        return frames
    }

    /// 去掉指针认证位（系统库的返回地址带签名）。
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    private static func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let offset = address - UInt(bitPattern: info.dli_fbase)
        // 本程序的地址记偏移（atos 还原）；系统库记符号名更直接。
        if image == "WindowShade" || info.dli_sname == nil {
            return "\(image)+0x\(String(offset, radix: 16))"
        }
        let name = String(cString: info.dli_sname!)
        return "\(image):\(name.count > 60 ? String(name.prefix(60)) + "…" : name)"
    }
}

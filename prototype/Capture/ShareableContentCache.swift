// SCShareableContent 的短时缓存。

import Cocoa
import ScreenCaptureKit

// SCShareableContent.current 每次都要枚举全系统的窗口，有的机器上要几百毫秒到几秒。
// 每次收起截图前都要等它，双击后的等待主要来自它（超时还会让卷帘条改用简化标题栏）。
// 有了短时缓存，再加上点标题栏时提前取一次，双击的第二下到来时内容通常已经准备好。
// 缓存里没有目标窗口时强制刷新，所以结果不受缓存时长影响（新建的窗口一定会触发强制刷新）。
/// 系统一次性产出的只读快照：只在后台枚举任务里生成，交给主 actor 一次，之后谁都不改它。
/// SCShareableContent 没标 Sendable，只用这个本文件私有的壳子跨这一次边界，不对整个类型担保。
private struct ShareableSnapshot: @unchecked Sendable {
    let content: SCShareableContent
}

@available(macOS 14.0, *)
@MainActor
final class ShareableContentCache {
    static let shared = ShareableContentCache()

    private var cached: SCShareableContent?
    private var fetchedAt: CFAbsoluteTime = 0
    private var inFlight: Task<ShareableSnapshot, Error>?
    private let ttl: TimeInterval = 1.5
    private var lastFailureAt: CFAbsoluteTime = 0
    private var lastFailureLogAt: CFAbsoluteTime = 0
    private let failureBackoff: TimeInterval = 2.0
    private let failureLogThrottle: TimeInterval = 30.0

    private func isFresh() -> Bool {
        cached != nil && CFAbsoluteTimeGetCurrent() - fetchedAt < ttl
    }

    func content(requiring windowID: CGWindowID) async -> SCShareableContent? {
        if isFresh(), let cached, cached.windows.contains(where: { $0.windowID == windowID }) {
            return cached
        }
        if let inFlight, let content = try? await inFlight.value.content,
           content.windows.contains(where: { $0.windowID == windowID }) {
            return content
        }
        // 等到的在途快照仍不含目标窗口（典型场景：窗口在枚举开始之后才创建）。
        // 旧任务此刻已经跑完，再 await 它只会拿到同一份过期快照；必须发起新枚举。
        // refresh() 会覆盖 inFlight，配合刷新序号，旧任务收尾时不会误清掉
        // 新任务的“正在刷新”标记（见 refresh() 的 refreshGeneration）。
        return await refresh()
    }

    // 点标题栏按下鼠标时提前取一次。命中新鲜缓存或已有在途请求都直接跳过；无录屏权限或
    // 处于失败退避期内也跳过，避免每次点击都触发一次注定失败的全系统枚举。
    func prefetch() async {
        guard hasScreenRecordingPermission() else { return }
        guard !isFresh(), inFlight == nil else { return }
        guard CFAbsoluteTimeGetCurrent() - lastFailureAt >= failureBackoff else { return }
        _ = await refresh()
    }

    // 从决定刷新到给 inFlight 赋值之间不能有 await。调用方决定刷新时，inFlight 要么为空，
    // 要么已经完成（content(requiring:) 先等完旧任务才会走到这里）；本函数在 `inFlight = task`
    // 之前也没有 await，所以不会重复枚举。
    // refreshGeneration 是刷新序号：content(requiring:) 发现旧快照里没有目标窗口时，
    // 会马上开始新一轮刷新并覆盖 inFlight；旧一轮可能在这之后才恢复执行，
    // 只有序号仍是最新的那一轮才清空 inFlight、写缓存。
    private var refreshGeneration: UInt64 = 0

    private func refresh() async -> SCShareableContent? {
        let start = CFAbsoluteTimeGetCurrent()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        // 不继承 MainActor：窗口枚举可能持续数秒，cache 状态仍在主 actor 串行化，
        // 但系统枚举及其完成回调不会占用主线程执行器。
        let task = Task.detached(priority: .userInitiated) {
            ShareableSnapshot(content: try await SCShareableContent.current)
        }
        inFlight = task
        let content = try? await task.value.content
        guard refreshGeneration == generation else {
            // 已被更新的刷新取代：缓存状态由新的一轮负责，这里只把结果交还调用方。
            return content
        }
        inFlight = nil
        if let content {
            cached = content
            fetchedAt = CFAbsoluteTimeGetCurrent()
            lastFailureAt = 0
            let ms = Int((fetchedAt - start) * 1000)
            if ms >= 300 { wlog("capture: shareable-content fetch took \(ms)ms") }
        } else {
            lastFailureAt = CFAbsoluteTimeGetCurrent()
            if lastFailureAt - lastFailureLogAt >= failureLogThrottle {
                lastFailureLogAt = lastFailureAt
                wlog("capture: shareable-content fetch failed")
            }
        }
        return content
    }
}

// 两个 Task 竞争 resume 同一个 continuation 时，保证只 resume 一次。两个 Task 不在同一个 actor 上，
// 需要真正的互斥，不能靠“中间没有 await 就不会交错”这种单线程推理。
actor SingleResumeGuard {
    private var resumed = false
    func tryResume() -> Bool {
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

// 跨线程交接用的两个包装类型和两个辅助函数。
//
// Dispatch 和 AppKit 的一部分回调在 macOS 26 SDK 里标成 @Sendable，
// 而这些回调里传的闭包或值本身并不跨线程使用。用下面两个类型把“调用方已经保证了线程”
// 写在类型上，两个版本的 SDK 都能编，也不用在每个调用点分别处理。

import Cocoa

/// 只会在主线程上执行的闭包。
struct MainThreadWork: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// 交给另一条线程、但同一时刻只有一方在用的值（例如交给后台扫描的只读快照、
/// 等 GPU 完成前要保持存活的帧）。调用方负责保证没有并发读写。
struct HandOff<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// 把闭包排到主队列上执行；`delay` 为 0 时等同于 `DispatchQueue.main.async`。
func runOnMainQueue(after delay: TimeInterval = 0, _ work: @escaping () -> Void) {
    let box = MainThreadWork(work)
    if delay > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { box.run() }
    } else {
        DispatchQueue.main.async { box.run() }
    }
}

extension NSAnimationContext {
    /// 和 `runAnimationGroup(_:completionHandler:)` 一样；完成回调总在主线程上执行。
    @MainActor
    static func runAnimationGroup(_ changes: (NSAnimationContext) -> Void,
                                  thenOnMain completion: @escaping () -> Void) {
        let box = MainThreadWork(completion)
        runAnimationGroup(changes, completionHandler: { box.run() })
    }
}

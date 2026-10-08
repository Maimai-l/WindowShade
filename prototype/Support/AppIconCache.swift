// 应用程序图标的位图缓存。
//
// NSRunningApplication.icon 第一次画出来时，要同步向图标服务（XPC）要位图：在主线程上实测 300 至 500 毫秒
// （CI 场景 A28-proxy，统一样式的标题栏画图标时）。所以在后台先画成位图存起来，主线程只画现成的位图；
// 还没准备好就不画图标，不在主线程上等。

import AppKit

final class AppIconCache: @unchecked Sendable {
    static let shared = AppIconCache()

    /// 标题栏、缩略图上的图标都不超过 32 点；按 2 倍像素画。
    static let pointSize: CGFloat = 32

    private let lock = NSLock()
    private var images: [pid_t: NSImage] = [:]
    private var pending: Set<pid_t> = []
    private let queue = DispatchQueue(label: "WindowShade.app-icons", qos: .userInitiated)

    /// 已经画好的图标；还没有时返回 nil。
    func image(pid: pid_t) -> NSImage? {
        lock.withLock { images[pid] }
    }

    /// 在后台把这个应用程序的图标画成位图。已经有了或正在画就不再画。
    func prepare(pid: pid_t) {
        let start = lock.withLock { () -> Bool in
            guard images[pid] == nil, !pending.contains(pid) else { return false }
            pending.insert(pid)
            return true
        }
        guard start else { return }
        queue.async { [self] in
            var bitmap: NSImage?
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                let size = Self.pointSize
                var rect = NSRect(x: 0, y: 0, width: size * 2, height: size * 2)
                if let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    bitmap = NSImage(cgImage: image, size: NSSize(width: size, height: size))
                }
            }
            lock.withLock {
                pending.remove(pid)
                if let bitmap { images[pid] = bitmap }
            }
        }
    }

    /// 应用程序退出后它的进程号可能被重用：丢掉旧图标。
    func forget(pid: pid_t) {
        lock.withLock { _ = images.removeValue(forKey: pid) }
    }
}

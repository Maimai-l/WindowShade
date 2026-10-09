// 应用程序信息的短时缓存：进程号 → 应用程序名、bundle ID，1 秒过期。
// 应用程序名和 bundle ID 在会话内不会变化；高频路径（appProfile 解析、日志、菜单）不再反复构造 NSRunningApplication。
// 窗口帧与标题分别由 WindowListCache / ShadeState 覆盖，这里不重复缓存。

import Cocoa

/// `apps` 只在持有 `lock` 时读写，可以从任意线程调用。
final class WindowRegistry: @unchecked Sendable {
    static let shared = WindowRegistry()

    private struct AppEntry {
        let name: String
        let bundleID: String
        let at: CFAbsoluteTime
    }

    private let lock = NSLock()
    private let ttl: TimeInterval = 1.0
    private var apps: [pid_t: AppEntry] = [:]

    func appInfo(pid: pid_t) -> (name: String, bundleID: String)? {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        guard let entry = apps[pid], now - entry.at < ttl else {
            if apps[pid] != nil { apps.removeValue(forKey: pid) }
            return nil
        }
        return (entry.name, entry.bundleID)
    }

    func cacheAppInfo(pid: pid_t, name: String, bundleID: String) {
        lock.lock()
        apps[pid] = AppEntry(name: name, bundleID: bundleID, at: CFAbsoluteTimeGetCurrent())
        if apps.count > 128 {
            let now = CFAbsoluteTimeGetCurrent()
            apps = apps.filter { now - $0.value.at < ttl }
        }
        lock.unlock()
    }
}

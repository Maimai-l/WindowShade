// 登录时自动启动的状态。
//
// 向系统查一次登录项（SMAppService.status）要等系统的后台服务回话，在主线程上查会让界面停住，
// 点击和按键都没有反应（2026-10-09 CI 场景 C15 打开设置窗口时停了 0.6 至 0.7 秒）。
// 所以这里只在后台线程查询和注册；设置窗口读最近一次查到的结果，结果变了再刷新。

import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginState {
    /// 最近一次查到的状态。启动后在后台查第一次，查到之前开关显示为关。
    private(set) static var status: SMAppService.Status = .notRegistered
    /// 这一次查完要通知的调用方，正在查时又来的也排在这里，不另查一次；结果没变、或查询期间改过登录项时不通知。
    private static var waiting: [@MainActor @Sendable () -> Void] = []
    private static var querying = false
    /// 注册或取消开始时加一，做完时再加一。查询、注册或取消回来时这个数变了，说明期间改过登录项，
    /// 回来的结果可能是改之前的，不写进 status。
    private static var generation = 0

    /// 在后台查一次；结果变了才在主线程调用 changed。上一次还没查完时不重复查，
    /// changed 等那一次查完再按它的结果调用；查询期间改过登录项时结果作废，也不调用。
    static func refresh(changed: @escaping @MainActor @Sendable () -> Void) {
        waiting.append(changed)
        guard !querying else { return }
        querying = true
        let startedAt = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let latest = SMAppService.mainApp.status
            DispatchQueue.main.async {
                querying = false
                let callers = waiting
                waiting = []
                guard startedAt == generation, latest != status else { return }
                status = latest
                callers.forEach { $0() }
            }
        }
    }

    /// 在后台注册或取消登录项。开关先按用户的选择显示，做完再按系统的结果更正；
    /// 做完在主线程调用 done，失败时参数是错误说明，成功时是 nil。
    static func set(_ on: Bool, done: @escaping @MainActor @Sendable (String?) -> Void) {
        status = on ? .enabled : .notRegistered
        generation += 1
        let startedAt = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String?
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            let latest = SMAppService.mainApp.status
            DispatchQueue.main.async {
                if startedAt == generation { status = latest }
                generation += 1
                wlog("launch-at-login: \(on ? "register" : "unregister") status=\(latest)")
                done(failure)
            }
        }
    }
}

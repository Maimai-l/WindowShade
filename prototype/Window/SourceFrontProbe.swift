// 展开后判断原窗口是否已排到最前、它的应用程序是否在前台（撤卷帘条、结束“看一眼”都要等这两件事）。
//
// 判断要向窗口服务器查一次窗口列表。窗口服务器正忙时，查询要等它：2026-10-17 CI 场景 L01 里
// 展开后每帧在主线程上查一次，其中一次查询让主线程停了 530 毫秒（停顿时的采样都在 `CGWindowListCopyWindowInfo`
// 内部的 `SLWindowListCopyWindowInfo` 里）。所以查询放在后台队列上，每个 SourceFrontProbe 同一时间只有一次查询；
// 主线程每帧只发起查询、读最近一次的结果。

import Cocoa

@MainActor
final class SourceFrontProbe {
    /// 一次查询的结果：原窗口标题栏之上有没有别的应用程序的普通窗口，原窗口属于哪个进程。
    struct Answer: Sendable {
        let inFront: Bool
        let ownerPID: pid_t?
    }

    private static let queue = DispatchQueue(label: "com.windowshade.source-front", qos: .userInitiated)
    private let id: CGWindowID
    private let query: @Sendable (CGWindowID) -> Answer
    private let frontmostPID: () -> pid_t?
    private var asking = false
    /// 最近一次查询的结果；第一次查询结束前为 nil。
    private(set) var latest: Answer?

    init(id: CGWindowID,
         query: @escaping @Sendable (CGWindowID) -> Answer = SourceFrontProbe.systemQuery,
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.id = id
        self.query = query
        self.frontmostPID = frontmostPID
    }

    /// 没有查询在进行时，在后台队列上查一次，结果回到主线程后写进 latest；上一次查询还没结束时什么也不做。
    func poll() {
        guard !asking else { return }
        asking = true
        let id = id, query = query
        Self.queue.async {
            let answer = query(id)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.latest = answer
                    self?.asking = false
                }
            }
        }
    }

    /// 最近一次查询结果是原窗口已排到最前，而且它的应用程序此刻在前台。还没有结果时为 false。
    var ready: Bool {
        guard let latest, latest.inFront, let owner = latest.ownerPID else { return false }
        return frontmostPID() == owner
    }

    /// 向窗口服务器查一次。在后台队列上调用。
    nonisolated static func systemQuery(_ id: CGWindowID) -> Answer {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let owner = windows.first { number($0) == id }.flatMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
        return Answer(inFront: inFront(id, windows: windows, selfPID: ProcessInfo.processInfo.processIdentifier),
                      ownerPID: owner)
    }

    /// windows 是屏幕上的窗口，按从前到后排列。原窗口标题栏那一条之上没有别的应用程序的普通窗口时为 true；
    /// WindowShade 自己的窗口（卷帘条、看一眼的画面）和菜单栏等其他层级的窗口不算。原窗口不在列表里时为 false。
    nonisolated static func inFront(_ id: CGWindowID, windows: [[String: Any]], selfPID: pid_t) -> Bool {
        guard let index = windows.firstIndex(where: { number($0) == id }), let frame = bounds(windows[index]) else { return false }
        let titleBand = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(60, frame.height))
        return !windows[..<index].contains { info in
            ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) == 0
                && (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != selfPID
                && (bounds(info)?.intersects(titleBand) ?? false)
        }
    }

    private nonisolated static func number(_ info: [String: Any]) -> CGWindowID? {
        (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    private nonisolated static func bounds(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }
}

// 找回窗口（Recovery/Rescue.swift）的判定：哪些恢复记录还要动窗口，哪些只删掉记录。
// 原则：用户已经看得见的窗口，找回不再按恢复记录移动它、取消隐藏或带到最前；找回做了几次仍不见效就放弃，不一直重试。

import Foundation

/// 用户现在看得见这扇窗口：位置在屏幕上，应用程序没有隐藏，窗口没有最小化，也不是透明的。
/// 记录停在“已收起”或“展开中”、窗口却已经看得见时，说明它已经回来了（用户唤回、WindowShade 退出前已经放回），
/// 只删掉记录。再按记录放回，会把用户已经拖走的窗口拉回原处，把用户隐藏的应用程序又取消隐藏。
func windowUserVisible(windowOnScreen: Bool, appHidden: Bool, minimized: Bool, transparent: Bool) -> Bool {
    windowOnScreen && !appHidden && !minimized && !transparent
}

/// 窗口的透明度低到看不见。WindowShade 用 SkyLight 收起时把透明度设成 0，窗口留在原处；读不到透明度时不算透明。
func windowLooksTransparent(alpha: Double?) -> Bool {
    guard let alpha, alpha.isFinite else { return false }
    return alpha < 0.05
}

/// 找回最多做这么多次（含第一次），之后窗口仍然看不见就放弃。
let journalRescueMaxAttempts = 3

/// 第 attempts 次找回之后窗口仍然看不见：到次数就放弃，删掉记录，不再每 30 秒挪一次那扇窗口。
func journalRescueGivesUp(attempts: Int) -> Bool {
    attempts >= journalRescueMaxAttempts
}

/// 恢复记录还可能对上那扇窗口吗（匹配条件见 Journal.swift 的 journalMatches）。对不上的记录不会再有用，
/// 留着只会让定时检查一直开着、每 30 秒查询一遍所有应用程序的窗口，直到 14 天后过期。以下情况直接删掉：
/// - 记录里的进程已经退出：窗口随进程一起没了；
/// - 这个进程号的应用程序是记录写下之后才启动的（应用程序重新打开过，或进程号给了别的程序）。
/// 窗口服务器查不到这扇窗口时不删：随应用程序一起隐藏的窗口，窗口服务器可能查不到；记录删掉了，
/// WindowShade 崩溃后重新启动时就找不回这扇窗口（场景 L02，macOS 14.5）。
func journalEntryCanStillMatch(processRunning: Bool, processLaunchedAt: Double?, createdAt: Double?) -> Bool {
    guard processRunning else { return false }
    if let createdAt, let processLaunchedAt, createdAt < processLaunchedAt - 1 { return false }
    return true
}

/// 恢复记录里有没有不属于正在进行的操作的记录（WindowShade 上次退出时留下的，或展开后一直没能确认的）。
/// inUse 是已收起、正在收起、正在展开的窗口。有这样的记录就要按时找回，不管现在有没有别的窗口收起着：
/// 窗口可能好几天都收起着，只在没有卷帘条时才找回，那些窗口就一直回不来。
func journalHasOrphanEntries(journalIDs: [UInt32], inUse: Set<UInt32>) -> Bool {
    journalIDs.contains { !inUse.contains($0) }
}

/// 扫描停在停放位置上、没有恢复记录对应的窗口：只在没有任何窗口收起着、正在收起或展开时做。
/// 收起着的窗口也停在停放位置，扫描分不出哪扇是 WindowShade 现在藏着的。
func parkedWindowScanAllowed(inUse: Set<UInt32>) -> Bool {
    inUse.isEmpty
}

/// 展开在应用程序的队列上做完、回到主线程时，这次展开是否仍然有效。应用程序慢时，窗口已经回来、
/// 但带到最前还没做完，用户就可能又收起了它：之后的校正和确认都属于上一次展开，不能再做。
/// 确认会把这扇窗口的恢复记录标成“展开中”、看到窗口还在原处就删掉，删的是新一次收起的记录。
/// issued 是这次展开发出的令牌，current 是现在登记的令牌（收起一开始就清掉它）。
func restoreCompletionStillCurrent(issued: UUID, current: UUID?, foldedOrFolding: Bool) -> Bool {
    current == issued && !foldedOrFolding
}

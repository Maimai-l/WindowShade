// 找回窗口（Recovery/Rescue.swift）的判定：哪些恢复记录还要动窗口，哪些只删掉记录。
// 原则：用户已经看得见的窗口，恢复记录不再移动、取消隐藏或拉回它；找回做了几次仍不见效就放弃，不一直重试。

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

/// 找回做过之后窗口仍然看不见，最多再试这么多次（含第一次）。
let journalRescueMaxAttempts = 3

/// 第 attempts 次找回之后窗口仍然看不见：到次数就放弃，删掉记录，不再每 30 秒挪一次那扇窗口。
func journalRescueGivesUp(attempts: Int) -> Bool {
    attempts >= journalRescueMaxAttempts
}

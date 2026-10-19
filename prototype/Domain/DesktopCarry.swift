// 卷帘条和原窗口不在同一个桌面上时的处理（需求 S6，docs/design.md 第 3.2 节）。纯函数，不调用系统接口。

/// 卷帘条所在的桌面和原窗口登记的桌面不一致时的处理。
enum StripSpaceAction: Equatable, Sendable {
    /// 卷帘条和原窗口在同一个桌面上，不用处理。
    case none
    /// 用户按住卷帘条切到了别的桌面（按住时按 Control-左右方向键）：卷帘条留在新桌面，原窗口跟过去。
    case carry(to: UInt64)
    /// 用户没有按住卷帘条，卷帘条却到了别的桌面：挪回原窗口所在的桌面。
    case moveBack
}

/// 依据：2026-10-18 用户的日志，按住卷帘条切换桌面时，系统把卷帘条带到了新桌面，
/// WindowShade 又把它挪回了原窗口所在的桌面（`space: corrected overlay ... from=24 to=5`）。
func stripSpaceAction(stripSpace: UInt64, windowSpace: UInt64, stripHeldByPointer: Bool) -> StripSpaceAction {
    guard stripSpace != windowSpace else { return .none }
    return stripHeldByPointer ? .carry(to: stripSpace) : .moveBack
}

/// 这几种收起方式下，原窗口试着跟到新桌面：隐藏了整个应用程序、移到屏幕外、最小化的窗口还在原来的桌面上，
/// 用私有接口（PrivateSLSWindowMover.moveOtherAppWindow）把它移到新桌面，收起方式不变，展开时它就在新桌面。
/// 私有接口没能移过去时，卷帘条挪回原桌面。
/// 不能用最小化代替：取消最小化时，系统把窗口放回最小化之前所在的桌面（CI 场景 S6-carry，e9cf2c1）。
/// 没有移开的窗口、设成透明的窗口、WindowShade 自己的窗口、已关掉的快速查看窗口：不跟过去，卷帘条挪回原桌面。
/// 按住卷帘条切到别的桌面时，要不要试着把原窗口移过去。
enum CarryDecision: Equatable, Sendable {
    case attempt
    /// 这种收起方式不跟过去（canCarry）。
    case skipUnsupported
    /// 隐藏了应用程序的窗口，系统完整性保护开着：要移得先取消隐藏，设不了透明，窗口会露出来。
    case skipNeedsUnhide
    /// 这次运行里，同一种收起方式的窗口移过一次没移过去。
    case skipFailedBefore
}

/// 只按收起方式记失败，不记“这台 Mac 移不了”：用户 macOS 15.2 的日志（869b8b0）里，
/// 移到屏幕外的访达窗口跟过去了 4 次，隐藏了应用程序的“系统设置”窗口一次也没移过去。
func carryDecision(hide: HideMethod, systemIntegrityEnabled: Bool, failedBefore: Set<HideMethod>) -> CarryDecision {
    guard canCarry(hide) else { return .skipUnsupported }
    if failedBefore.contains(hide) { return .skipFailedBefore }
    if hide == .hidden && systemIntegrityEnabled { return .skipNeedsUnhide }
    return .attempt
}

func canCarry(_ hide: HideMethod) -> Bool {
    switch hide {
    case .hidden, .offscreen, .privateOffscreen, .minimized: return true
    case .none, .privateAlpha, .ownWindowOrderedOut, .quickLookClosed: return false
    }
}

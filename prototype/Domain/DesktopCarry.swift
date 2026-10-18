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

/// 原窗口跟到新桌面的办法。别的应用程序的窗口，macOS 没有公开接口能移到别的桌面，私有接口从 macOS 14.5 起也不起作用。
/// 取消最小化时，系统把窗口放到当前桌面，所以在原桌面上把它最小化，展开时它就出现在新桌面。
enum CarryMethod: Equatable, Sendable {
    /// 已经最小化，展开时系统把它放到当前桌面。
    case alreadyMinimized
    /// 改成最小化。隐藏了整个应用程序的，先取消隐藏，窗口回到原桌面上（用户这时在新桌面，看不到），再最小化。
    case minimize(unhideAppFirst: Bool)
    /// 没有移开的窗口、设成透明的窗口、WindowShade 自己的窗口、已关掉的快速查看窗口：不跟过去，卷帘条挪回原桌面。
    case notSupported
}

func carryMethod(for hide: HideMethod) -> CarryMethod {
    switch hide {
    case .minimized: return .alreadyMinimized
    case .hidden: return .minimize(unhideAppFirst: true)
    case .offscreen, .privateOffscreen: return .minimize(unhideAppFirst: false)
    case .none, .privateAlpha, .ownWindowOrderedOut, .quickLookClosed: return .notSupported
    }
}

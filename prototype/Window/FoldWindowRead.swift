// 收起前读窗口（docs/design.md 第 5.4 节第 1、2 步）：位置、大小、角色、标题、外框、全屏、最小化。
// 全部是对另一个进程的同步辅助功能调用，对方忙时一次要等几百毫秒（访达的外框解析实测 274ms），
// 所以在后台队列上做；主线程只等结果。

import Cocoa

struct FoldWindowReadout {
    let pos: CGPoint
    let size: CGSize
    let role: String?
    /// 是窗口，或 Adobe 有窗口服务器窗口支撑的工作区（AXLayoutArea）。
    let isWindow: Bool
    let title: String
    let profile: WindowChromeProfile
    let fullScreen: Bool
    let minimized: Bool
    let quickLookReopenURL: URL?
}

private let foldReadQueue = DispatchQueue(label: "WindowShade.fold-read", qos: .userInteractive,
                                          attributes: .concurrent)

/// 任意线程。取不到位置或大小时返回 nil。
func readWindowForFold(_ win: AXUIElement, id: CGWindowID, pid: pid_t,
                       localChromeHeight: CGFloat?, preparedProfile: WindowChromeProfile?) -> FoldWindowReadout? {
    guard let pos = axPosition(win), let size = axSize(win) else { return nil }
    let role = axRole(win)
    // Adobe AE/Premiere 工作区窗口的 role 是 AXLayoutArea：有 layer-0 真实
    // CGWindow 背书时按窗口放行（见 isWindowLikeRole），其余非窗口角色照旧拒绝。
    let isWindow = role == kAXWindowRole as String
        || (isWindowLikeRole(role, pid: pid) && cgWindowLayer(id) == 0)
    let title = axTitle(win)
    let profile = preparedProfile ?? ChromeProfileCache.shared.profile(
        id: id, win: win, pos: pos, size: size, pid: pid, title: title, localChromeHeight: localChromeHeight)
    return FoldWindowReadout(pos: pos, size: size, role: role, isWindow: isWindow, title: title, profile: profile,
                             fullScreen: axBoolAttribute(win, "AXFullScreen"),
                             minimized: axBoolAttribute(win, kAXMinimizedAttribute as String),
                             quickLookReopenURL: profile.isQuickLook ? quickLookReopenURL(for: win) : nil)
}

/// 在后台队列上读，读完回到调用方。元素和结果都不是 Sendable：用 HandOff 交接，
/// 调用方在等待期间不使用它们。
func readWindowForFoldInBackground(_ input: HandOff<(win: AXUIElement, preparedProfile: WindowChromeProfile?)>,
                                   id: CGWindowID, pid: pid_t,
                                   localChromeHeight: CGFloat?) async -> HandOff<FoldWindowReadout?> {
    await withCheckedContinuation { continuation in
        foldReadQueue.async {
            continuation.resume(returning: HandOff(readWindowForFold(
                input.value.win, id: id, pid: pid, localChromeHeight: localChromeHeight,
                preparedProfile: input.value.preparedProfile)))
        }
    }
}

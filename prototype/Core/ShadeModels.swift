// 收起相关的值类型：生命周期阶段、标题栏外形（AdobeChromeProfile、WindowChromeProfile）、ShadeState、
// 收起时的调用选项。隐藏方式、外观模式、隐藏策略和收起计划在 Domain/。

import Cocoa

enum ShadeLifecycleStage: String {
    case preparing   // 恢复记录已写入，原窗口还没隐藏完
    case folded
    case restoring
    case cleaned
    case forwarded
}
struct AdobeChromeProfile {
    let kind: AdobeChromeKind
    let preservedChromeHeight: CGFloat
    let hitChromeHeight: CGFloat
    let canShade: Bool
    let reason: String

    static let none = AdobeChromeProfile(kind: .none,
                                         preservedChromeHeight: titleBarHeight,
                                         hitChromeHeight: titleBarHeight,
                                         canShade: true,
                                         reason: "non-adobe")
}

struct WindowChromeProfile {
    let hasToolbar: Bool
    let trafficLightHeight: CGFloat?
    let adobeProfile: AdobeChromeProfile
    let trafficLights: ProxyTrafficLightConfiguration
    let preciseChrome: Bool
    let toolbarlessStandardTitleBar: Bool
    let standardTitleBarOnly: Bool
    let hasContentBelowTitleBar: Bool
    let standardCropHeight: CGFloat
    let axBarHeight: CGFloat
    let hitBarHeight: CGFloat

    var isQuickLook: Bool {
        trafficLights.style == .quickLook
    }

    var boundaryName: String {
        if isQuickLook { return "quicklook-fixed" }
        if standardTitleBarOnly { return "standard-titlebar" }
        if preciseChrome { return "precise" }
        return "AX"
    }
}

// MARK: - 收起状态

// ShadeState 跟的是一扇真实的窗口，不是一个应用程序。存下的 CGWindowID 和几何信息是展开的依据：
// 只要系统允许，展开时就放回同一扇窗口，并对齐卷帘条当前的位置。
struct ShadeState {
    let foldTransactionID = UUID()
    let element: AXUIElement
    let sourceWindowID: CGWindowID
    let originalPosition: CGPoint
    var originalSize: CGSize
    let sourceDisplayID: CGDirectDisplayID?
    let sourceSpaceID: UInt64?
    let overlay: NSWindow?
    let overlayID: CGWindowID?
    var hide: HideMethod         // 原窗口实际被移开的方式（见 HideMethod）；延迟验证补救时可能改写
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let appearanceMode: ShadeAppearanceMode
    var lifecycleStage: ShadeLifecycleStage
    var previewImage: NSImage?
    let quickLookReopenURL: URL?
    let ignoreAppRevealUntil: Date
    var observer: AXObserver?    // 监听窗口被外部唤回（收起后下一轮 RunLoop 才注册）
}

struct ShadeInvocationOptions {
    let forcedAppearanceMode: ShadeAppearanceMode?
    let capturePreview: Bool
    let emitFoldFeedback: Bool
    let rebuildMenuAfterInstall: Bool
}

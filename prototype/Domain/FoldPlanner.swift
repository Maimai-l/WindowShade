// 收起计划（docs/design.md 第 5.4 节第 3 步）：由窗口信息、应用程序配置和用户设置决定收不收、
// 卷帘条用什么样子、原窗口怎么移开。纯函数，不调用系统接口；调用方先读好窗口信息再交进来。

import Foundation

enum ShadeAppearanceMode: String, Sendable {
    case nativeScreenshot
    case proxyTitleBar
    /// 收起后窗口在原处缩成一张缩略图（设置里“收起后显示”的第三项，见 App/Thumbnail.swift）。
    case thumbnail
}

enum AdobeChromeKind: String, Sendable {
    case none
    case applicationFrame
    case tabbedDocumentFrame
    case floatingDocumentWindow
    case floatingPanel
}

struct ShadePlan: Equatable, Sendable {
    let mode: ShadeAppearanceMode
    let policy: ShadePolicy
    let reason: String
}

/// 收起前读到的窗口信息。
struct FoldFacts: Sendable {
    var visibleOnActiveSpace = true
    var fullScreen = false
    var minimized = false
    /// 窗口上挂着对话框（sheet），例如“是否保存”。
    var hasSheet = false
    /// 应用程序弹出了独立的模态提示框（例如 NSAlert）：用户要先回答它。
    var appHasModalDialog = false
    var isQuickLook = false
    /// 快速查看窗口能不能在展开时重新打开：收起时读到了它显示的文件。
    var quickLookReopenable = true
    var adobeKind = AdobeChromeKind.none
    var adobeCanShade = true
    var adobeReason = ""
    /// 窗口有标题栏，规则见 Window/ChromeProfile.swift 的 windowHasTitleBar。
    var hasTitleBar = true
    var windowHeight: CGFloat = 600
    /// 收起后卷帘条的高度。
    var barHeight: CGFloat = 28
}

/// 和这次收起有关的用户设置与权限。
struct FoldSettings: Sendable {
    var appearance = ShadeAppearanceMode.nativeScreenshot
    /// 调用方指定的样子；为 nil 时按用户设置，并在截不了图时退回图标和标题。
    var forcedAppearance: ShadeAppearanceMode?
    var screenRecordingGranted = true
    /// macOS 14 及以上才有 ScreenCaptureKit 的单张截图。
    var screenCaptureKitAvailable = true
}

/// 不收起的原因。log 写进日志。notice 显示在菜单栏上，说用户看得到的原因，不超过 14 个字，多了会被截断。
enum FoldRejection: Error, Equatable, Sendable {
    case offSpace
    case fullScreen
    case minimized
    case hasSheet
    case modalDialog
    case quickLookWithoutFile
    case adobePanel(String)
    case noTitleBar
    case notWorthFolding

    var log: String {
        switch self {
        case .offSpace: return "invisible/off-space window"
        case .fullScreen: return "fullscreen window"
        case .minimized: return "minimized window"
        case .hasSheet: return "window has a sheet"
        case .modalDialog: return "app shows a modal dialog"
        case .quickLookWithoutFile: return "quick look preview with no file to reopen"
        case .adobePanel(let detail): return "adobe panel \(detail)"
        case .noTitleBar: return "window has no title bar"
        case .notWorthFolding: return "folding would save too little height"
        }
    }

    var notice: String {
        switch self {
        case .offSpace: return "窗口在屏幕外，不能收起"
        case .fullScreen: return "全屏时不能收起"
        case .minimized: return "已最小化的窗口不能收起"
        case .hasSheet: return "请先关闭窗口上的对话框"
        case .modalDialog: return "请先关闭对话框"
        case .quickLookWithoutFile: return "找不到快速查看的文件"
        case .adobePanel: return "浮动面板不能收起"
        case .noTitleBar: return "没有标题栏的窗口不能收起"
        case .notWorthFolding: return "窗口太矮，不能收起"
        }
    }
}

enum FoldDecision: Equatable, Sendable {
    case reject(FoldRejection)
    case fold(ShadePlan)
}

enum FoldPlanner {
    /// 收起至少要省下这么高。
    static let minimumSavedHeight: CGFloat = 60

    /// 收起值不值得：省下的高度不到 minimumSavedHeight，或卷帘条占了窗口一半以上，就不值得。
    static func worthFolding(windowHeight: CGFloat, barHeight: CGFloat) -> Bool {
        windowHeight - barHeight >= minimumSavedHeight && barHeight * 2 <= windowHeight
    }

    static func decide(facts: FoldFacts, profile: AppProfile, settings: FoldSettings) -> FoldDecision {
        guard facts.visibleOnActiveSpace else { return .reject(.offSpace) }
        guard !facts.fullScreen else { return .reject(.fullScreen) }
        guard !facts.minimized else { return .reject(.minimized) }
        guard !facts.hasSheet else { return .reject(.hasSheet) }
        guard !facts.appHasModalDialog else { return .reject(.modalDialog) }
        // 快速查看窗口收起时要关掉，展开时靠文件路径重新打开；读不到路径就关掉，展开时预览找不回来（场景 A32）。
        guard !facts.isQuickLook || facts.quickLookReopenable else { return .reject(.quickLookWithoutFile) }
        guard facts.hasTitleBar else { return .reject(.noTitleBar) }
        guard worthFolding(windowHeight: facts.windowHeight, barHeight: facts.barHeight) else {
            return .reject(.notWorthFolding)
        }
        guard facts.adobeKind != .floatingPanel, facts.adobeCanShade else {
            return .reject(.adobePanel("kind=\(facts.adobeKind.rawValue) reason=\(facts.adobeReason)"))
        }

        let policy: ShadePolicy = facts.isQuickLook ? .closeQuickLookPreview : profile.hiding
        var mode = settings.forcedAppearance ?? settings.appearance
        var reason = settings.forcedAppearance == nil ? "user-mode" : "forced-\(mode.rawValue)"
        if facts.isQuickLook { reason += "-quicklook" }

        guard settings.forcedAppearance == nil else { return .fold(ShadePlan(mode: mode, policy: policy, reason: reason)) }
        // 缩略图要收起那一刻的截图：截不了的时候和“原标题栏”一样，退回图标和标题。
        let needsScreenshot = mode == .nativeScreenshot || mode == .thumbnail
        if needsScreenshot && !settings.screenRecordingGranted {
            mode = .proxyTitleBar
            reason = "screen-recording-missing"
        }
        if needsScreenshot && !settings.screenCaptureKitAvailable {
            mode = .proxyTitleBar
            reason = "screencapturekit-unavailable"
        }
        // Adobe 的标题栏是自绘的，图标和标题画不出它：有截图权限时一律用截图。
        if facts.adobeKind != .none, mode == .proxyTitleBar,
           settings.screenRecordingGranted, settings.screenCaptureKitAvailable {
            mode = .nativeScreenshot
            reason = "adobe-\(facts.adobeKind.rawValue)-native-chrome"
        }
        return .fold(ShadePlan(mode: mode, policy: policy, reason: reason))
    }
}

// 收起计划（docs/design.md 第 5.4 节第 3 步）：由窗口信息、应用程序配置和用户设置决定收不收、
// 卷帘条用什么样子、原窗口怎么移开。纯函数，不调用系统接口；调用方先读好窗口信息再交进来。

import Foundation

enum ShadeAppearanceMode: String, Sendable {
    case nativeScreenshot
    case proxyTitleBar
    /// 收起后窗口在原处缩成一张缩略图（设置里“收起后的样子”的第三项，见 App/Thumbnail.swift）。
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
    var isQuickLook = false
    var adobeKind = AdobeChromeKind.none
    var adobeCanShade = true
    var adobeReason = ""
}

/// 和这次收起有关的用户设置与权限。
struct FoldSettings: Sendable {
    var appearance = ShadeAppearanceMode.nativeScreenshot
    /// 调用方指定的样子；为 nil 时按用户设置，并在截不了图时退回统一样式的标题栏。
    var forcedAppearance: ShadeAppearanceMode?
    var screenRecordingGranted = true
    /// macOS 14 及以上才有 ScreenCaptureKit 的单张截图。
    var screenCaptureKitAvailable = true
}

enum FoldDecision: Equatable, Sendable {
    case reject(String)
    case fold(ShadePlan)
}

enum FoldPlanner {
    static func decide(facts: FoldFacts, profile: AppProfile, settings: FoldSettings) -> FoldDecision {
        guard facts.visibleOnActiveSpace else { return .reject("invisible/off-space window") }
        guard !facts.fullScreen else { return .reject("fullscreen window") }
        guard !facts.minimized else { return .reject("minimized window") }
        guard facts.adobeKind != .floatingPanel, facts.adobeCanShade else {
            return .reject("adobe panel kind=\(facts.adobeKind.rawValue) reason=\(facts.adobeReason)")
        }

        let policy: ShadePolicy = facts.isQuickLook ? .closeQuickLookPreview : profile.hiding
        var mode = settings.forcedAppearance ?? settings.appearance
        var reason = settings.forcedAppearance == nil ? "user-mode" : "forced-\(mode.rawValue)"
        if facts.isQuickLook { reason += "-quicklook" }

        guard settings.forcedAppearance == nil else { return .fold(ShadePlan(mode: mode, policy: policy, reason: reason)) }
        // 缩略图要收起那一刻的截图：截不了的时候和“跟原来一样”一样，退回统一标题栏。
        let needsScreenshot = mode == .nativeScreenshot || mode == .thumbnail
        if needsScreenshot && !settings.screenRecordingGranted {
            mode = .proxyTitleBar
            reason = "screen-recording-missing"
        }
        if needsScreenshot && !settings.screenCaptureKitAvailable {
            mode = .proxyTitleBar
            reason = "screencapturekit-unavailable"
        }
        // Adobe 的标题栏是自绘的，统一样式的标题栏画不出它：有截图权限时一律用截图。
        if facts.adobeKind != .none, mode == .proxyTitleBar,
           settings.screenRecordingGranted, settings.screenCaptureKitAvailable {
            mode = .nativeScreenshot
            reason = "adobe-\(facts.adobeKind.rawValue)-native-chrome"
        }
        return .fold(ShadePlan(mode: mode, policy: policy, reason: reason))
    }
}

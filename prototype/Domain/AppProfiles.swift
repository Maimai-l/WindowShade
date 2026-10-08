// 应用程序配置表（docs/design.md 第 5.3 节）：按应用程序区分的处理全部写在这张表里，
// 收起、截图、标题栏识别的代码只读配置项，不判断 bundle ID。
// 领域层：只依赖 Foundation，不读当前时间，单元测试直接编译这个文件（tests/run-domain-tests.sh）。

import Foundation

/// 原窗口实际被移开的方式（写进恢复记录，展开时按它移回）。
enum HideMethod: String, Sendable { case none, offscreen, privateOffscreen, privateAlpha, hidden, minimized, ownWindowOrderedOut, quickLookClosed }

/// 把原窗口移出视线的方式。只描述“怎么藏”，不进入面向用户的文字。
enum ShadePolicy: Equatable, Sendable {
    /// 先移到屏幕外，不行再按顺序退回；allowAppHide 为 false 时不隐藏整个应用程序。
    case offscreenThenFallback(allowAppHide: Bool)
    /// 移到屏幕外，保持窗口仍在绘制（看一眼要用实时画面的应用程序）。
    case offscreenForLivePreview
    /// 原窗口是该应用程序唯一的窗口时隐藏整个应用程序，否则移开或最小化。
    case hiddenIfSingleWindowElseMinimized(allowAppHide: Bool)
    /// 快速查看窗口：关闭，展开时重新打开同一个文件。
    case closeQuickLookPreview

    /// 这种方式会不会隐藏整个应用程序（只在原窗口是唯一窗口时才会）。
    var mayHideApp: Bool {
        switch self {
        case .offscreenThenFallback(let allowAppHide), .hiddenIfSingleWindowElseMinimized(let allowAppHide):
            return allowAppHide
        case .offscreenForLivePreview:
            return true
        case .closeQuickLookPreview:
            return false
        }
    }

    var logDescription: String {
        switch self {
        case .offscreenThenFallback(let allowAppHide):
            return "offscreenThenFallback(allowAppHide:\(allowAppHide))"
        case .offscreenForLivePreview:
            return "offscreenForLivePreview"
        case .hiddenIfSingleWindowElseMinimized(let allowAppHide):
            return "hiddenIfSingleWindowElseMinimized(allowAppHide:\(allowAppHide))"
        case .closeQuickLookPreview:
            return "closeQuickLookPreview"
        }
    }
}

struct AppProfile: Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case standard, finder, safari, codex, systemSettings, weChat, telegram, elpass, stickies, calculator, adobe
    }

    /// 匹配条件，bundle ID 和名称都先转成小写再比。
    enum Match: Equatable, Sendable {
        case bundle(String)
        case bundlePrefix(String)
        case bundleContains(String)
        case name(String)
        case namePrefix(String)
        case nameContains(String)

        func matches(bundleID: String, name: String) -> Bool {
            switch self {
            case .bundle(let value): return bundleID == value
            case .bundlePrefix(let value): return bundleID.hasPrefix(value)
            case .bundleContains(let value): return bundleID.contains(value)
            case .name(let value): return name == value
            case .namePrefix(let value): return name.hasPrefix(value)
            case .nameContains(let value): return name.contains(value)
            }
        }
    }

    /// 卷帘条保留多高的一条。
    enum ChromeRule: Equatable, Sendable {
        /// 先用辅助功能接口报告的标题栏高度，不可信时分析截图像素。
        case accessibility
        /// 只保留标准标题栏的高度。
        case standardTitleBarOnly
        /// 自绘标题栏：固定高度，只保留第一层可操作的控件带。
        case fixed(Double)
    }

    let id: ID
    let match: [Match]
    let hiding: ShadePolicy
    let chrome: ChromeRule
    /// 使用应用程序自带的收起功能（便笺的“折叠”）。
    let nativeShade: Bool
    /// 卷帘条可以横向拉宽。
    let stripResizable: Bool
    /// 采用这项配置的原因。
    let note: String

    init(_ id: ID, match: [Match], hiding: ShadePolicy = .hiddenIfSingleWindowElseMinimized(allowAppHide: true),
         chrome: ChromeRule = .accessibility, nativeShade: Bool = false, stripResizable: Bool = true, note: String) {
        self.id = id
        self.match = match
        self.hiding = hiding
        self.chrome = chrome
        self.nativeShade = nativeShade
        self.stripResizable = stripResizable
        self.note = note
    }

    var fixedChromeHeight: Double? {
        if case .fixed(let height) = chrome { return height }
        return nil
    }

    var usesStandardTitleBarOnly: Bool { chrome == .standardTitleBarOnly }
}

enum AppProfiles {
    /// 未列入下表的应用程序。
    static let standard = AppProfile(.standard, match: [],
        note: "默认：唯一窗口时隐藏整个应用程序，否则移到屏幕角落或最小化；标题栏高度取自辅助功能接口")

    /// 按顺序匹配，第一条匹配的生效。
    static let table: [AppProfile] = [
        AppProfile(.finder, match: [.bundle("com.apple.finder"), .name("finder")],
                   hiding: .hiddenIfSingleWindowElseMinimized(allowAppHide: false),
                   note: "不隐藏整个应用程序；原因未记录，沿用 Compatibility/Policies.swift"),
        AppProfile(.safari, match: [.bundle("com.apple.safari"), .name("safari")],
                   hiding: .offscreenThenFallback(allowAppHide: true),
                   note: "先移到屏幕外；原因未记录，沿用 Compatibility/Policies.swift"),
        AppProfile(.codex, match: [.bundleContains("codex"), .name("codex")],
                   hiding: .offscreenForLivePreview,
                   note: "移到屏幕外以保持窗口绘制，看一眼才有实时画面"),
        AppProfile(.systemSettings,
                   match: [.bundle("com.apple.systempreferences"), .bundle("com.apple.systemsettings"),
                           .name("system settings"), .name("settings"), .name("系統設定"), .name("系统设置")],
                   stripResizable: false,
                   note: "系统设置的窗口不能改变宽度，卷帘条也不允许拉宽"),
        AppProfile(.weChat,
                   match: [.bundle("com.tencent.xinwechat"), .bundle("com.tencent.wechat"),
                           .nameContains("wechat"), .nameContains("微信")],
                   chrome: .fixed(51.5),
                   note: "自绘标题栏：只保留交通灯、搜索框和工具按钮这一层，列表行不进卷帘条"),
        AppProfile(.telegram,
                   match: [.bundle("com.tdesktop.telegram"), .bundle("ru.keepcoder.telegram"),
                           .bundle("org.telegram.desktop"), .nameContains("telegram")],
                   chrome: .standardTitleBarOnly,
                   note: "自绘标题栏，只保留标准标题栏的高度；原因未记录，沿用 Compatibility/Policies.swift"),
        AppProfile(.elpass, match: [.bundle("app.elpass.macos"), .nameContains("elpass")],
                   chrome: .fixed(50.5),
                   note: "自绘标题栏：只保留第一层控件带"),
        AppProfile(.stickies,
                   match: [.bundle("com.apple.stickies"), .nameContains("stickies"),
                           .nameContains("便條"), .nameContains("便笺"), .nameContains("便条")],
                   nativeShade: true,
                   note: "便笺自带收起功能，双击交给便笺自己处理"),
        AppProfile(.calculator,
                   match: [.bundle("com.apple.calculator"), .name("calculator"), .name("計算機"), .name("计算器")],
                   stripResizable: false,
                   note: "计算器的窗口不能改变宽度，卷帘条也不允许拉宽"),
        AppProfile(.adobe, match: [.bundlePrefix("com.adobe."), .namePrefix("adobe ")],
                   note: "标题栏区域由 Window/ChromeProfile.swift 中的 Adobe 外框分析确定；面板不收起"),
    ]

    static func profile(bundleID: String, name: String) -> AppProfile {
        let bundleID = bundleID.lowercased()
        let name = name.lowercased()
        return table.first { profile in
            profile.match.contains { $0.matches(bundleID: bundleID, name: name) }
        } ?? standard
    }
}

// 需求：S5、A1、F1（docs/testing.md 第 3.1、3.2、3.4 节）；应用程序配置表（docs/design.md 第 5.3 节）。
// 领域层的单元测试：应用程序配置的匹配、收起计划的决定。只编译 Domain/，不调用系统接口。

import Foundation

@main
struct DomainTests {
    static func main() {
        var t = TestSuite("domain")

        t.section("P1", "每个列入配置表的应用程序按 bundle ID 和名称都能匹配到自己的配置")
        let expected: [(String, String, AppProfile.ID)] = [
            ("com.apple.finder", "Finder", .finder),
            ("com.apple.Safari", "Safari", .safari),
            ("com.openai.codex", "Codex", .codex),
            ("com.apple.systempreferences", "System Settings", .systemSettings),
            ("", "系统设置", .systemSettings),
            ("com.tencent.xinWeChat", "WeChat", .weChat),
            ("", "微信", .weChat),
            ("ru.keepcoder.Telegram", "Telegram", .telegram),
            ("app.elpass.macos", "Elpass", .elpass),
            ("com.apple.Stickies", "Stickies", .stickies),
            ("", "便笺", .stickies),
            ("com.apple.calculator", "Calculator", .calculator),
            ("com.adobe.Photoshop", "Adobe Photoshop 2026", .adobe),
            ("", "Adobe Illustrator", .adobe),
            ("com.apple.TextEdit", "TextEdit", .standard),
            ("", "", .standard),
        ]
        for (bundle, name, id) in expected {
            t.expect(AppProfiles.profile(bundleID: bundle, name: name).id == id,
                     "\(bundle.isEmpty ? name : bundle) → \(id.rawValue)")
        }
        t.expect(Set(AppProfiles.table.map(\.id)).count == AppProfiles.table.count, "配置表中每个应用程序只出现一次")
        t.expect(AppProfiles.table.allSatisfy { !$0.match.isEmpty && !$0.note.isEmpty },
                 "每条配置都有匹配条件和原因说明")

        t.section("P2", "配置项与原来的按应用程序判断一致")
        let finder = AppProfiles.profile(bundleID: "com.apple.finder", name: "Finder")
        t.expect(finder.hiding == .hiddenIfSingleWindowElseMinimized(allowAppHide: false) && !finder.hiding.mayHideApp,
                 "访达不隐藏整个应用程序")
        t.expect(AppProfiles.profile(bundleID: "com.apple.safari", name: "").hiding == .offscreenThenFallback(allowAppHide: true),
                 "Safari 先移到屏幕外")
        t.expect(AppProfiles.profile(bundleID: "com.openai.codex", name: "").hiding == .offscreenForLivePreview,
                 "Codex 移到屏幕外，保持绘制")
        t.expect(AppProfiles.profile(bundleID: "com.tencent.xinwechat", name: "").fixedChromeHeight == 51.5,
                 "微信只保留 51.5 点高的控件带")
        t.expect(AppProfiles.profile(bundleID: "app.elpass.macos", name: "").fixedChromeHeight == 50.5,
                 "Elpass 只保留 50.5 点高的控件带")
        t.expect(AppProfiles.profile(bundleID: "org.telegram.desktop", name: "").usesStandardTitleBarOnly,
                 "Telegram 只保留标准标题栏")
        t.expect(AppProfiles.profile(bundleID: "com.apple.stickies", name: "").nativeShade, "便笺用自带的收起功能")
        t.expect(!AppProfiles.profile(bundleID: "com.apple.calculator", name: "").stripResizable
                    && !AppProfiles.profile(bundleID: "com.apple.systemsettings", name: "").stripResizable,
                 "计算器和系统设置的卷帘条不能拉宽")
        let standard = AppProfiles.standard
        t.expect(standard.hiding == .hiddenIfSingleWindowElseMinimized(allowAppHide: true) && standard.chrome == .accessibility
                    && standard.stripResizable && !standard.nativeShade,
                 "默认配置：可隐藏整个应用程序、标题栏高度取自辅助功能接口、卷帘条可拉宽")

        t.section("F1", "不收起的窗口")
        let settings = FoldSettings()
        let profile = AppProfiles.standard
        func decide(_ facts: FoldFacts, _ settings: FoldSettings = FoldSettings(), _ profile: AppProfile = AppProfiles.standard) -> FoldDecision {
            FoldPlanner.decide(facts: facts, profile: profile, settings: settings)
        }
        t.expect(decide(FoldFacts(visibleOnActiveSpace: false)) == .reject("invisible/off-space window"), "不在当前桌面的窗口不收起")
        t.expect(decide(FoldFacts(fullScreen: true)) == .reject("fullscreen window"), "全屏窗口不收起")
        t.expect(decide(FoldFacts(minimized: true)) == .reject("minimized window"), "已最小化的窗口不收起")
        // 缺陷回归（CI 场景 A10）：挂着“是否保存”这类对话框的窗口收起后，对话框跟着被移开，用户看不到要回答的问题。
        t.expect(decide(FoldFacts(hasSheet: true)) == .reject("window has a sheet"), "挂着对话框的窗口不收起")
        if case .reject = decide(FoldFacts(adobeKind: .floatingPanel)) {
            t.expect(true, "Adobe 浮动面板不收起")
        } else { t.expect(false, "Adobe 浮动面板不收起") }
        if case .reject = decide(FoldFacts(adobeKind: .applicationFrame, adobeCanShade: false)) {
            t.expect(true, "Adobe 外框分析判定不能收起时不收起")
        } else { t.expect(false, "Adobe 外框分析判定不能收起时不收起") }

        t.section("A1", "卷帘条的样子按用户设置")
        for mode in [ShadeAppearanceMode.nativeScreenshot, .proxyTitleBar, .thumbnail] {
            var chosen = settings
            chosen.appearance = mode
            t.expect(decide(FoldFacts(), chosen, profile) == .fold(ShadePlan(mode: mode, policy: profile.hiding, reason: "user-mode")),
                     "设置为 \(mode.rawValue) 时用 \(mode.rawValue)")
        }

        t.section("S5", "截不了图时改用统一样式的标题栏")
        for mode in [ShadeAppearanceMode.nativeScreenshot, .thumbnail] {
            t.expect(decide(FoldFacts(), FoldSettings(appearance: mode, screenRecordingGranted: false))
                        == .fold(ShadePlan(mode: .proxyTitleBar, policy: profile.hiding, reason: "screen-recording-missing")),
                     "\(mode.rawValue)：没有屏幕录制权限")
            t.expect(decide(FoldFacts(), FoldSettings(appearance: mode, screenCaptureKitAvailable: false))
                        == .fold(ShadePlan(mode: .proxyTitleBar, policy: profile.hiding, reason: "screencapturekit-unavailable")),
                     "\(mode.rawValue)：系统没有 ScreenCaptureKit")
        }
        t.expect(decide(FoldFacts(), FoldSettings(forcedAppearance: .nativeScreenshot, screenRecordingGranted: false))
                    == .fold(ShadePlan(mode: .nativeScreenshot, policy: profile.hiding, reason: "forced-nativeScreenshot")),
                 "调用方指定了样子时照用，不退回")

        t.section("P3", "按窗口和应用程序决定怎么移开原窗口")
        t.expect(decide(FoldFacts(isQuickLook: true))
                    == .fold(ShadePlan(mode: .nativeScreenshot, policy: .closeQuickLookPreview, reason: "user-mode-quicklook")),
                 "快速查看窗口：关闭，展开时重新打开")
        t.expect(decide(FoldFacts(), settings, finder) == .fold(ShadePlan(mode: .nativeScreenshot, policy: finder.hiding, reason: "user-mode")),
                 "其他窗口按应用程序配置")
        t.expect(decide(FoldFacts(adobeKind: .applicationFrame), FoldSettings(appearance: .proxyTitleBar))
                    == .fold(ShadePlan(mode: .nativeScreenshot, policy: profile.hiding, reason: "adobe-applicationFrame-native-chrome")),
                 "Adobe 的自绘标题栏有截图权限时总用截图")
        t.expect(decide(FoldFacts(adobeKind: .applicationFrame), FoldSettings(appearance: .proxyTitleBar, screenRecordingGranted: false))
                    == .fold(ShadePlan(mode: .proxyTitleBar, policy: profile.hiding, reason: "user-mode")),
                 "Adobe 没有截图权限时照用户设置")

        t.finish()
    }
}

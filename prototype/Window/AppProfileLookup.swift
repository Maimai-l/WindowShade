// 按进程取应用程序配置（Domain/AppProfiles.swift），以及由配置派生的几项判断。

import Cocoa

func appProfile(for pid: pid_t) -> AppProfile {
    AppProfiles.profile(bundleID: appBundleID(pid: pid), name: appDisplayName(pid: pid))
}

func shadePolicy(for pid: pid_t) -> ShadePolicy {
    appProfile(for: pid).hiding
}

func isElpass(pid: pid_t) -> Bool {
    appProfile(for: pid).id == .elpass
}

func isAdobeApp(pid: pid_t) -> Bool {
    appProfile(for: pid).id == .adobe
}

func usesStandardTitleBarOnly(pid: pid_t) -> Bool {
    appProfile(for: pid).usesStandardTitleBarOnly
}

func isStickies(pid: pid_t) -> Bool {
    appProfile(for: pid).nativeShade
}

func needsControlPaddedChrome(pid: pid_t) -> Bool {
    fixedNonstandardChromeHeight(pid: pid) != nil
}

// 微信、Elpass 这类自绘标题栏，按“第一层可操作的控件”裁切：只保留红绿灯、搜索框、标题和工具按钮，
// 以及它们上下的留白。下面的列表行、选中条、账号卡哪怕只露出一点，卷帘条看起来也就不像标题栏了。
func fixedNonstandardChromeHeight(pid: pid_t) -> CGFloat? {
    appProfile(for: pid).fixedChromeHeight.map { CGFloat($0) }
}

func fallbackControlPaddedChromeHeight(pid: pid_t, minimum _: CGFloat) -> CGFloat? {
    if let fixed = fixedNonstandardChromeHeight(pid: pid) { return max(titleBarHeight, fixed) }
    return nil
}

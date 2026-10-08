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

// WeChat / Elpass 这类非标准窗口的诀窍是按“第一层可操作 chrome band”裁，
// 只保留交通灯、搜索框、标题/工具按钮和它们自己的上下 padding。
// 下面的列表行、选中条、账号卡即使只露一点，也会让折叠条失去标题栏语义。
func fixedNonstandardChromeHeight(pid: pid_t) -> CGFloat? {
    appProfile(for: pid).fixedChromeHeight.map { CGFloat($0) }
}

func fallbackControlPaddedChromeHeight(pid: pid_t, minimum _: CGFloat) -> CGFloat? {
    if let fixed = fixedNonstandardChromeHeight(pid: pid) { return max(titleBarHeight, fixed) }
    return nil
}

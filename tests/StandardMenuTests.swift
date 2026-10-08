// 应用菜单和状态栏菜单共用的构造：标准菜单、收起窗口的分区、标题截断和“关于”面板。
// 纯逻辑，不碰用户的设置和窗口。

import Cocoa

@main
enum StandardMenuTests {
    static var failures = 0
    static var checks = 0

    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(label)")
        }
    }

    static func main() {
        // @main 的入口在主线程。菜单测试要安装 NSApp.mainMenu。
        MainActor.assumeIsolated { standardMainMenu() }
        if failures == 0 {
            print("PASS: \(checks) standard menu checks")
        } else {
            print("FAILED: \(failures)/\(checks) standard menu checks")
            exit(1)
        }
    }

    static func standardMainMenu() {
        _ = NSApplication.shared
        let menu = StandardMenu.make(appName: "WindowShade", settingsTarget: nil,
                                     settingsAction: nil)
        NSApp.mainMenu = menu
        let titles = menu.items.compactMap { $0.submenu?.title }
        expect(titles.contains("编辑") && titles.contains("窗口"),
               "the agent app installs standard edit and window menus")
        guard let appMenu = menu.items.first?.submenu,
              let about = appMenu.items.first(where: { $0.title.hasPrefix("关于") }) else {
            expect(false, "the application menu exposes 关于")
            return
        }
        expect(about.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
                || about.action != nil,
               "关于 is wired to an action (custom panel or the system default)")
        // 折叠窗口的菜单分区：前 9 个内联带 ⌃⌘1…9，其余进“更多”子菜单。
        let few = (1...3).map { $0 }
        let fewSplit = StandardMenu.splitFoldedWindows(few)
        expect(fewSplit.inline == few && fewSplit.overflow.isEmpty,
               "a short folded-window list stays inline")
        let many = Array(1...20)
        let manySplit = StandardMenu.splitFoldedWindows(many)
        expect(manySplit.inline.count == StandardMenu.inlineFoldedWindowLimit
                && manySplit.overflow.count == 20 - StandardMenu.inlineFoldedWindowLimit,
               "a long list splits into inline shortcuts and an overflow submenu")
        expect(manySplit.inline + manySplit.overflow == many,
               "the split preserves order and never drops a window")
        expect(StandardMenu.foldedWindowShortcut(index: 0) == "1"
                && StandardMenu.foldedWindowShortcut(index: 8) == "9",
               "the first nine windows carry ⌃⌘1…9 shortcuts")
        expect(StandardMenu.foldedWindowShortcut(index: 9) == nil
                && StandardMenu.foldedWindowShortcut(index: -1) == nil,
               "the overflow items carry no shortcut")
        // 菜单标题统一截断：短标题原样，长标题按上限收尾，两处列表共用同一规则。
        expect(StandardMenu.menuTitle("窗口 1") == "窗口 1",
               "a short menu title is left unchanged")
        let long = String(repeating: "长", count: 60)
        let truncated = StandardMenu.menuTitle(long)
        expect(truncated.count == 42 && truncated.hasSuffix("…"),
               "a long menu title is truncated to the shared limit")
        expect(StandardMenu.menuTitle(long, limit: 10).count == 10,
               "the truncation limit is configurable (used by tests and future callers)")
        expect(StandardMenu.menuTitle("  前后有空白  ") == "前后有空白",
               "menu titles are trimmed before truncation")

        // “关于”面板的内容来自同一份构造：版本、许可与仓库链接。
        let aboutOptions = StandardMenu.aboutPanelOptions(version: "1.0.14", build: "14")
        expect((aboutOptions[.applicationVersion] as? String) == "1.0.14"
                && (aboutOptions[.version] as? String) == "14",
               "the about panel shows the bundle version and build")
        let credits = aboutOptions[.credits] as? NSAttributedString
        expect(credits?.string.contains("MIT License") == true
                && credits?.string.contains("github.com/surfine/WindowShade") == true,
               "the about panel credits the license and the repository")
        var hasLink = false
        credits?.enumerateAttribute(.link, in: NSRange(location: 0, length: credits?.length ?? 0)) {
            value, _, _ in if value != nil { hasLink = true }
        }
        expect(hasLink, "the repository appears as a clickable link")

        // 注入了 target/action 时，“设置…”必须带上 ⌘, 且指向注入的目标。
        let withSettings = StandardMenu.make(appName: "WindowShade", settingsTarget: NSApp,
                                             settingsAction: #selector(NSApplication.terminate(_:)))
        let settingsItem = withSettings.items.first?.submenu?.items.first { $0.title == "设置…" }
        expect(settingsItem?.keyEquivalent == "," && settingsItem?.target === NSApp,
               "设置… uses ⌘, and the injected target")
        guard let edit = menu.items.compactMap({ $0.submenu }).first(where: { $0.title == "编辑" }),
              let paste = edit.items.first(where: { $0.title == "粘贴" }) else {
            expect(false, "the edit menu exposes 粘贴")
            return
        }
        expect(paste.keyEquivalent == "v"
                && paste.keyEquivalentModifierMask.contains(.command)
                && !paste.keyEquivalentModifierMask.contains(.shift),
               "粘贴 keeps the standard ⌘V key equivalent")
        if let redo = edit.items.first(where: { $0.title == "重做" }) {
            expect(redo.keyEquivalent == "z" && redo.keyEquivalentModifierMask.contains(.shift),
                   "重做 uses ⇧⌘Z")
        } else {
            expect(false, "the edit menu exposes 重做")
        }
        guard let windowMenu = menu.items.compactMap({ $0.submenu })
            .first(where: { $0.title == "窗口" }),
              let close = windowMenu.items.first(where: { $0.title == "关闭" }) else {
            expect(false, "the window menu exposes 关闭")
            return
        }
        expect(close.keyEquivalent == "w", "关闭 keeps the standard ⌘W key equivalent")
        let copyItem = edit.items.first { $0.title == "拷贝" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        // 行为验证：菜单必须认领 ⌘V 并把动作指向响应链的 paste:（真正落到文本框
        // 的端到端验证在独立进程里做，见 scripts/check-standard-menu.sh：
        // 同一份构建里“无主菜单 → 不粘贴、有主菜单 → 粘贴成功”）。
        expect(paste.action == #selector(NSText.paste(_:)),
               "粘贴 is wired to the standard paste: action")
        expect(copyItem?.action == #selector(NSText.copy(_:)),
               "拷贝 is wired to the standard copy: action")
        window.close()
    }
}

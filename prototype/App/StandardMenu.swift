// 标准最小主菜单。
//
// WindowShade 是只在菜单栏显示图标的代理应用（LSUIElement），屏幕顶部不显示它的菜单栏；
// 但 AppKit 的文本编辑快捷键（⌘X/⌘C/⌘V/⌘A/⌘Z）和 ⌘W 都通过主菜单的快捷键分派。
// 实测：没有主菜单时，即使 NSTextField 已经是第一响应者，⌘V 也不会粘贴
// （menuHandled=false / windowHandled=false）。
//
// 因此这里提供一份最小但标准的主菜单：应用菜单（关于/设置/服务/隐藏/退出）、编辑
// 菜单（撤销/重做/剪切/拷贝/粘贴/删除/全选）与窗口菜单（关闭/最小化）。它不改变
// 代理应用的菜单栏行为，只让文本框和关闭快捷键恢复系统习惯。

import Cocoa

enum StandardMenu {
    /// 只从主线程安装主菜单：里面要写 `NSApp.servicesMenu`。
    @MainActor
    static func make(appName: String,
                     settingsTarget: AnyObject?,
                     settingsAction: Selector?,
                     aboutTarget: AnyObject? = nil,
                     aboutAction: Selector? = nil) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem(appName: appName,
                                            settingsTarget: settingsTarget,
                                            settingsAction: settingsAction,
                                            aboutTarget: aboutTarget,
                                            aboutAction: aboutAction))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    /// 系统标准“关于”面板的内容：一句用途说明 + 许可与仓库链接。
    /// 纯构造，便于测试；实际展示仍由 `orderFrontStandardAboutPanel` 负责。
    static func aboutPanelOptions(applicationName: String = "WindowShade",
                                  version: String,
                                  build: String)
        -> [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSMutableAttributedString(
            string: "双击标题栏收起窗口，卷帘条留在原处。\nMIT License\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/surfine/WindowShade",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: "https://github.com/surfine/WindowShade")!]))
        return [
            .applicationName: applicationName,
            .applicationVersion: version,
            .version: build,
            .credits: credits,
        ]
    }

    // MARK: 已收起窗口的菜单分区

    /// 直接列出并带 ⌃⌘1…⌃⌘9 的窗口数；其余放进“更多”子菜单，
    /// 免得菜单太长，而第 9 扇之后的窗口又没有快捷键。
    static let inlineFoldedWindowLimit = 9

    static func foldedWindowShortcut(index: Int) -> String? {
        guard index >= 0, index < inlineFoldedWindowLimit else { return nil }
        return "\(index + 1)"
    }

    /// 菜单里的窗口标题统一截断，避免单项把菜单撑到屏幕宽（默认上限 42 字）。
    static func menuTitle(_ raw: String, limit: Int = 42) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit, limit > 1 else { return clean }
        return String(clean.prefix(limit - 1)) + "…"
    }

    static func splitFoldedWindows<T>(_ items: [T]) -> (inline: [T], overflow: [T]) {
        guard items.count > inlineFoldedWindowLimit else { return (items, []) }
        return (Array(items.prefix(inlineFoldedWindowLimit)),
                Array(items.dropFirst(inlineFoldedWindowLimit)))
    }

    // MARK: 各子菜单

    @MainActor
    private static func applicationMenuItem(appName: String,
                                            settingsTarget: AnyObject?,
                                            settingsAction: Selector?,
                                            aboutTarget: AnyObject?,
                                            aboutAction: Selector?) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)

        // 有自定义实现时用应用的“关于”面板（标准面板 + 许可信息），否则用系统默认的。
        let about = NSMenuItem(title: "关于 \(appName)",
                               action: aboutAction
                                   ?? #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = aboutTarget
        menu.addItem(about)
        menu.addItem(.separator())

        if let settingsAction {
            let settings = NSMenuItem(title: "设置…", action: settingsAction, keyEquivalent: ",")
            settings.target = settingsTarget
            menu.addItem(settings)
            menu.addItem(.separator())
        }

        let services = NSMenu(title: "服务")
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(withTitle: "隐藏 \(appName)",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "显示全部",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 \(appName)",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        // 这些动作由响应链上的第一响应者执行，标准实现在 NSText/NSTextView 里。
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let delete = NSMenuItem(title: "删除", action: #selector(NSText.delete(_:)),
                                keyEquivalent: "")
        menu.addItem(delete)
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        menu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        item.submenu = menu
        return item
    }
}

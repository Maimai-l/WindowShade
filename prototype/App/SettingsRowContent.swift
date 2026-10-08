// 设置行左侧的内容：符号、名字、一行副标题；说不完的放进 info 气泡。
import Cocoa
@MainActor enum SettingsRowContent {
    nonisolated static let short: [String:String] = [
        "设置怎么收起窗口、收起后什么样、要不要提示音。": "窗口的收起方式与外观",
        "指针停在卷帘条上，窗口在原处出现，移开就收回": "停在卷帘条上看一眼",
        "收起的窗口也不会被别的窗口挡住": "收起后也保持置顶",
        "WindowShade 只在需要时使用系统权限。": "只在需要时使用权限",
        "找到、移动和恢复窗口": "找到、移动和恢复窗口",
        "截取窗口画面做预览": "截取窗口画面做预览",
        "在任何应用里都能用。点“录制…”再按下新的组合；“清除”会关掉这个快捷键。": "录制或清除全局快捷键",
        "外观选“统一标题栏”时，改为专注当前 App；选“缩略图”时，把缩略图排到屏幕下边，再按放回原位": "按外观整理窗口或缩略图",
        // 动态副标题：原文由运行时状态拼出，这里按可能出现的几种逐条列出短句。
        "在任意窗口的标题栏上双击": "双击任意窗口标题栏",
        "三击标题栏会缩放窗口": "三击标题栏缩放窗口",
        "三击标题栏会最小化窗口": "三击标题栏最小化窗口",
        "WindowShade 会在登录后自动运行": "登录后自动运行",
        "需要在系统设置中批准登录项": "需在系统设置中批准",
        "开机后自动运行 WindowShade": "开机后自动运行",
        "当前 app bundle 不支持登录项": "此版本不支持登录项",
        "⌃⌘1…9 对应菜单里的前 9 个窗口": "⌃⌘1…9：前 9 个窗口",
        "卷帘条跟原来一样或用统一标题栏，也可以在原处缩成缩略图": "跟原来一样、统一标题栏或缩略图",
        "让它更透一些，能看到后面的内容": "更透，能看到后面",
        "有新版本时在菜单里告诉你，不会自己装。": "有新版时告诉你，不自动装",
        "新版本用着不对，可以换回刚才那一版。": "可以换回刚才那一版",
        "重看欢迎窗口，或打开诊断日志。": "欢迎窗口与诊断日志",
    ]

    /// design-system §4.11 里出现过的符号。页头只许用这份里的名字。
    nonisolated static let tableSymbols: Set<String> = [
        "rectangle.compress.vertical", "rectangle.expand.vertical",
        "rectangle.topthird.inset.filled", "macwindow.on.rectangle",
        "eye", "pin", "pin.slash",
        "rectangle.lefthalf.inset.filled", "rectangle.righthalf.inset.filled",
        "rectangle.inset.filled", "rectangle.split.2x1", "rectangle.split.3x3",
        "wand.and.stars", "scroll", "sidebar.right", "pip",
        "square.grid.3x3", "rectangle.3.group", "rectangle.on.rectangle",
        "command", "lightbulb", "music.note", "airpods", "waveform",
        "timer", "cup.and.saucer", "magicmouse", "rectangle.and.hand.point.up.left",
        "keyboard", "appletvremote.gen4", "gamecontroller", "iphone",
        "battery.75percent", "viewfinder", "touchid", "lock.shield", "mic.fill", "info.circle",
    ]

    nonisolated static func tableSymbol(_ name: String?) -> String? {
        guard let name, tableSymbols.contains(name) else { return nil }
        return name
    }

    /// 一行里放得下的短句。全文更长时由气泡保留，不在这里截掉意思。
    nonisolated static func line(_ subtitle: String) -> String {
        if let mapped = short[subtitle] { return mapped }
        if subtitle.count <= 16 { return subtitle }
        if let range = subtitle.range(of: "个应用") {
            let head = String(subtitle[..<range.upperBound])
            if head.count <= 16 { return head }
        }
        return String(subtitle.prefix(16))
    }

    /// 只返回 §4.11 对得上的符号。对不上返回 nil，不另造一个。
    /// 更具体的名字放前面。
    nonisolated static func symbol(for name: String) -> String? {
        let pairs: [(String, String)] = [
            ("看一眼", "eye"),
            ("双击标题栏收起窗口", "rectangle.compress.vertical"),
            ("收起后的样子", "rectangle.compress.vertical"),
            ("收起或展开", "rectangle.compress.vertical"),
            ("收起窗口", "rectangle.compress.vertical"),
            ("按编号展开", "rectangle.expand.vertical"),
            ("快捷键", "command"),
        ]
        for (needle, symbol) in pairs where name.contains(needle) {
            return symbol
        }
        return nil
    }

    /// 设置行左侧：圆角色块里的符号（有才放）、名字、至多一行副标题，说不完的进 info.circle。
    /// 跟着枚举留在主线程：这里建的是 AppKit 视图。调用方都是主线程类型。
    static func content(name: String?, subtitle: String?, symbol: String? = nil) -> (view: NSStackView, detail: NSTextField?) {
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        if let name, !name.isEmpty {
            let title = NSTextField(labelWithString: name)
            title.font = SystemAppearancePolicy.font(relativeToBody: 0)
            labels.addArrangedSubview(title)
        }
        var detail: NSTextField?
        if let subtitle {
            let shown = line(subtitle)
            let field = NSTextField(labelWithString: shown)
            field.font = SystemAppearancePolicy.font(relativeToBody: -2)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.toolTip = subtitle
            labels.addArrangedSubview(field)
            detail = field
        }
        var views: [NSView] = []
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(hierarchicalColor: .controlAccentColor)
            icon.wantsLayer = true
            icon.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            icon.layer?.cornerRadius = 7
            icon.imageScaling = .scaleProportionallyDown
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            icon.setContentHuggingPriority(.required, for: .horizontal)
            views.append(icon)
        }
        views.append(labels)
        let content = NSStackView(views: views)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        if let subtitle, line(subtitle) != subtitle {
            let caption = (name?.isEmpty == false ? name! : "说明")
            content.addArrangedSubview(SettingsInfoButton(text: subtitle, name: caption))
        }
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return (content, detail)
    }
}
final class SettingsInfoButton: NSButton {
    private let fullText: String
    private var popover: NSPopover?

    init(text: String, name: String) {
        fullText = text
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "\(name)的说明")
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(showInfo)
        toolTip = text
        setAccessibilityLabel("\(name)的说明")
    }

    required init?(coder: NSCoder) { nil }

    @objc private func showInfo() {
        if let popover, popover.isShown { popover.close(); return }
        let label = NSTextField(wrappingLabelWithString: fullText)
        label.translatesAutoresizingMaskIntoConstraints = false
        let host = NSViewController()
        host.view = NSView()
        host.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: host.view.bottomAnchor, constant: -16),
            label.widthAnchor.constraint(equalToConstant: 300),
        ])
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

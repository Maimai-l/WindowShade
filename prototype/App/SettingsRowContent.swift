// 设置行左侧的内容：符号、名字、一行副标题。副标题只写名字里没有的信息，没有就不写。
import Cocoa
@MainActor enum SettingsRowContent {
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

    /// 设置行左侧：圆角色块里的符号（有才放）、名字、至多一行副标题。
    /// 跟着枚举留在主线程：这里建的是 AppKit 视图。调用方都是主线程类型。
    static func content(name: String?, subtitle: String?, symbol: String? = nil) -> NSStackView {
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        if let name, !name.isEmpty {
            let title = NSTextField(labelWithString: name)
            title.font = SystemAppearancePolicy.font(relativeToBody: 0)
            labels.addArrangedSubview(title)
        }
        if let subtitle {
            let field = NSTextField(labelWithString: subtitle)
            field.font = SystemAppearancePolicy.font(relativeToBody: -2)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.toolTip = subtitle
            labels.addArrangedSubview(field)
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
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return content
    }
}

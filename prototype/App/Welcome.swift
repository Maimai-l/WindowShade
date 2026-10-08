// 欢迎使用 WindowShade：首次打开时出现、菜单里随时能再打开（“欢迎使用 Macintosh”的现代版）。
// 一页：真实的授权行（沿用原来的刷新逻辑），关窗口也算看过，下次不再自动弹出。

import Cocoa

@MainActor
final class WelcomeView: NSView {
    static let title = "欢迎使用 WindowShade"
    static let lede = "辅助功能让 WindowShade 能移动窗口，屏幕录制让它能显示实时画面。两项都打开就能用了。"
    static let standardAccount = "打开这两项时，要输入管理员的名字和密码。"

    var onFinish: (() -> Void)?
    var onLater: (() -> Void)?
    /// 换了一步：AppDelegate 据此决定授权页的每秒刷新开不开（只在停在授权页时开）。
    var onPageChange: (() -> Void)?
    /// 两项授权都有了没有：“开始使用”只在都有时能点，没有时旁边给“稍后再说”。
    var permissionsGranted: () -> Bool = { true }
    /// 授权区：AppDelegate 往里填授权行（沿用原来的刷新逻辑）。
    let permissionStack = NSStackView()
    /// 授权行现在画的是哪种状态（辅助功能、屏幕录制）；没变就不拆了重画。
    var shownGrants: [Bool]?

    private let titleLabel = NSTextField(labelWithString: "")
    private let lede = NSTextField(wrappingLabelWithString: "")
    private let skip = NSButton(title: "稍后再说", target: nil, action: nil)
    let next = NSButton(title: "开始使用", target: nil, action: nil)
    private let permissionBox = NSStackView()

    static let size = NSSize(width: 720, height: 596)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let padding: CGFloat = 26
        let areaWidth = Self.size.width - padding * 2
        let areaHeight = (areaWidth * 9 / 16).rounded()
        // 上面一块放授权卡片，下面是标题和一句话。
        let area = NSRect(x: padding, y: Self.size.height - 40 - areaHeight, width: areaWidth, height: areaHeight)

        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 12
        permissionStack.orientation = .vertical
        permissionStack.alignment = .centerX
        permissionBox.addArrangedSubview(permissionStack)
        permissionBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(permissionBox)
        NSLayoutConstraint.activate([
            permissionBox.centerXAnchor.constraint(equalTo: leadingAnchor, constant: area.midX),
            permissionBox.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -area.midY),
        ])

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        lede.font = .systemFont(ofSize: 14)
        lede.textColor = .secondaryLabelColor
        lede.maximumNumberOfLines = 3
        let top = area.minY - 20
        titleLabel.frame = NSRect(x: padding, y: top - 50, width: areaWidth, height: 30)
        // 三行高（标准账户时会到三行）；字从上往下排，一两行时位置不变。
        lede.frame = NSRect(x: padding, y: top - 114, width: areaWidth, height: 60)
        [titleLabel, lede].forEach(addSubview)

        for (button, action) in [(skip, #selector(skipPressed)), (next, #selector(nextPressed))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .large
            addSubview(button)
        }
        skip.isBordered = false
        skip.contentTintColor = .secondaryLabelColor
        next.keyEquivalent = "\r"
        layoutButtons()
        showPermissions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func layoutButtons() {
        var x = Self.size.width - 26
        next.sizeToFit()
        // 无边框的“稍后再说”比有边框的按钮矮，按中线对齐，字才在同一条线上。
        let midY = 18 + next.frame.height / 2
        for button in [next, skip] where !button.isHidden {
            button.sizeToFit()
            let width = max(button.frame.width, button === next ? 96 : 72)
            x -= width
            button.frame = NSRect(x: x, y: (midY - button.frame.height / 2).rounded(), width: width, height: button.frame.height)
            x -= 8
        }
    }

    /// 授权页。
    func showPermissions() {
        permissionBox.isHidden = false
        [skip, next].forEach { $0.isEnabled = true }
        titleLabel.stringValue = Self.title
        lede.stringValue = Self.lede
        // 标准账户打开这两项要管理员的名字和密码：先说一声，免得他以为自己点错了。
        if !Self.isAdminUser() { lede.stringValue += "\n" + Self.standardAccount }
        next.title = "开始使用"
        refreshButtons()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        onPageChange?()
    }

    /// 没授权时旁边给“稍后再说”，“开始使用”等授权后才能点。
    func refreshButtons() {
        let granted = permissionsGranted()
        skip.title = "稍后再说"
        skip.isHidden = granted
        next.isEnabled = granted
        layoutButtons()
    }

    @objc private func nextPressed() {
        onFinish?()
    }
    @objc private func skipPressed() {
        onLater?()
    }

    override var acceptsFirstResponder: Bool { true }

    /// 当前用户在 admin 组（gid 80）里。
    private static func isAdminUser() -> Bool {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0 else { return false }
        return groups.prefix(Int(count)).contains(80)
    }
}

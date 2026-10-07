// 欢迎使用 WindowShade：首次打开时出现、菜单里随时能再打开（“欢迎使用 Macintosh”的现代版）。
// 一页：真实的授权行（沿用原来的刷新逻辑），关窗口也算看过，下次不再自动弹出。
// 从“下载”等地方直接打开时，授权之前多一步“放进‘应用程序’文件夹”（UpdaterMove）：放进去以后才能在菜单里更新。

import Cocoa

@MainActor
final class WelcomeView: NSView {
    static let title = "欢迎使用 WindowShade"
    static let lede = "辅助功能让 WindowShade 能移动窗口，屏幕录制让它能显示实时画面。两项都打开就能用了。"

    var onFinish: (() -> Void)?
    var onLater: (() -> Void)?
    /// 换了一步：AppDelegate 据此决定授权页的每秒刷新开不开（只在停在授权页时开）。
    var onPageChange: (() -> Void)?
    /// 两项授权都有了没有：“开始使用”只在都有时能点，没有时旁边给“稍后再说”。
    var permissionsGranted: () -> Bool = { true }
    /// 授权区：AppDelegate 往里填授权行、进度字（沿用原来的刷新逻辑）。
    let permissionStack = NSStackView()
    let progressLabel = NSTextField(labelWithString: "")
    /// 授权行现在画的是哪种状态（辅助功能、屏幕录制）；没变就不拆了重画。
    var shownGrants: [Bool]?
    /// 装好新版本后系统要他重新打开两项授权：授权页换成“再打开一次这两项”那组文案。
    var permissionsAgain = false { didSet { if !onMoveStep { showPermissions() } } }

    private let titleLabel = NSTextField(labelWithString: "")
    private let lede = NSTextField(wrappingLabelWithString: "")
    private let skip = NSButton(title: "稍后再说", target: nil, action: nil)
    let next = NSButton(title: "开始使用", target: nil, action: nil)
    private let permissionBox = NSStackView()
    /// 授权之前那一步：放进“应用程序”文件夹。AppDelegate 在首次打开时交进来；nil 就没有这一步。
    private var moveStep: UpdaterMoveStep?
    private(set) var onMoveStep = false
    private var moveFailed = false
    private let moveBox = NSStackView()
    private let moveIcon = NSImageView()

    static let size = NSSize(width: 720, height: 596)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let padding: CGFloat = 26
        let areaWidth = Self.size.width - padding * 2
        let areaHeight = (areaWidth * 9 / 16).rounded()
        // 上面一块放授权卡片或“放进‘应用程序’”的两个图标，下面是标题和一句话。
        let area = NSRect(x: padding, y: Self.size.height - 40 - areaHeight, width: areaWidth, height: areaHeight)

        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 12
        progressLabel.font = .systemFont(ofSize: 13, weight: .medium)
        permissionStack.orientation = .vertical
        permissionStack.alignment = .centerX
        permissionBox.addArrangedSubview(progressLabel)
        permissionBox.addArrangedSubview(permissionStack)
        permissionBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(permissionBox)
        // 放进“应用程序”那一步：这个 App 的图标 → “应用程序”文件夹的图标，都是系统给的图，不另画。
        moveIcon.image = NSApp.applicationIconImage
        moveIcon.wantsLayer = true
        let folder = NSImageView(image: NSWorkspace.shared.icon(forFile: "/Applications"))
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil) ?? NSImage())
        arrow.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        arrow.contentTintColor = .tertiaryLabelColor
        for icon in [moveIcon, folder] {
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 112).isActive = true
        }
        moveBox.orientation = .horizontal
        moveBox.alignment = .centerY
        moveBox.spacing = 28
        [moveIcon, arrow, folder].forEach(moveBox.addArrangedSubview)
        moveBox.setAccessibilityElement(false)
        moveBox.isHidden = true
        moveBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(moveBox)
        for box in [permissionBox, moveBox] as [NSView] {
            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: leadingAnchor, constant: area.midX),
                box.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -area.midY),
            ])
        }

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        lede.font = .systemFont(ofSize: 14)
        lede.textColor = .secondaryLabelColor
        lede.maximumNumberOfLines = 3
        let top = area.minY - 20
        titleLabel.frame = NSRect(x: padding, y: top - 50, width: areaWidth, height: 30)
        // 三行高（标准账户、更新后要重新授权时会到三行）；字从上往下排，一两行时位置不变。
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
        onMoveStep = false
        moveBox.isHidden = true
        permissionBox.isHidden = false
        [skip, next].forEach { $0.isEnabled = true }
        titleLabel.stringValue = Self.title
        lede.stringValue = Self.lede
        if permissionsAgain {
            titleLabel.stringValue = UpdateCopy.permissionsAgainTitle
            lede.stringValue = UpdateCopy.permissionsAgainLead + UpdateCopy.permissionsStuckHint
        }
        // 标准账户打开这两项要管理员的名字和密码：先说一声，免得他以为自己点错了。
        if UpdaterMove.shared.isStandardAccount { lede.stringValue += "\n" + UpdateCopy.standardAccount }
        next.title = "开始使用"
        refreshButtons()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        onPageChange?()
    }

    /// 授权之前那一步：放进“应用程序”文件夹。没有这一步（已经在里面、他跳过过）就直接到授权页。
    func showMove(_ step: UpdaterMoveStep?) {
        moveStep = step
        guard let step else { showPermissions(); return }
        onMoveStep = true
        moveFailed = false
        titleLabel.stringValue = step.title
        lede.stringValue = step.lead + (step.note ?? "")
        permissionBox.isHidden = true
        moveBox.isHidden = false
        skip.isHidden = false
        skip.title = step.secondaryTitle
        next.title = step.primaryTitle
        [skip, next].forEach { $0.isEnabled = true }
        resetMoveIcon()
        layoutButtons()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        onPageChange?()
    }

    private func pressMovePrimary() {
        if moveFailed {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            return
        }
        [skip, next].forEach { $0.isEnabled = false }
        glideIconIntoFolder()
        UpdaterMove.shared.performPrimary { [weak self] result in
            // .relaunching：这个进程马上退出，新位置那一份接着从头走。
            guard let self, case .failed = result else { return }
            self.moveFailed = true
            self.resetMoveIcon()
            self.lede.stringValue = UpdateCopy.moveFailed
            self.next.title = UpdateCopy.showInFinder
            self.skip.title = "继续"
            [self.skip, self.next].forEach { $0.isEnabled = true }
            self.layoutButtons()
            NSAccessibility.post(element: self.lede, notification: .valueChanged)
        }
    }

    /// 按下去就给回应：图标朝文件夹滑过去、变小、变淡（移动要一两秒）。“减少动态效果”时只变淡。
    private func glideIconIntoFolder() {
        guard let layer = moveIcon.layer else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0.2 : 0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        if !reduce {
            // 图层的锚点在左下角：缩小时补回一半的差，看起来是绕图标中心缩。
            let travel = moveBox.arrangedSubviews.last.map { $0.frame.midX - moveIcon.frame.midX } ?? 0
            let scale: CGFloat = 0.55
            let inset = moveIcon.bounds.width * (1 - scale) / 2
            var t = CATransform3DMakeTranslation(travel + inset, moveIcon.bounds.height * (1 - scale) / 2, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            layer.transform = t
        }
        layer.opacity = 0.25
        CATransaction.commit()
    }

    private func resetMoveIcon() {
        guard let layer = moveIcon.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    /// 没授权时旁边给“稍后再说”，“开始使用”等授权后才能点。
    func refreshButtons() {
        guard !onMoveStep else { return }
        let granted = permissionsGranted()
        skip.title = "稍后再说"
        skip.isHidden = granted
        next.isEnabled = granted
        layoutButtons()
    }

    @objc private func nextPressed() {
        if onMoveStep { pressMovePrimary(); return }
        onFinish?()
    }
    @objc private func skipPressed() {
        if onMoveStep {
            // 跳过就不再在欢迎窗口里问（没能移过去时的“继续”不算跳过）；更新小窗里位置不对时还会再给这一步。
            if !moveFailed { UpdaterMove.shared.declineForWelcome() }
            showPermissions()
            return
        }
        onLater?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onMoveStep {
            // 这一步的 → 就是“跳过”；← 没有上一步。
            if event.keyCode == 124, skip.isEnabled { skipPressed() } else if event.keyCode != 123 { super.keyDown(with: event) }
            return
        }
        super.keyDown(with: event)
    }
}

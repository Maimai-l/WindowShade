import Cocoa

enum WindowShadeSettingsSection: Int, CaseIterable {
  // 存下来的是原始值：拿掉的分页空出的编号不再复用，旧值落到默认分页。
  case shade = 1, shortcuts = 3, permissions = 4, advanced = 5

  private static let lastViewedKey = "WindowShade.Settings.LastViewedSection"

  static func lastViewed(in defaults: UserDefaults = .standard) -> Self {
    guard let rawValue = defaults.object(forKey: lastViewedKey) as? Int,
          let section = Self(rawValue: rawValue) else { return .shade }
    return section
  }

  func remember(in defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.lastViewedKey)
  }

  /// 在侧边栏里的行号。
  var row: Int { Self.allCases.firstIndex(of: self)! }

  var title: String {
    switch self {
    case .shade: return "卷帘"
    case .shortcuts: return "快捷键"
    case .permissions: return "权限与启动"
    case .advanced: return "高级"
    }
  }

  var symbolName: String {
    switch self {
    case .shade: return "rectangle.compress.vertical"
    case .shortcuts: return "command"
    case .permissions: return "lock.shield"
    case .advanced: return "slider.horizontal.3"
    }
  }
}

/// 设置页内容列宽度上限，各分页共用。
let settingsContentWidth: CGFloat = 640

private final class SettingsPageHost: NSView {
  override var isFlipped: Bool { true }
}

/// All settings pages and onboarding share the same native, flat group box.
final class SettingsGroupBox: NSBox {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    boxType = .custom
    titlePosition = .noTitle
    borderWidth = 0
    cornerRadius = SystemCornerRadius.card
    contentViewMargins = .zero
    // 动态颜色：浅深色在绘制时各自解析，不再依赖外观回调重新赋值。
    fillColor = SystemAppearancePolicy.groupBoxFill()
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    fillColor = SystemAppearancePolicy.groupBoxFill()
    needsDisplay = true
  }
}

final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
  private weak var app: AppDelegate?
  /// 关掉时不记窗口位置和上次看的分页（测试用）。
  private let remembersState: Bool
  private var pageHost: NSView!
  private var pageScroll: NSScrollView!
  private var pages: [WindowShadeSettingsSection: NSView] = [:]
  private let sidebarTable = NSTableView()
  private let splitController = NSSplitViewController()
  private var activePageConstraints: [NSLayoutConstraint] = []
  private var currentSection: WindowShadeSettingsSection?

  init(owner: AppDelegate, remembersState: Bool = true) {
    self.app = owner
    self.remembersState = remembersState
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    window.title = "WindowShade 设置"
    window.isReleasedWhenClosed = false
    // 工具型窗口不与其它窗口合并成标签页（系统偏好设为“始终”时也保持一致）。
    window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 820, height: 580)
    if remembersState {
      window.setFrameAutosaveName("WindowShade.Settings")
    }
    super.init(window: window)
    window.delegate = self
    build()
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  private func build() {
    guard let window else { return }
    window.toolbarStyle = .unified
    window.backgroundColor = .textBackgroundColor
    let toolbar = NSToolbar(identifier: "WindowShade.Settings.Toolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    toolbar.isVisible = true
    splitController.splitView.isVertical = true
    splitController.splitView.dividerStyle = .thin
    let sidebarController = NSViewController()
    sidebarController.view = makeSidebar()
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 260
    sidebarItem.canCollapse = true
    sidebarItem.preferredThicknessFraction = 214.0 / 900.0
    splitController.addSplitViewItem(sidebarItem)

    let detail = NSView()
    detail.translatesAutoresizingMaskIntoConstraints = false
    // Let the window background continue beneath the native floating sidebar
    // and detail pane, instead of introducing a separate material at the divider.

    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    pageScroll = scroll
    let host = SettingsPageHost()
    pageHost = host
    pageHost.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = pageHost
    pageHost.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    pageHost.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
    detail.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: detail.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
    ])
    let detailController = NSViewController()
    detailController.view = detail
    splitController.addSplitViewItem(NSSplitViewItem(viewController: detailController))
    // Give the controller the requested initial frame before NSWindow adopts it.
    splitController.view.translatesAutoresizingMaskIntoConstraints = false
    splitController.view.setFrameSize(NSSize(width: 900, height: 680))
    window.contentViewController = splitController
    // AppKit adds the toolbar's extra height to the window's own minimum, even for a full-size
    // content view, so measure the chrome instead of assuming a toolbar height. The minimum is
    // expressed as `contentMinSize`, never as a required width/height constraint on the split
    // view: a required constraint there makes AppKit satisfy it by growing the whole window
    // whenever the sidebar expands, so toggling the sidebar pushed the window from 900 to
    // 1115 pt (one sidebar wider). `contentMinSize` only limits how small a person can drag the
    // window; AppKit stays free to redistribute sidebar and detail inside it.
    let titlebarHeight = NSWindow.frameRect(forContentRect: .zero,
      styleMask: window.styleMask.subtracting(.fullSizeContentView)).height
    let toolbarHeight = max(0, window.frame.height - window.contentLayoutRect.height - titlebarHeight)
    window.contentMinSize = NSSize(width: 820, height: max(320, 580 - titlebarHeight - toolbarHeight))
    toolbar.isVisible = true
    splitController.splitView.setPosition(214, ofDividerAt: 0)

    pages[.advanced] = makeAdvancedPage()
    pages[.shade] = app?.makeShadeSettingsPage()
    pages[.shortcuts] = app?.makeShortcutsSettingsPage()
    pages[.permissions] = app?.makePermissionsSettingsPage()
    select(section: .lastViewed())
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    if identifier == .sidebarTrackingSeparator {
      return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitController.splitView, dividerIndex: 0)
    }
    guard identifier == .toggleSidebar else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "切换侧边栏")
    item.label = "切换侧边栏"
    item.target = splitController
    item.action = #selector(NSSplitViewController.toggleSidebar(_:))
    return item
  }

  private func makeSidebar() -> NSView {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    sidebarTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section")))
    sidebarTable.headerView = nil
    sidebarTable.style = .sourceList
    sidebarTable.rowHeight = 30
    sidebarTable.allowsEmptySelection = false
    sidebarTable.allowsMultipleSelection = false
    sidebarTable.dataSource = self
    sidebarTable.delegate = self
    sidebarTable.setAccessibilityLabel("设置侧边栏")
    scroll.documentView = sidebarTable
    return scroll
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    WindowShadeSettingsSection.allCases.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let section = WindowShadeSettingsSection.allCases[row]
    let cell = NSTableCellView()
    let icon = NSImageView(image: NSImage(systemSymbolName: section.symbolName,
                                        accessibilityDescription: nil) ?? NSImage())
    let label = NSTextField(labelWithString: section.title)
    label.font = SystemAppearancePolicy.font(relativeToBody: 0)
    icon.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(icon)
    cell.addSubview(label)
    cell.imageView = icon
    cell.textField = label
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 17),
      icon.heightAnchor.constraint(equalToConstant: 17),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    let sections = WindowShadeSettingsSection.allCases
    guard sections.indices.contains(sidebarTable.selectedRow) else { return }
    let section = sections[sidebarTable.selectedRow]
    guard section != currentSection else { return }
    select(section: section)
  }

  private func allowHorizontalExpansion(in view: NSView) {
    if let stack = view as? NSStackView {
      stack.setHuggingPriority(.defaultLow, for: .horizontal)
    }
    view.subviews.forEach { allowHorizontalExpansion(in: $0) }
  }

  func select(section: WindowShadeSettingsSection) {
    guard let pageHost, let page = pages[section] else { return }
    guard currentSection != section || pageHost.subviews.first !== page else { return }
    currentSection = section
    if remembersState { section.remember() }
    allowHorizontalExpansion(in: page)
    NSLayoutConstraint.deactivate(activePageConstraints)
    activePageConstraints.removeAll()
    pageHost.subviews.forEach { $0.removeFromSuperview() }
    page.translatesAutoresizingMaskIntoConstraints = false
    pageHost.addSubview(page)
    // 内容列固定 640pt 上限：窗口再宽也不让一行文字横跨到远端的开关。
    // 但在详情区里**居中**，不贴左边——收起侧栏（详情区变成整窗宽）或把窗口拉宽之后，
    // 多出来的宽度应当均分到两侧。Apple 自己的分组表单就是这么摆的：本机实测
    // 854pt 容器左右各 75pt、1200pt 容器左右各 248pt，内容列本身恒为 703.5pt。
    // 贴左边会让收起侧栏后的窗口右半边整片空着（640pt 内容 + 447pt 空白）。
    let preferredWidth = page.widthAnchor.constraint(equalToConstant: settingsContentWidth)
    preferredWidth.priority = .dragThatCannotResizeWindow
    activePageConstraints = [
      page.centerXAnchor.constraint(equalTo: pageHost.centerXAnchor),
      page.leadingAnchor.constraint(greaterThanOrEqualTo: pageHost.leadingAnchor, constant: 28),
      page.trailingAnchor.constraint(lessThanOrEqualTo: pageHost.trailingAnchor, constant: -28),
      preferredWidth,
      page.widthAnchor.constraint(lessThanOrEqualToConstant: settingsContentWidth),
      page.topAnchor.constraint(equalTo: pageHost.topAnchor, constant: 22),
      page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor, constant: -22),
    ]
    NSLayoutConstraint.activate(activePageConstraints)
    pageHost.layoutSubtreeIfNeeded()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      page.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        page.animator().alphaValue = 1
      }
    } else {
      page.alphaValue = 1
    }
    pageScroll.contentView.scroll(to: .zero)
    pageScroll.contentView.bounds.origin = .zero
    pageScroll.reflectScrolledClipView(pageScroll.contentView)
    window?.subtitle = section.title
    if sidebarTable.selectedRow != section.row {
      sidebarTable.selectRowIndexes(IndexSet(integer: section.row), byExtendingSelection: false)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.currentSection == section else { return }
      self.window?.displayIfNeeded()
      self.scrollToTop()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.currentSection == section else { return }
        self.scrollToTop()
      }
    }
  }

  private func scrollToTop() {
    pageScroll.layoutSubtreeIfNeeded()
    pageHost.layoutSubtreeIfNeeded()
    pageScroll.contentView.scroll(to: .zero)
    pageScroll.contentView.bounds.origin = .zero
    pageScroll.reflectScrolledClipView(pageScroll.contentView)
  }

  func refreshSettings() {
    guard let app, let currentSection else { return }
    pages[.shade] = app.makeShadeSettingsPage()
    pages[.shortcuts] = app.makeShortcutsSettingsPage()
    pages[.permissions] = app.makePermissionsSettingsPage()
    self.currentSection = nil
    select(section: currentSection)
  }

  private func makePageRoot() -> NSView {
    // 背景由详情区统一铺满，页面本身保持透明，避免页边距露出另一种底色。
    NSView()
  }

  // 页内不再重复一次大标题：分节名已经在侧边栏和标题栏副标题里出现过两次。
  // 只保留一行说明。符号只使用 §4.11 里有的名字。
  private func makePageHeader(subtitle: String, symbolName: String?) -> NSView {
    return SettingsRowContent.content(name: nil, subtitle: subtitle, symbol: SettingsRowContent.tableSymbol(symbolName)).view
  }

  private func settingsContent(title: String, subtitle: String) -> NSStackView {
    SettingsRowContent.content(name: title, subtitle: subtitle, symbol: SettingsRowContent.symbol(for: title)).view
  }

  private func makeSectionLabel(_ title: String) -> NSView {
    // 分组标题只有文字：图标在这个层级不传递信息，只增加噪声。
    let label = NSTextField(labelWithString: title)
    label.font = SystemAppearancePolicy.font(relativeToBody: -1, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
  }

  private func makeSettingsCard(_ rows: [NSView]) -> NSView {
    let card = SettingsGroupBox()
    card.wantsLayer = true
    card.translatesAutoresizingMaskIntoConstraints = false

    let inner = NSStackView()
    inner.orientation = .vertical
    inner.alignment = .leading
    inner.spacing = 0
    inner.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(inner)
    NSLayoutConstraint.activate([
      inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
      inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
    ])

    for (index, row) in rows.enumerated() {
      if index > 0 {
        let separator = NSBox()
        separator.boxType = .separator
        inner.addArrangedSubview(separator)
        // 左端缩进到文字起点，右端铺到盒子边缘——macOS 分组盒的分隔线就是这样。
        separator.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -16).isActive = true
      }
      inner.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
    }
    return card
  }

  private func makeActionRow(title: String, subtitle: String, button: NSButton) -> NSView {
    button.font = SystemAppearancePolicy.font(relativeToBody: -1)
    let labels = settingsContent(title: title, subtitle: subtitle)

    button.controlSize = .regular
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = NSStackView(views: [labels, button])
    NSLayoutConstraint.activate([
      labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      labels.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -14),
      button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
    ])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 14
    labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
    labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    return row
  }

  private func makeAdvancedPage() -> NSView {
    let root = makePageRoot()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
    ])
    let header = makePageHeader(
      subtitle: "重看欢迎窗口，或打开诊断日志。",
      symbolName: "slider.horizontal.3")
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(16, after: header)

    let actionSection = makeSectionLabel("操作")
    stack.addArrangedSubview(actionSection)
    stack.setCustomSpacing(6, after: actionSection)
    let diagnostics = NSButton(title: "打开诊断日志", target: self, action: #selector(openDiagnostics))
    diagnostics.bezelStyle = .rounded
    diagnostics.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "诊断日志")
    diagnostics.imagePosition = .imageLeading
    let welcome = NSButton(title: "欢迎使用 WindowShade…", target: app,
                           action: #selector(AppDelegate.showWelcomeGuide))
    welcome.bezelStyle = .rounded
    let actionCard = makeSettingsCard([
      makeActionRow(
        title: "欢迎使用",
        subtitle: "重新看一遍欢迎窗口和授权说明。",
        button: welcome),
      makeActionRow(
        title: "诊断日志",
        subtitle: "打开运行记录排查问题。",
        button: diagnostics),
    ])
    stack.addArrangedSubview(actionCard)
    actionCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return root
  }

  @objc private func openDiagnostics() {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/WindowShade/windowshade.log")
    if FileManager.default.fileExists(atPath: logURL.path) {
      NSWorkspace.shared.open(logURL)
    } else {
      NSWorkspace.shared.open(logURL.deletingLastPathComponent())
    }
  }

  func windowWillClose(_ notification: Notification) {
    app?.settingsWindow = nil
  }
}

extension AppDelegate {
  /// 普通的“设置…”回到上次看的分页；从别处点进来的可以指定分页。
  func showSettingsWindow(section: WindowShadeSettingsSection? = nil) {
    if settingsWindow == nil {
      settingsWindow = SettingsWindow(owner: self)
    }
    settingsWindow?.showWindow(nil)
    if let section { settingsWindow?.select(section: section) }
    NSApp.activate()
  }
}

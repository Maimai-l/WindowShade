// 设置窗口：系统的分页工具栏（NSTabViewController 的 toolbar 样式，和多数 Mac 应用的设置窗口一样），
// 每页是 SettingsView.swift 里的一张分组表单。

import Cocoa
import SwiftUI

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
    case .advanced: return "gearshape.2"
    }
  }
}

final class SettingsWindow: NSWindowController, NSWindowDelegate {
  /// 每页同一个大小，换页时窗口不跳；放不下的那页在表单里滚动。
  static let contentSize = NSSize(width: 560, height: 520)

  private weak var app: AppDelegate?
  /// 关掉时不记窗口位置和上次看的分页（测试用）。
  private let remembersState: Bool
  let model: SettingsModel
  private let tabs = SettingsTabController()

  init(owner: AppDelegate, remembersState: Bool = true) {
    app = owner
    self.remembersState = remembersState
    model = SettingsModel(app: owner)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    // 工具型窗口不与其它窗口合并成标签页（系统偏好设为“始终”时也保持一致）。
    window.tabbingMode = .disallowed
    super.init(window: window)
    window.delegate = self

    tabs.tabStyle = .toolbar
    for section in WindowShadeSettingsSection.allCases {
      // 分页控制器会加载每一页的视图：每页先放一个空的占位，SwiftUI 表单要显示时才建。
      // 四页一起建，第一次打开设置时主线程停 700 毫秒以上（CI 场景 H01、H02、C15）。
      let model = self.model
      let page = LazySettingsPage(title: section.title) {
        let form = NSHostingController(rootView: SettingsPage(section: section, model: model))
        form.sizingOptions = []
        return form
      }
      page.preferredContentSize = Self.contentSize
      let item = NSTabViewItem(viewController: page)
      item.label = section.title
      item.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
      tabs.addTabViewItem(item)
    }
    tabs.onSelect = { [weak self] index in
      guard let self, WindowShadeSettingsSection.allCases.indices.contains(index) else { return }
      let section = WindowShadeSettingsSection.allCases[index]
      self.page(at: index)?.buildIfNeeded()
      self.window?.title = section.title
      if self.remembersState { section.remember() }
    }
    // 先选好分页再装进窗口：装进去时才建选中那一页；反过来会先建第一页，再建上次看的那页。
    select(section: .lastViewed())
    window.contentViewController = tabs
    window.setContentSize(Self.contentSize)
    if remembersState { window.setFrameAutosaveName("WindowShade.Settings") }
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  var selectedSection: WindowShadeSettingsSection {
    WindowShadeSettingsSection.allCases[tabs.selectedTabViewItemIndex]
  }

  func select(section: WindowShadeSettingsSection) {
    guard let index = WindowShadeSettingsSection.allCases.firstIndex(of: section) else { return }
    page(at: index)?.buildIfNeeded()
    tabs.selectedTabViewItemIndex = index
    window?.title = section.title
  }

  private func page(at index: Int) -> LazySettingsPage? {
    guard tabs.tabViewItems.indices.contains(index) else { return nil }
    return tabs.tabViewItems[index].viewController as? LazySettingsPage
  }

  /// 设置在别处改了（菜单、快捷键注册失败退回）：读回来。
  func refreshSettings() {
    model.reload()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // 从系统设置授权回来时，权限那一行马上更新。
    model.reload()
  }

  func windowWillClose(_ notification: Notification) {
    app?.settingsWindow = nil
  }
}

/// 设置的一页：先是一个空视图，第一次要显示时才把 SwiftUI 表单建进去。
final class LazySettingsPage: NSViewController {
  private let make: () -> NSViewController
  private(set) var isBuilt = false

  init(title: String, make: @escaping () -> NSViewController) {
    self.make = make
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.contentSize))
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    buildIfNeeded()
  }

  func buildIfNeeded() {
    guard !isBuilt else { return }
    isBuilt = true
    let form = make()
    addChild(form)
    form.view.frame = view.bounds
    form.view.autoresizingMask = [.width, .height]
    view.addSubview(form.view)
  }
}

/// 换页时通知设置窗口：窗口标题跟着换，记下这一页。
final class SettingsTabController: NSTabViewController {
  var onSelect: ((Int) -> Void)?

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    if let tabViewItem { onSelect?(tabView.indexOfTabViewItem(tabViewItem)) }
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

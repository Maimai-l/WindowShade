// 菜单栏控制器：状态栏图标、菜单重建与菜单代理回调。
// 作为 AppDelegate 扩展实现，动作目标仍是主实现的 @objc 方法。

import Cocoa

struct MenuState {
  let canArrangeShades: Bool
  let foldedWindows: [(CGWindowID, ShadeState)]
  let titlebarDoubleClickEnabled: Bool
}

extension AppDelegate {
  func setupStatusItem() {
    // 启动时补上“收起后显示”选的缩略图（WindowShade.swift 只认得前两项）。
    adoptPersistedCollapseAppearance()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.isVisible = true
    statusMenu = NSMenu()
    statusMenu.delegate = self
    statusItem.menu = statusMenu
    statusItem.button?.image = Self.statusBarIcon
    statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.toolTip = "WindowShade"
    statusItem.button?.setAccessibilityLabel(PaperSurfaceAccessibility.statusItemLabel)
    statusItem.button?.setAccessibilityValue(
      PaperSurfaceAccessibility.statusItemValue(foldedCount: shaded.count))
    rebuildMenu()
    wlog("status item visible=\(statusItem.isVisible)")
  }
  func rebuildMenu() {
    MainThreadActivity.push("menu: 重建")
    defer { MainThreadActivity.pop() }
    if suppressMenuRebuilds {
      pendingMenuRebuild = true
      return
    }
    // 这里绝不能解析当前 AX 窗口：菜单重建可能由点击、前台切换、会话变化
    // 高频触发；目标解析在后台完成后仅在目标改变时安排下一次重建。
    menuRebuildWorkItem?.cancel()
    menuRebuildWorkItem = nil
    statusItem.button?.image = Self.statusBarIcon
    statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    statusItem.button?.imagePosition = .imageLeft
    statusItem.isVisible = true
    statusItem.button?.title = shaded.isEmpty ? "" : " \(shaded.count)"
    statusItem.button?.toolTip =
      shaded.isEmpty ? "WindowShade"
        : "WindowShade：\(PaperSurfaceAccessibility.statusItemValue(foldedCount: shaded.count))"
    // VoiceOver：状态栏按钮读成“WindowShade + 已收起的窗口数”，而不是一个孤立的数字。
    statusItem.button?.setAccessibilityLabel(PaperSurfaceAccessibility.statusItemLabel)
    statusItem.button?.setAccessibilityValue(
      PaperSurfaceAccessibility.statusItemValue(foldedCount: shaded.count))
    statusMenu.removeAllItems()

    let menuState = makeMenuState()

    statusMenu.addItem(.sectionHeader(title: "当前窗口"))
    func action(_ title: String, _ symbol: String, _ selector: Selector,
                _ shortcut: GlobalShortcut? = nil, enabled: Bool = true, menu: NSMenu? = nil) {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
      item.target = self; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      item.isEnabled = enabled
      if let shortcut { applyShortcut(shortcut, to: item) }
      (menu ?? statusMenu).addItem(item)
    }
    let foldTitle = foldToggleMenuTitle().replacingOccurrences(of: "当前窗口", with: "窗口")
    action(foldTitle,
           foldTitle.contains("展开") ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
           #selector(toggleAction), .toggleShade)
    let arrangeTitle = thumbnailsInUse ? (hasArrangedOverlayFrames ? "把缩略图放回原位" : "整理缩略图")
                                       : (hasArrangedOverlayFrames ? "把卷帘条放回原位" : "整理卷帘条")
    action(arrangeTitle, "rectangle.grid.1x2", #selector(arrangeShadedWindows), .arrange,
           enabled: menuState.canArrangeShades)

    if !menuState.foldedWindows.isEmpty {
      statusMenu.addItem(.separator())
      statusMenu.addItem(.sectionHeader(title: "已收起的窗口"))
      // 前 9 扇直接列出，带 ⌃⌘1…9；其余放进“更多”子菜单（动作和图标相同）。
      let sections = StandardMenu.splitFoldedWindows(menuState.foldedWindows)
      for (index, entry) in sections.inline.enumerated() {
        statusMenu.addItem(foldedWindowMenuItem(entry, index: index))
      }
      if !sections.overflow.isEmpty {
        let more = NSMenuItem(title: "更多（\(sections.overflow.count)）",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in sections.overflow {
          submenu.addItem(foldedWindowMenuItem(entry, index: nil))
        }
        more.submenu = submenu
        statusMenu.addItem(more)
      }
      // 仅在有已收起的窗口时才显示“全部展开”。
      statusMenu.addItem(.separator())
      let restore = NSMenuItem(title: "全部展开", action: #selector(restoreAll), keyEquivalent: "")
      statusMenu.addItem(restore)
    }

    statusMenu.addItem(.separator())
    // D03 / M1：不在重建时 if option { addItem } 插入行。
    // “设置…”↔“关于”用 isAlternate；“检查更新…”始终挂在菜单上，用 isHidden 随 ⌥ 显隐。
    // “欢迎使用 WindowShade”只在设置里。
    let optionHeld = NSEvent.modifierFlags.contains(.option)
    let settings = NSMenuItem(title: "设置…", action: #selector(showPreferences), keyEquivalent: ",")
    settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    statusMenu.addItem(settings)
    let about = NSMenuItem(title: "关于 WindowShade", action: #selector(showAboutPanel), keyEquivalent: ",")
    about.isAlternate = true
    about.keyEquivalentModifierMask = [.option]
    about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
    statusMenu.addItem(about)
    let updateItem = UpdaterController.shared.makeMenuItem()
    updateItem.isHidden = !optionHeld
    statusMenu.addItem(updateItem)
    let quitItem = NSMenuItem(title: "退出 WindowShade", action: #selector(quit), keyEquivalent: "q")
    quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil); statusMenu.addItem(quitItem)
    updateReconcileTimer()
  }
  private func windowMenuIcon(for pid: pid_t) -> NSImage? {
    guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else {
      return nil
    }
    icon.size = NSSize(width: 16, height: 16)
    return icon
  }

  func scheduleMenuRebuild(delay: TimeInterval = 0.04) {
    if suppressMenuRebuilds {
      pendingMenuRebuild = true
      return
    }
    menuRebuildWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.menuRebuildWorkItem = nil
      self?.rebuildMenu()
    }
    menuRebuildWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
  func withMenuRebuildSuppressed(_ body: () -> Void) {
    let wasSuppressed = suppressMenuRebuilds
    suppressMenuRebuilds = true
    body()
    suppressMenuRebuilds = wasSuppressed
    if !suppressMenuRebuilds, pendingMenuRebuild {
      pendingMenuRebuild = false
      rebuildMenu()
    }
  }
  /// 设置里“收起后显示”：原标题栏 / 简化标题栏 / 缩略图。只影响之后收起的窗口。
  func setAppearanceMode(_ mode: ShadeAppearanceMode) {
    switch mode {
    case .proxyTitleBar, .thumbnail: appearanceMode = mode
    case .nativeScreenshot: appearanceMode = .nativeScreenshot
    }
    UserDefaults.standard.set(appearanceMode.rawValue, forKey: shadeAppearanceModeDefaultsKey)
    rebuildMenu()
    refreshPreferencesWindowIfOpen()
  }
  func menuDidClose(_ menu: NSMenu) {
    hideMenuHoverPreview()
    menuPreviewHoverID = nil
    menuPreviewAnchor = nil
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === statusMenu, !isUpdatingMenuFromDelegate else { return }
    isUpdatingMenuFromDelegate = true
    defer { isUpdatingMenuFromDelegate = false }
    rebuildMenu()
  }
  func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
    guard menu === statusMenu else { return }
    hideMenuHoverPreview()
    menuPreviewHoverID = nil
    menuPreviewAnchor = nil
    guard let item,
      let n = item.representedObject as? NSNumber
    else { return }
    let mouse = NSEvent.mouseLocation
    let id = CGWindowID(n.uint32Value)
    let anchor = estimatedStatusMenuItemAnchor(near: mouse)
    menuPreviewHoverID = id
    menuPreviewAnchor = anchor
    showMenuHoverPreview(id, anchor: anchor)
  }
  func sortedShadedEntries() -> [(CGWindowID, ShadeState)] {
    shaded.sorted {
      if $0.value.appName != $1.value.appName { return $0.value.appName < $1.value.appName }
      let aTitle = descriptiveDisplayTitle(appName: $0.value.appName, windowTitle: $0.value.title)
      let bTitle = descriptiveDisplayTitle(appName: $1.value.appName, windowTitle: $1.value.title)
      if aTitle != bTitle { return aTitle < bTitle }
      return $0.key < $1.key
    }
  }
  var hasArrangedOverlayFrames: Bool {
    arrangedOverlayFrames.keys.contains { shaded[$0]?.overlay != nil }
  }
  func foldToggleMenuTitle() -> String {
    guard !shaded.isEmpty else { return "收起当前窗口" }
    if currentShadedOverlayID() != nil { return "展开当前窗口" }
    return "收起当前窗口"
  }
  /// 菜单项显示当前设置的快捷键；关掉了、被其他应用占用或按键画不出来时不显示。
  private func applyShortcut(_ shortcut: GlobalShortcut, to item: NSMenuItem) {
    guard let hotKey = menuHotKey(for: shortcut),
          let equivalent = GlobalShortcutSettings.menuKeyEquivalent(for: hotKey) else {
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }
    item.keyEquivalent = equivalent.key
    item.keyEquivalentModifierMask = equivalent.modifiers
  }

  /// 单个已收起窗口的菜单项（直接列出时带 ⌃⌘1…9，子菜单里不带快捷键）。
  private func foldedWindowMenuItem(_ entry: (CGWindowID, ShadeState),
                                    index: Int?) -> NSMenuItem {
    let (id, state) = entry
    let title = StandardMenu.menuTitle(
      descriptiveDisplayTitle(appName: state.appName, windowTitle: state.title))
    let key = index.flatMap { index in
      isNumberedShortcutActive(index: index) ? StandardMenu.foldedWindowShortcut(index: index) : nil
    } ?? ""
    let itemTitle = key.isEmpty ? title : "\(key)  \(title)"
    let item = NSMenuItem(title: itemTitle, action: #selector(unshadeFromMenu(_:)),
                          keyEquivalent: key)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : [.control, .command]
    item.target = self
    item.representedObject = NSNumber(value: id)
    item.image = windowMenuIcon(for: state.pid)
    return item
  }

  func makeMenuState() -> MenuState {
    MenuState(
      canArrangeShades: shaded.values.contains { $0.overlay != nil },
      foldedWindows: sortedShadedEntries(),
      titlebarDoubleClickEnabled: titlebarDoubleClickEnabled)
  }
  /// 模板图，跟随菜单栏浅深色；画一次就够，不必每次重建菜单都重画。
  static let statusBarIcon = makeStatusBarIcon()
}

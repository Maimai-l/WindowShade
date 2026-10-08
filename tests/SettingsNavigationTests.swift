import Cocoa

@main
struct SettingsNavigationTests {
  @MainActor
  static func main() async {
    let suiteName = "WindowShade.SettingsNavigationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    precondition(WindowShadeSettingsSection.lastViewed(in: defaults) == .shade)
    for section in WindowShadeSettingsSection.allCases {
      section.remember(in: defaults)
      precondition(WindowShadeSettingsSection.lastViewed(in: defaults) == section)
    }
    defaults.set(999, forKey: "WindowShade.Settings.LastViewedSection")
    precondition(WindowShadeSettingsSection.lastViewed(in: defaults) == .shade)

    // 拿掉的分页空出来的旧值（0 = 效果，2 = 窗口浏览）落回默认分页。
    for removed in [0, 2] {
      defaults.set(removed, forKey: "WindowShade.Settings.LastViewedSection")
      precondition(WindowShadeSettingsSection.lastViewed(in: defaults) == .shade)
    }

    _ = NSApplication.shared
    let owner = AppDelegate()
    let settings = SettingsWindow(owner: owner, remembersState: false)
    owner.settingsWindow = settings
    settings.select(section: .shortcuts)
    // Complete the two deferred layout passes before simulating user scrolling.
    await drainLayout()
    guard let root = settings.window?.contentView,
          let scroll = descendants(root).compactMap({ $0 as? NSScrollView })
            .first(where: { !($0.documentView is NSTableView) })
    else { preconditionFailure("Settings detail scroll view is missing") }
    scroll.layoutSubtreeIfNeeded()
    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 80))
    let origin = scroll.contentView.bounds.origin
    let page = scroll.documentView?.subviews.first
    settings.select(section: .shortcuts)
    await drainLayout()
    precondition(scroll.contentView.bounds.origin == origin,
                 "Selecting the current pane must preserve the user's scroll position")
    precondition(scroll.documentView?.subviews.first === page,
                 "Selecting the current pane must preserve its content view")
    for section in WindowShadeSettingsSection.allCases {
      settings.select(section: section)
      await drainLayout()
      precondition(settings.window?.subtitle == section.title,
                   "Explicit contextual navigation must still select the target pane")
    }
    // 带说明文字、右侧有控件的行：多行说明不能贴边，也不能压到控件上。
    let rowsBySection: [(WindowShadeSettingsSection, [String])] = [
      (.shade, ["双击标题栏收起窗口", "看一眼"]),
      (.shortcuts, ["收起或展开当前窗口", "整理卷帘条"]),
      (.permissions, [UpdateCopy.autoCheck]),
    ]
    settings.window?.setContentSize(NSSize(width: 820, height: 580))
    for (section, names) in rowsBySection {
    settings.select(section: section)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      settings.window?.appearance = NSAppearance(named: appearance)
      await drainLayout()
      root.layoutSubtreeIfNeeded()
      for name in names {
        guard let title = descendants(root).compactMap({ $0 as? NSTextField })
          .first(where: { $0.stringValue == name
            && ($0.superview?.superview as? NSStackView)?.orientation == .horizontal }),
          let labels = title.superview as? NSStackView,
          // S1 起每一行是「圆角图标 + 文字（+ 说明气泡）」：真正的一行在再外面一层。
          let content = labels.superview as? NSStackView,
          let row = content.superview as? NSStackView,
          let control = row.arrangedSubviews.last else {
          preconditionFailure("Missing settings row: \(name)")
        }
        let rect = content.convert(content.bounds, to: row)
        let controlRect = control.convert(control.bounds, to: row)
        precondition(rect.minY >= 7.5 && row.bounds.maxY - rect.maxY >= 7.5,
                     "Multiline labels need vertical clearance: \(name)")
        precondition(controlRect.minX - rect.maxX >= 13.5,
                     "Labels must not overlap controls: \(name)")
      }
      scroll.contentView.setBoundsOrigin(.zero)
      guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        preconditionFailure("Cannot render settings")
      }
      root.cacheDisplay(in: root.bounds, to: bitmap)
      let directory = URL(fileURLWithPath: ".build/appkit-tests/settings-shots", isDirectory: true)
      try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try! bitmap.representation(using: .png, properties: [:])!.write(
        to: directory.appendingPathComponent("\(section)-\(appearance.rawValue).png"))
    }
    }
    // 更新：发布版的 Info.plist 有清单地址和公钥才启动更新器；测试包两样都没有，
    // 设置里的开关和“检查更新”按钮不可用，菜单里的“检查更新…”也不可用。
    precondition(UpdaterController.isConfigured(["SUFeedURL": "https://example.com/appcast.xml",
                                                 "SUPublicEDKey": "key"]))
    precondition(!UpdaterController.isConfigured(["SUPublicEDKey": "key"]))
    precondition(!UpdaterController.isConfigured(["SUFeedURL": "", "SUPublicEDKey": "key"]))
    UpdaterController.shared.start()
    precondition(!UpdaterController.shared.isAvailable, "A build without a feed URL must not start the updater")
    settings.select(section: .permissions)
    await drainLayout()
    let controls = descendants(root).compactMap { $0 as? NSControl }
    guard let checkButton = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == UpdateCopy.checkButton }),
          let autoCheck = controls.first(where: { $0 is NSSwitch && $0.accessibilityLabel() == UpdateCopy.autoCheck })
    else { preconditionFailure("Update settings rows are missing") }
    precondition(!checkButton.isEnabled && !autoCheck.isEnabled,
                 "Update controls must be disabled when the updater is not running")
    let updateItem = UpdaterController.shared.makeMenuItem()
    precondition(!UpdaterController.shared.validateMenuItem(updateItem),
                 "Check for Updates must be disabled when the updater is not running")
    settings.window?.close()
    print("PASS: settings navigation, 820pt light/dark row clearance and update controls; screenshots saved")
  }

  @MainActor
  private static func drainLayout() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        DispatchQueue.main.async { continuation.resume() }
      }
    }
  }

  @MainActor
  private static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}

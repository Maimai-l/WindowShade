import Carbon.HIToolbox
import Cocoa
import SwiftUI

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
    guard let window = settings.window, let content = window.contentView else {
      preconditionFailure("Settings window is missing")
    }

    // 缺陷回归（CI 场景 H01、H02、C15）：打开设置窗口时四页表单当场全部建好，主线程停 700 毫秒以上。
    // 只建当前那一页，其余分页切过去时再建。
    let pages = (window.contentViewController as? NSTabViewController)?.tabViewItems
      .compactMap { $0.viewController as? LazySettingsPage } ?? []
    precondition(pages.count == WindowShadeSettingsSection.allCases.count, "One page per settings section")
    let built = pages.filter(\.isBuilt).count
    precondition(built == 1, "Opening Settings builds only the page shown, not every page: \(built) built")

    // 分页是系统的工具栏标签：每页一个，带 SF Symbol 和名字，选中哪页标题就是哪页。
    let items = window.toolbar?.items.filter { $0.label.isEmpty == false } ?? []
    precondition(items.map(\.label) == WindowShadeSettingsSection.allCases.map(\.title),
                 "One toolbar tab per settings section: \(items.map(\.label))")
    precondition(items.allSatisfy { $0.image != nil }, "Every settings tab has a symbol")
    var sizes: Set<String> = []
    for section in WindowShadeSettingsSection.allCases {
      settings.select(section: section)
      await drainLayout()
      precondition(settings.selectedSection == section && window.title == section.title,
                   "Selecting \(section) shows that page")
      sizes.insert("\(window.frame.size)")
    }
    precondition(sizes.count == 1, "Switching pages does not resize the window: \(sizes)")
    precondition(pages.allSatisfy(\.isBuilt), "Every page is built once it has been shown")

    // 设置窗口读回的是 AppDelegate 里实际生效的值。
    let model = settings.model
    precondition(model.doubleClick == owner.titlebarDoubleClickEnabled && model.appearance == owner.appearanceMode
                 && model.floating == owner.floatingOnTop && model.sound == owner.soundEnabled,
                 "Settings show the values in effect")

    // 用到的 SF Symbols 都存在（名字写错时系统给 nil，界面上就空一块）。
    var symbols = WindowShadeSettingsSection.allCases.map(\.symbolName) + ["checkmark.circle.fill"]
    let everyModifier = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    for keyCode in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Delete,
                    kVK_ForwardDelete, kVK_Escape, kVK_Tab, kVK_Space] {
      for cap in HotKey.keyCaps(for: HotKey(keyCode: UInt32(keyCode), modifiers: everyModifier)) {
        if case .symbol(let name) = cap { symbols.append(name) }
      }
    }
    for name in symbols {
      precondition(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing SF Symbol: \(name)")
    }

    // 文案（docs/copy-guide.md 第 7 条）：不用字符画符号，设置里不写说明句，不写进度旁白和实现用语。
    let glyphs = CharacterSet(charactersIn: "✓✔●○•·⌃⌥⇧⌘←→↑↓↩⇥⌫⌦…")
    for text in SettingsCopy.all + WelcomeCopy.all {
      precondition(text.rangeOfCharacter(from: glyphs) == nil, "Use SF Symbols instead of glyph characters: \(text)")
      precondition(!["还差", "已就绪", "bundle"].contains(where: text.contains), "No narration or jargon: \(text)")
    }
    for text in SettingsCopy.all {
      precondition(!text.hasSuffix("。"), "Settings show no explanatory sentences: \(text)")
    }

    // 浅色、深色各截一张图，留在 CI 产物里看。
    let directory = URL(fileURLWithPath: ".build/appkit-tests/settings-shots", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func shoot(_ view: NSView, _ name: String) {
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        preconditionFailure("Cannot render \(name)")
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      window.appearance = NSAppearance(named: appearance)
      for section in WindowShadeSettingsSection.allCases {
        settings.select(section: section)
        await drainLayout()
        shoot(content, "\(section)-\(appearance.rawValue)")
      }
      let welcome = NSHostingView(rootView: WelcomeContent(status: PermissionStatus(), isAdmin: false,
                                                           onFinish: {}, onLater: {}))
      welcome.frame = NSRect(origin: .zero, size: WelcomeContent.size)
      welcome.appearance = NSAppearance(named: appearance)
      shoot(welcome, "welcome-\(appearance.rawValue)")
    }

    // 更新：发布版的 Info.plist 有清单地址和公钥才启动更新器；测试包两样都没有，
    // 设置里的开关和“检查更新”按钮不可用，菜单里的“检查更新…”也不可用。
    precondition(UpdaterController.isConfigured(["SUFeedURL": "https://example.com/appcast.xml",
                                                 "SUPublicEDKey": "key"]))
    precondition(!UpdaterController.isConfigured(["SUPublicEDKey": "key"]))
    precondition(!UpdaterController.isConfigured(["SUFeedURL": "", "SUPublicEDKey": "key"]))
    UpdaterController.shared.start()
    precondition(!UpdaterController.shared.isAvailable, "A build without a feed URL must not start the updater")
    model.reload()
    precondition(!model.updaterAvailable, "Update controls are disabled when the updater is not running")
    let updateItem = UpdaterController.shared.makeMenuItem()
    precondition(!UpdaterController.shared.validateMenuItem(updateItem),
                 "Check for Updates must be disabled when the updater is not running")
    window.close()
    print("PASS: settings tabs, values, symbols, copy and update controls; screenshots saved")
  }

  @MainActor
  private static func drainLayout() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        DispatchQueue.main.async { continuation.resume() }
      }
    }
  }
}

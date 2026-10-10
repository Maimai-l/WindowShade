// 应用自己的全局快捷键：每个动作一个可改、可关的组合。
// 1.0.16 起，新安装时不预设任何组合，需要的用户在设置里自己录；从旧版本升级的，
// 没改过的组合沿用升级前的出厂组合（怎样判断见文件末尾的 InstallHistory）。

import Cocoa
import Carbon.HIToolbox

enum GlobalShortcut: String, CaseIterable {
    case toggleShade
    /// 存储键沿用旧名，升级的用户录过的组合照样生效。
    case arrange = "arrangeOrFocus"

    /// Carbon 快捷键编号：事件处理按它分派，与 1.0 起的编号一致；拿掉的动作空出的编号不再复用。
    var hotKeyID: UInt32 {
        switch self {
        case .toggleShade: return 1
        case .arrange: return 2
        }
    }

    /// 设置页与冲突提示里的名字。
    var title: String {
        switch self {
        case .toggleShade: return "收起或展开当前窗口"
        case .arrange: return "整理卷帘条"
        }
    }

    /// 各版本的出厂组合：新安装的为空；1.0.15 及以前是 ⌃⌘C 和 ⌃⌘0。
    /// 只用于让升级的用户照原样使用，不给新安装。
    func factoryHotKey(for history: InstallHistory) -> HotKey? {
        guard history.hadFactoryShortcuts else { return nil }
        let controlCommand = UInt32(controlKey | cmdKey)
        func key(_ code: Int) -> HotKey { HotKey(keyCode: UInt32(code), modifiers: controlCommand) }
        switch self {
        case .toggleShade: return key(kVK_ANSI_C)
        case .arrange: return key(kVK_ANSI_0)
        }
    }

    fileprivate var defaultsKey: String { "GlobalShortcut.\(rawValue)" }
}

enum GlobalShortcutSettings {
    static let numberedExpandKey = "GlobalShortcut.numberedExpand"
    /// Control-Command-1 至 9 这一组的修饰键：编号和菜单顺序绑定，不单独改键，只能整组开关。
    static let numberedModifiers = UInt32(controlKey | cmdKey)
    static let numberedKeyCodes: [UInt32] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ].map(UInt32.init)

    /// 只有单线程的测试会在使用前换掉它再换回；WindowShade 自己从不赋值。
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// 这台 Mac 从哪个版本开始用（启动第一步判断一次并存下，见下面的 InstallHistory）：决定没改过的快捷键是什么。
    static var history: InstallHistory { InstallHistory.settled(in: defaults) }

    /// 没改过时的组合：新安装的为空；升级的沿用原来的出厂组合。
    static func defaultHotKey(for shortcut: GlobalShortcut) -> HotKey? {
        shortcut.factoryHotKey(for: history)
    }

    /// 当前组合；nil 表示关掉了，或没设置过且默认没有组合。
    static func hotKey(for shortcut: GlobalShortcut) -> HotKey? {
        guard let stored = defaults.array(forKey: shortcut.defaultsKey) as? [Int] else {
            return defaultHotKey(for: shortcut)
        }
        guard stored.count == 2 else { return nil }
        return HotKey(keyCode: UInt32(stored[0]), modifiers: UInt32(stored[1]))
    }

    static func setHotKey(_ hotKey: HotKey?, for shortcut: GlobalShortcut) {
        if hotKey == defaultHotKey(for: shortcut) {
            defaults.removeObject(forKey: shortcut.defaultsKey)
        } else if let hotKey {
            defaults.set([Int(hotKey.keyCode), Int(hotKey.modifiers)], forKey: shortcut.defaultsKey)
        } else {
            defaults.set([Int](), forKey: shortcut.defaultsKey)
        }
    }

    /// Control-Command-1 至 9 没改过时是否打开：和别的 Control-Command 组合一样，新安装时关闭，升级的保持打开。
    static var numberedExpandDefault: Bool { history.hadFactoryShortcuts }

    static var numberedExpandEnabled: Bool {
        get { defaults.object(forKey: numberedExpandKey).map { _ in defaults.bool(forKey: numberedExpandKey) } ?? numberedExpandDefault }
        set {
            if newValue == numberedExpandDefault { defaults.removeObject(forKey: numberedExpandKey) }
            else { defaults.set(newValue, forKey: numberedExpandKey) }
        }
    }

    static var isAllDefault: Bool {
        GlobalShortcut.allCases.allSatisfy { hotKey(for: $0) == defaultHotKey(for: $0) }
            && numberedExpandEnabled == numberedExpandDefault
    }

    /// 恢复默认：新安装的全部清空；升级的回到原来的出厂组合（不会因为这一版不再预设就把升级用户的组合也清掉）。
    static func resetAll() {
        for shortcut in GlobalShortcut.allCases { setHotKey(defaultHotKey(for: shortcut), for: shortcut) }
        numberedExpandEnabled = numberedExpandDefault
    }

    /// 这个组合已经被本应用的哪个动作占用（`excluding` 是正在录制的那一个）。
    /// 返回用户看得懂的名字；没冲突返回 nil。
    static func conflictName(for candidate: HotKey, excluding: GlobalShortcut) -> String? {
        for shortcut in GlobalShortcut.allCases where shortcut != excluding {
            if hotKey(for: shortcut) == candidate { return shortcut.title }
        }
        if numberedExpandEnabled, candidate.modifiers == numberedModifiers,
           numberedKeyCodes.contains(candidate.keyCode) {
            return "按编号展开"
        }
        return nil
    }

    /// 录制快捷键时按下一个键的结果。Esc 结束录制；只按修饰键继续等；其余组合按保留规则和冲突判断。
    enum CaptureVerdict: Equatable {
        case keepWaiting
        case cancel
        case accept(HotKey)
        case needsControlOrOption
        case reservedBySystem
        case usedBy(String)
    }

    static func captureVerdict(keyCode: UInt16, modifiers: UInt32, for shortcut: GlobalShortcut) -> CaptureVerdict {
        if keyCode == UInt16(kVK_Escape) { return .cancel }
        if HotKey.isModifierOnlyKeyCode(keyCode) { return .keepWaiting }
        let hotKey = HotKey(keyCode: UInt32(keyCode), modifiers: modifiers)
        if HotKey.isReserved(hotKey) {
            return modifiers & (HotKey.controlMask | HotKey.optionMask) != 0 ? .reservedBySystem : .needsControlOrOption
        }
        if let name = conflictName(for: hotKey, excluding: shortcut) { return .usedBy(name) }
        return .accept(hotKey)
    }

    static func displayName(for shortcut: GlobalShortcut) -> String? {
        hotKey(for: shortcut).map(HotKey.displayName(for:))
    }

    /// 提示文字里这一组的名字。
    static let numberedDisplayName = "Control-Command-1 至 9"

    /// 菜单项上显示的按键：只处理单个字符的键；功能键等显示不了的返回 nil，
    /// 快捷键本身照常生效。
    static func menuKeyEquivalent(for hotKey: HotKey) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key = HotKey.keyName(for: hotKey.keyCode, shift: hotKey.modifiers & UInt32(shiftKey) != 0)
        guard key.count == 1, let character = key.first,
              character.isLetter || character.isNumber || character.isPunctuation else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if hotKey.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if hotKey.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if hotKey.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if hotKey.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return (String(character).lowercased(), modifiers)
    }
}

/// 这台 Mac 上的 WindowShade 是新安装的，还是从旧版本升级的。
///
/// 1.0.16 起，⌃⌘ 那一组快捷键在新安装时不预设，“让开这个 App”对换机的用户默认关闭；
/// 升级的用户不受影响，正在用的组合和已经打开的功能都保持原样。所以第一次需要时判断一次并存下，以后都用存下的结果。
/// 判断依据是旧版本会写下的设置：最可靠的是每次启动都写的声音迁移版本号（从第一版起就有）；
/// 其次是看过欢迎窗口、收起过窗口、改过外观或快捷键（这几项不一定都有，例如用红色按钮关掉欢迎窗口时不会写“看过”）。
/// 因此必须在这一次启动写下任何设置之前判断：放在 WindowShade.swift 的 applicationDidFinishLaunching 开头、
/// 声音迁移和清理收起记录之前。万一判断晚了，新安装会被当成升级、预设 1.0.15 的那一组，不会反过来让老用户丢掉快捷键。
/// 只读写 UserDefaults，可以做单元测试。
enum InstallHistory: Int, Sendable {
    /// 新安装：用新的默认值。
    case fresh = 0
    /// 从 1.0.15 及以前升级的：那时出厂预设了 ⌃⌘ 那一组（⌃⌘C、⌃⌘0，见 factoryHotKey）和 ⌃⌘1…9。
    case shipped = 1
    /// 用过 1.0.16 的测试版：那一版又多占了 ⌃⌘S、L、M、N、H，“让开这个 App”也默认开着。
    case preview = 2

    static let defaultsKey = "InstallHistory"

    /// 1.0.16 测试版每次启动都会写下的键（它当时检查新加的默认组合是否和老用户自己录的组合冲突）。
    static let previewMarker = "GlobalShortcut.newDefaultsChecked.1.0.16"
    /// 以前的版本会写下的键（名字见 WindowShade.swift 开头那一组常量）：有一个就是老安装。
    /// 第一个是以前每一版每次启动都写的（这一版也写，所以要在启动第一步、它被写之前认）。
    static let shippedMarkers = [
        "ShadeSoundMigrationVersion",
        "ShadeOnboardingShown", "ShadeJournalEntries", "ShadeAppearanceMode", "ShadeFloatingOnTop", "ShadeTranslucent",
        "ShadeTitlebarDoubleClickEnabled", "ShadeSoundEnabled", "ShadeFoldSound", "ShadeUnfoldSound",
    ]
    /// 改过任何一个快捷键（录过、清掉过、关掉 ⌃⌘1…9）也是老安装。
    static let shippedPrefix = "GlobalShortcut."

    /// 看现有的设置认一次，不写。
    static func detect(in defaults: UserDefaults) -> InstallHistory {
        if defaults.object(forKey: previewMarker) != nil { return .preview }
        if shippedMarkers.contains(where: { defaults.object(forKey: $0) != nil }) { return .shipped }
        if defaults.dictionaryRepresentation().keys.contains(where: { $0.hasPrefix(shippedPrefix) }) { return .shipped }
        return .fresh
    }

    /// 判断过就用存下的结果；没判断过就现在判断并存下。存的值认不出（以后的版本写的）时按新安装处理。
    @discardableResult
    static func settled(in defaults: UserDefaults) -> InstallHistory {
        if let raw = defaults.object(forKey: defaultsKey) as? Int { return InstallHistory(rawValue: raw) ?? .fresh }
        let found = detect(in: defaults)
        defaults.set(found.rawValue, forKey: defaultsKey)
        return found
    }

    /// 以前就有 ⌃⌘ 那一组出厂组合的安装。
    var hadFactoryShortcuts: Bool { self != .fresh }
}

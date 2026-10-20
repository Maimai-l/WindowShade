// 设置窗口的四页：系统的分组表单（Form + .grouped），对齐、间距、行高都交给系统。
// 每行只有名字和控件；副标题只写名字和控件说明不了的事。图标一律用 SF Symbols，不用字符画符号。
// 文案集中在 SettingsCopy，测试按 docs/copy-guide.md 检查它。

import AppKit
import SwiftUI

enum SettingsCopy {
    static let doubleClick = "双击标题栏收起窗口"
    /// “看一眼”这个功能的开关：名字直接说它做什么，不另加小字（docs/copy-guide.md 规则 1）。
    static let glance = "指针悬停在卷帘条上时显示窗口"

    static let appearance = "外观"
    static let appearanceMode = "收起后显示"
    static let appearanceChoices: [(mode: ShadeAppearanceMode, title: String)] = [
        (.nativeScreenshot, "原标题栏"), (.proxyTitleBar, "简化标题栏"), (.thumbnail, "缩略图"),
    ]
    static let floating = "卷帘条置顶"
    static let stripTranslucency = "卷帘条透明度"
    static let thumbnailTranslucency = "缩略图透明度"

    static let sound = "声音"
    static let playSound = "收起和展开时播放音效"
    static let foldSound = "收起音效"
    static let unfoldSound = "展开音效"

    static let permissions = "权限"
    static let accessibility = "辅助功能"
    /// macOS 26 或更新。用旧 SDK 编译时，macOS 26 报给程序的版本号是 16，所以按主版本号不小于 16 判断。
    static var isMacOS26OrLater: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16 }

    /// 和“系统设置”里那一项同名：macOS 26 叫“录屏与系统录音”，更早的版本叫“屏幕录制”。
    static var screenRecording: String {
        if SettingsCopy.isMacOS26OrLater { return "录屏与系统录音" }
        return "屏幕录制"
    }
    static let granted = "已允许"
    static let grant = "打开系统设置"

    static let launchAtLogin = "登录时打开"
    /// 页名和“系统设置”一致：macOS 26 叫“登录项与扩展”，更早的版本叫“登录项”。
    static var launchNeedsApproval: String {
        if SettingsCopy.isMacOS26OrLater { return "请在“系统设置”的“登录项与扩展”中允许" }
        return "请在“系统设置”的“登录项”中允许"
    }
    static let launchUnavailable = "请将 WindowShade 移到“应用程序”文件夹中"
    static let launchFailed = "未能更改登录项"

    /// 照系统设置“键盘快捷键”一页顶上的那句说明写，“连按”换成全产品通用的“双击”。
    static let shortcutHint = "若要更改快捷键，请双击组合键，然后按下新的组合键。"
    static let numbered = "按编号展开"
    static let resetShortcuts = "恢复默认"
    static let noShortcut = "无"
    static let recording = "现在按下按键"
    /// “按编号展开”只换修饰键：按住修饰键再按一个键，界面上提示按数字。
    static let recordingModifiers = "按住修饰键并按下数字键"
    static let needsControlOrOption = "组合里要有 Control 或 Option"
    static let reservedBySystem = "系统已占用这个组合"
    static func usedBy(_ name: String) -> String { "已用于：\(name)" }

    static let welcomeWindow = "欢迎使用 WindowShade"
    static let diagnostics = "诊断日志"
    static let open = "打开"

    /// 测试用：设置里可能出现的小字，只有随系统设置变化的状态和出问题时的办法（docs/copy-guide.md 规则 1、2）。
    static var notes: [String] { [launchNeedsApproval, launchUnavailable, launchFailed, "三击标题栏会缩放窗口", "三击标题栏会最小化窗口"] }

    /// 测试用：设置窗口里出现的全部固定文案。
    static var all: [String] {
        [doubleClick, glance, appearance, appearanceMode, floating,
         stripTranslucency, thumbnailTranslucency, sound, playSound, foldSound, unfoldSound,
         permissions, accessibility, screenRecording, granted, grant,
         launchAtLogin, launchNeedsApproval, launchUnavailable, launchFailed,
         shortcutHint, numbered, resetShortcuts,
         noShortcut, recording, recordingModifiers, needsControlOrOption, reservedBySystem, usedBy(""),
         welcomeWindow, diagnostics, open]
            + appearanceChoices.map { $0.title }
            + WindowShadeSettingsSection.allCases.map { $0.title }
            + GlobalShortcut.allCases.map { $0.title }
            + [UpdateCopy.settingsGroup, UpdateCopy.autoCheck, UpdateCopy.checkButton]
            + shadeSoundChoices.map { $0.label }
    }
}

/// 两项系统授权的状态，设置窗口和欢迎窗口共用。
@MainActor
final class PermissionStatus: ObservableObject {
    @Published private(set) var accessibility = hasAccessibilityPermission()
    @Published private(set) var screenRecording = hasScreenRecordingPermission()

    var allGranted: Bool { accessibility && screenRecording }

    func refresh() {
        let ax = hasAccessibilityPermission()
        let screen = hasScreenRecordingPermission()
        if ax != accessibility { accessibility = ax }
        if screen != screenRecording { screenRecording = screen }
    }
}

/// 设置窗口显示的值。界面改了哪一项，didSet 交给 AppDelegate 生效；reload 从 AppDelegate 整体读回来
///（菜单里改的也一样）；读的时候 loading 为真，didSet 不会把值写回 AppDelegate。
@MainActor
final class SettingsModel: ObservableObject {
    private weak var app: AppDelegate?
    let permissions = PermissionStatus()
    private var loading = false

    @Published private(set) var tripleClickNote: String?
    @Published private(set) var launchNote: String?
    @Published private(set) var updaterAvailable = false
    @Published private(set) var version = ""
    @Published private(set) var hotKeys: [GlobalShortcut: HotKey] = [:]
    @Published private(set) var shortcutsAreDefault = true
    @Published private(set) var numberedModifiers = GlobalShortcutSettings.defaultNumberedModifiers

    @Published var doubleClick = true { didSet { apply { $0.setTitlebarDoubleClick(self.doubleClick) } } }
    @Published var glance = true { didSet { apply { $0.setGlanceEnabled(self.glance) } } }
    @Published var appearance: ShadeAppearanceMode = .nativeScreenshot {
        didSet { apply { $0.setAppearanceMode(self.appearance) } }
    }
    @Published var floating = true { didSet { apply { $0.setFloatingOnTop(self.floating) } } }
    /// 百分比，0 到 ShadeTranslucency.maximum × 100。拖动时连续写入，不整体读回。
    @Published var translucency: Double = 0 {
        didSet { if !loading { app?.setShadeTranslucency(percent: translucency) } }
    }
    @Published var sound = true { didSet { apply { $0.setSoundEnabled(self.sound) } } }
    @Published var foldSound = "" { didSet { apply { $0.setFoldSound(self.foldSound) } } }
    @Published var unfoldSound = "" { didSet { apply { $0.setUnfoldSound(self.unfoldSound) } } }
    @Published var launchAtLogin = false { didSet { apply { $0.setLaunchAtLogin(self.launchAtLogin) } } }
    @Published var autoCheck = false {
        didSet { if !loading { UpdaterController.shared.automaticallyChecks = autoCheck } }
    }
    @Published var numbered = false { didSet { apply { $0.setNumberedShortcuts(self.numbered) } } }

    init(app: AppDelegate?) {
        self.app = app
        reload()
    }

    func reload() {
        loading = true
        defer { loading = false }
        permissions.refresh()
        tripleClickNote = systemTitlebarTripleClickDescription()
        glance = GlanceController.isEnabled
        translucency = (ShadeTranslucency.fraction() * 100).rounded()
        let updater = UpdaterController.shared
        autoCheck = updater.automaticallyChecks
        updaterAvailable = updater.isAvailable
        version = updater.currentVersion
        var keys: [GlobalShortcut: HotKey] = [:]
        for shortcut in GlobalShortcut.allCases { keys[shortcut] = GlobalShortcutSettings.hotKey(for: shortcut) }
        hotKeys = keys
        numbered = GlobalShortcutSettings.numberedExpandEnabled
        numberedModifiers = GlobalShortcutSettings.numberedModifiers
        shortcutsAreDefault = GlobalShortcutSettings.isAllDefault
        guard let app else { return }
        doubleClick = app.titlebarDoubleClickEnabled
        appearance = app.appearanceMode
        floating = app.floatingOnTop
        sound = app.soundEnabled
        foldSound = app.soundName(defaultsKey: shadeFoldSoundDefaultsKey, fallback: shadeDefaultFoldSound)
        unfoldSound = app.soundName(defaultsKey: shadeUnfoldSoundDefaultsKey, fallback: shadeDefaultUnfoldSound)
        launchAtLogin = app.launchAtLoginEnabled()
        launchNote = app.launchAtLoginNote()
        // 登录项状态在后台查；查到的结果变了，再读一遍设置。
        LaunchAtLoginState.refresh { [weak self] in self?.reload() }
    }

    /// 界面改的值交给 AppDelegate，再读回实际生效的（例如登录项注册失败时开关弹回去）。
    private func apply(_ change: (AppDelegate) -> Void) {
        guard !loading else { return }
        if let app { change(app) }
        reload()
    }

    func setShortcut(_ hotKey: HotKey?, for shortcut: GlobalShortcut) {
        app?.setShortcut(hotKey, for: shortcut)
        reload()
    }

    func perform(_ action: (AppDelegate) -> Void) {
        if let app { action(app) }
        reload()
    }

    /// 开始、结束录制快捷键：录制期间 WindowShade 自己的全局快捷键先注销（见 AppDelegate.pauseGlobalShortcutsForRecording）。
    func setRecordingShortcut(_ recording: Bool) {
        if recording {
            app?.pauseGlobalShortcutsForRecording()
        } else {
            app?.resumeGlobalShortcutsAfterRecording()
        }
    }
}

// MARK: - 页面

@MainActor
struct SettingsPage: View {
    let section: WindowShadeSettingsSection
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            switch section {
            case .shade: ShadeSettings(model: model)
            case .shortcuts: ShortcutSettings(model: model)
            case .permissions: PermissionSettings(model: model)
            case .advanced: AdvancedSettings(model: model)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct ShadeSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            Toggle(isOn: $model.doubleClick) {
                Text(SettingsCopy.doubleClick)
                if let note = model.tripleClickNote { Text(note) }
            }
            Toggle(SettingsCopy.glance, isOn: $model.glance)
        }
        Section(SettingsCopy.appearance) {
            Picker(SettingsCopy.appearanceMode, selection: $model.appearance) {
                ForEach(SettingsCopy.appearanceChoices.indices, id: \.self) { index in
                    Text(SettingsCopy.appearanceChoices[index].title).tag(SettingsCopy.appearanceChoices[index].mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle(SettingsCopy.floating, isOn: $model.floating)
            LabeledContent(model.appearance == .thumbnail ? SettingsCopy.thumbnailTranslucency
                                                         : SettingsCopy.stripTranslucency) {
                HStack {
                    Slider(value: $model.translucency, in: 0...(ShadeTranslucency.maximum * 100))
                        .frame(width: 160)
                    Text(verbatim: "\(Int(model.translucency))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
        }
        Section(SettingsCopy.sound) {
            Toggle(SettingsCopy.playSound, isOn: $model.sound)
            soundPicker(SettingsCopy.foldSound, $model.foldSound)
            soundPicker(SettingsCopy.unfoldSound, $model.unfoldSound)
        }
    }

    private func soundPicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(shadeSoundChoices.indices, id: \.self) { index in
                Text(shadeSoundChoices[index].label).tag(shadeSoundChoices[index].name)
            }
        }
        .disabled(!model.sound)
    }
}

@MainActor
private struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // 照系统设置的“键盘快捷键”：分组第一行是操作说明，下面每行一个复选框、名字和右边的组合，双击组合就改。
        Section {
            Text(SettingsCopy.shortcutHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            ShortcutRow(model: model, shortcut: .toggleShade)
            ShortcutRow(model: model, shortcut: .arrange)
            NumberedShortcutRow(model: model)
        } footer: {
            // 放在分组下面，不单独占一张卡片。
            HStack {
                Spacer()
                Button(SettingsCopy.resetShortcuts) { model.perform { $0.resetShortcuts() } }
                    .disabled(model.shortcutsAreDefault)
            }
        }
    }
}

@MainActor
private struct PermissionSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section(SettingsCopy.permissions) {
            PermissionRows(status: model.permissions)
        }
        Section {
            Toggle(isOn: $model.launchAtLogin) {
                Text(SettingsCopy.launchAtLogin)
                if let note = model.launchNote { Text(note) }
            }
        }
        Section(UpdateCopy.settingsGroup) {
            Toggle(UpdateCopy.autoCheck, isOn: $model.autoCheck)
                .disabled(!model.updaterAvailable)
            LabeledContent(UpdateCopy.currentVersionRow(model.version)) {
                Button(UpdateCopy.checkButton) { UpdaterController.shared.checkForUpdates(nil) }
                    .disabled(!model.updaterAvailable)
            }
        }
    }
}

@MainActor
private struct AdvancedSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section {
            LabeledContent(SettingsCopy.welcomeWindow) {
                Button(SettingsCopy.open) { model.perform { $0.showWelcomeGuide() } }
                    .accessibilityLabel("打开“\(SettingsCopy.welcomeWindow)”")
            }
            LabeledContent(SettingsCopy.diagnostics) {
                Button(SettingsCopy.open) { model.perform { $0.openDiagnosticsLog() } }
                    .accessibilityLabel(SettingsCopy.open + SettingsCopy.diagnostics)
            }
        }
    }
}

// MARK: - 零件

/// 两行授权：已授权时一个系统的对勾符号和“已允许”，没授权时一个“打开系统设置”按钮，打开系统设置里对应的那一页。
@MainActor
struct PermissionRows: View {
    @ObservedObject var status: PermissionStatus

    var body: some View {
        row(SettingsCopy.accessibility, granted: status.accessibility, open: openAccessibilityPrivacySettings)
        row(SettingsCopy.screenRecording, granted: status.screenRecording, open: openScreenRecordingPrivacySettings)
    }

    private func row(_ title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label(SettingsCopy.granted, systemImage: "checkmark.circle.fill")
                    .labelStyle(GrantedLabelStyle())
            } else {
                Button(SettingsCopy.grant, action: open)
                    .accessibilityLabel(title + "，" + SettingsCopy.grant)
            }
        }
    }
}

private struct GrantedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.green)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// 按键组合显示成一串 SF Symbols 和文字，排在同一行文字里，基线由系统对齐。
enum KeyCaps {
    static func text(_ caps: [HotKey.KeyCap]) -> Text {
        caps.reduce(Text(verbatim: "")) { result, cap in
            switch cap {
            case .symbol(let name): return Text("\(result)\(Image(systemName: name))")
            case .text(let text): return Text("\(result)\(text)")
            }
        }
    }
}

/// 一行全局快捷键，照系统设置：复选框、名字、右边的组合。双击组合开始录制，按下新的组合就换上，Esc 取消。
/// 取消勾选时关掉这个快捷键，组合显示为灰色，再勾选时恢复使用；没设过组合时勾上就开始录制。
/// 录制时只在这一行接收按键，不装全局监听。
@MainActor
private struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let shortcut: GlobalShortcut
    @State private var recording = false
    @State private var message: String?

    private var enabled: Binding<Bool> {
        Binding(get: { model.hotKeys[shortcut] != nil }, set: { on in
            message = nil
            if on, let last = GlobalShortcutSettings.lastHotKey(for: shortcut) {
                model.setShortcut(last, for: shortcut)
            } else if on {
                recording = true
            } else {
                recording = false
                model.setShortcut(nil, for: shortcut)
            }
        })
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(shortcut.title, isOn: enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(shortcut.title)
                .foregroundStyle(recording ? Color.white : Color.primary)
            Spacer()
            current
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    message = nil
                    recording = true
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { recording = true }
        }
        .background(KeyCapture(isActive: $recording, onKey: capture, onRecording: recordingChanged))
        .modifier(SelectedShortcutRow(isSelected: recording))
        .task(id: message) {
            // 录到不能用的组合：说明原因，1.8 秒后回到当前组合。
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            message = nil
        }
    }

    @ViewBuilder private var current: some View {
        if recording {
            RecordingField()
        } else if let message {
            Text(message).foregroundStyle(.secondary)
        } else if let hotKey = model.hotKeys[shortcut] {
            KeyCaps.text(HotKey.keyCaps(for: hotKey))
                .accessibilityLabel(HotKey.displayName(for: hotKey))
        } else if let last = GlobalShortcutSettings.lastHotKey(for: shortcut) {
            KeyCaps.text(HotKey.keyCaps(for: last))
                .foregroundStyle(.secondary)
                .accessibilityLabel(HotKey.displayName(for: last))
        } else {
            Text(SettingsCopy.noShortcut).foregroundStyle(.secondary)
        }
    }

    private func capture(_ event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= HotKey.commandMask }
        if flags.contains(.option) { modifiers |= HotKey.optionMask }
        if flags.contains(.control) { modifiers |= HotKey.controlMask }
        if flags.contains(.shift) { modifiers |= HotKey.shiftMask }
        let verdict = GlobalShortcutSettings.captureVerdict(keyCode: event.keyCode, modifiers: modifiers, for: shortcut)
        // 只按修饰键不构成快捷键：保持录制状态，等真正的键。
        if verdict == .keepWaiting { return }
        recording = false
        switch verdict {
        case .accept(let hotKey): model.setShortcut(hotKey, for: shortcut)
        case .needsControlOrOption: reject(SettingsCopy.needsControlOrOption)
        case .reservedBySystem: reject(SettingsCopy.reservedBySystem)
        case .usedBy(let name): reject(SettingsCopy.usedBy(name))
        case .keepWaiting, .cancel: break
        }
    }

    private func reject(_ text: String) {
        shadeSounds.beep()
        message = text
    }

    private func recordingChanged(_ recording: Bool) {
        model.setRecordingShortcut(recording)
    }
}

/// “按编号展开”一行：复选框、名字、右边的修饰键加“1–9”。双击右边的组合，按住新的修饰键再按一个数字，
/// 换掉这一组的修饰键；数字 1 至 9 跟着菜单里的顺序，不能改。规则和别的快捷键一样（GlobalShortcutSettings.numberedVerdict）。
@MainActor
private struct NumberedShortcutRow: View {
    @ObservedObject var model: SettingsModel
    @State private var recording = false
    @State private var message: String?

    var body: some View {
        HStack(spacing: 10) {
            Toggle(SettingsCopy.numbered, isOn: $model.numbered)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(SettingsCopy.numbered)
                .foregroundStyle(recording ? Color.white : Color.primary)
            Spacer()
            current
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    message = nil
                    recording = true
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { recording = true }
        }
        .background(KeyCapture(isActive: $recording, onKey: capture, onRecording: recordingChanged))
        .modifier(SelectedShortcutRow(isSelected: recording))
        .task(id: message) {
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            message = nil
        }
    }

    @ViewBuilder private var current: some View {
        if recording {
            RecordingField(prompt: SettingsCopy.recordingModifiers)
        } else if let message {
            Text(message).foregroundStyle(.secondary)
        } else {
            Text("\(KeyCaps.text(HotKey.modifierCaps(model.numberedModifiers)))1–9")
                .foregroundStyle(model.numbered ? .primary : .secondary)
                .accessibilityLabel(GlobalShortcutSettings.numberedDisplayName)
        }
    }

    private func capture(_ event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= HotKey.commandMask }
        if flags.contains(.option) { modifiers |= HotKey.optionMask }
        if flags.contains(.control) { modifiers |= HotKey.controlMask }
        if flags.contains(.shift) { modifiers |= HotKey.shiftMask }
        let verdict = GlobalShortcutSettings.numberedVerdict(keyCode: event.keyCode, modifiers: modifiers)
        if verdict == .keepWaiting { return }
        recording = false
        switch verdict {
        case .accept(let chosen): model.perform { $0.setNumberedModifiers(chosen) }
        case .needsControlOrOption: reject(SettingsCopy.needsControlOrOption)
        case .reservedBySystem: reject(SettingsCopy.reservedBySystem)
        case .usedBy(let name): reject(SettingsCopy.usedBy(name))
        case .keepWaiting, .cancel: break
        }
    }

    private func reject(_ text: String) {
        shadeSounds.beep()
        message = text
    }

    private func recordingChanged(_ recording: Bool) {
        model.setRecordingShortcut(recording)
    }
}

/// 正在录制的那一行照系统设置，整行用强调色作选中背景。名字改白色在各行里做，右边的输入框见 RecordingField。
private struct SelectedShortcutRow: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content.listRowBackground(Color.accentColor)
        } else {
            content
        }
    }
}

/// 录制时右边的空白输入框：白底，右端有闪烁的插入点。prompt 只供 VoiceOver 读出，不显示。
private struct RecordingField: View {
    var prompt: String = SettingsCopy.recording

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let visible = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            HStack {
                Spacer()
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 16)
                    .opacity(visible ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .frame(width: 180, height: 22)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
        }
        .accessibilityElement()
        .accessibilityLabel(prompt)
    }
}

/// 录制快捷键时接收按键的透明视图：isActive 为真时成为第一响应者，Esc、失去焦点或设置窗口不再是当前窗口时结束录制。
/// 成为第一响应者时调用 onRecording(true)，结束时调用 onRecording(false)：录制期间先注销 WindowShade 自己的全局快捷键，
/// 不然已经在用的组合按下去执行的是它的动作，送不到这里（见 AppDelegate.pauseGlobalShortcutsForRecording）。
private struct KeyCapture: NSViewRepresentable {
    @Binding var isActive: Bool
    let onKey: (NSEvent) -> Void
    let onRecording: (Bool) -> Void

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onBegin: (() -> Void)?
        var onEnd: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            onBegin?()
            return true
        }

        /// 设置窗口不再是当前窗口（切到别的应用程序、关掉窗口）时结束录制：全局快捷键注销着，要马上注册回来。
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                                       name: NSWindow.didResignKeyNotification, object: newWindow)
            }
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            guard let window, window.firstResponder === self else { return }
            window.makeFirstResponder(nil)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEnd?() } else { onKey?(event) }   // 53：Esc
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else {
                return super.performKeyEquivalent(with: event)
            }
            onKey?(event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onEnd?()
            return super.resignFirstResponder()
        }
    }

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        let binding = $isActive
        let recordingChanged = onRecording
        view.onBegin = { recordingChanged(true) }
        view.onEnd = {
            if binding.wrappedValue { binding.wrappedValue = false }
            recordingChanged(false)
        }
        if isActive, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !isActive, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

// 设置窗口的四页：系统的分组表单（Form + .grouped），对齐、间距、行高都交给系统。
// 每行只有名字和控件；副标题只写名字和控件说明不了的事。图标一律用 SF Symbols，不用字符画符号。
// 文案集中在 SettingsCopy，测试按 docs/copy-guide.md 检查它。

import AppKit
import SwiftUI

enum SettingsCopy {
    static let doubleClick = "双击标题栏收起窗口"
    static let glance = "看一眼"
    static let glanceNote = "指针停在卷帘条上时显示窗口"

    static let appearance = "外观"
    static let appearanceMode = "收起后显示"
    static let appearanceChoices: [(mode: ShadeAppearanceMode, title: String)] = [
        (.nativeScreenshot, "原标题栏"), (.proxyTitleBar, "简化标题栏"), (.thumbnail, "缩略图"),
    ]
    static let floating = "卷帘条置顶"
    static let stripTranslucency = "卷帘条半透明"
    static let thumbnailTranslucency = "缩略图半透明"

    static let sound = "声音"
    static let playSound = "收起和展开时播放音效"
    static let foldSound = "收起音效"
    static let unfoldSound = "展开音效"

    static let permissions = "权限"
    static let accessibility = "辅助功能"
    static let accessibilityNote = "找到、移动和恢复窗口"
    static let screenRecording = "屏幕录制"
    static let screenRecordingNote = "原标题栏和看一眼要用窗口画面"
    static let granted = "已授权"
    static let grant = "打开系统设置"

    static let launchAtLogin = "登录时自动启动"
    static let launchNeedsApproval = "要在系统设置的“登录项”里允许"
    static let launchUnavailable = "这个版本不能在登录时启动"
    static let launchFailed = "无法修改登录时自动启动"

    static let shadedWindows = "已收起的窗口"
    static let arrangeNote = "把卷帘条排到屏幕一侧，再按一次放回原位"
    static let numbered = "按编号展开"
    static let numberedNote = "加数字 1 至 9，展开菜单里对应的窗口"
    static let resetShortcuts = "恢复默认"
    static let notSet = "未设置"
    static let record = "录制"
    static let recording = "按下快捷键"
    static let cancel = "取消"
    static let clear = "清除"
    static let needsControlOrOption = "组合里要有 Control 或 Option"
    static let reservedBySystem = "系统已占用这个组合"
    static func usedBy(_ name: String) -> String { "已用于：\(name)" }

    static let welcomeWindow = "欢迎窗口"
    static let diagnostics = "诊断日志"
    static let open = "打开"

    /// 测试用：设置窗口里出现的全部固定文案。
    static var all: [String] {
        [doubleClick, glance, glanceNote, appearance, appearanceMode, floating,
         stripTranslucency, thumbnailTranslucency, sound, playSound, foldSound, unfoldSound,
         permissions, accessibility, accessibilityNote, screenRecording, screenRecordingNote, granted, grant,
         launchAtLogin, launchNeedsApproval, launchUnavailable, launchFailed,
         shadedWindows, arrangeNote, numbered, numberedNote, resetShortcuts,
         notSet, record, recording, cancel, clear, needsControlOrOption, reservedBySystem, usedBy(""),
         welcomeWindow, diagnostics, open]
            + appearanceChoices.map { $0.title }
            + WindowShadeSettingsSection.allCases.map { $0.title }
            + GlobalShortcut.allCases.map { $0.title }
            + [UpdateCopy.settingsGroup, UpdateCopy.autoCheck, UpdateCopy.autoCheckDetail, UpdateCopy.checkButton]
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
///（菜单里改的也一样），读的时候不触发 didSet。
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
            Toggle(isOn: $model.glance) {
                Text(SettingsCopy.glance)
                Text(SettingsCopy.glanceNote)
            }
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
        Section {
            ShortcutRow(model: model, shortcut: .toggleShade, note: nil)
        }
        Section {
            ShortcutRow(model: model, shortcut: .arrange, note: SettingsCopy.arrangeNote)
            Toggle(isOn: $model.numbered) {
                Text(SettingsCopy.numbered)
                Text("\(KeyCaps.text(HotKey.modifierCaps(GlobalShortcutSettings.numberedModifiers))) \(SettingsCopy.numberedNote)")
            }
        } header: {
            Text(SettingsCopy.shadedWindows)
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
            Toggle(isOn: $model.autoCheck) {
                Text(UpdateCopy.autoCheck)
                Text(UpdateCopy.autoCheckDetail)
            }
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
                    .accessibilityLabel(SettingsCopy.open + SettingsCopy.welcomeWindow)
            }
            LabeledContent(SettingsCopy.diagnostics) {
                Button(SettingsCopy.open) { model.perform { $0.openDiagnosticsLog() } }
                    .accessibilityLabel(SettingsCopy.open + SettingsCopy.diagnostics)
            }
        }
    }
}

// MARK: - 零件

/// 两行授权：已授权时一个系统的对勾符号和“已授权”，没授权时一个“打开系统设置”按钮，打开系统设置里对应的那一页。
@MainActor
struct PermissionRows: View {
    @ObservedObject var status: PermissionStatus

    var body: some View {
        row(SettingsCopy.accessibility, SettingsCopy.accessibilityNote,
            granted: status.accessibility, open: openAccessibilityPrivacySettings)
        row(SettingsCopy.screenRecording, SettingsCopy.screenRecordingNote,
            granted: status.screenRecording, open: openScreenRecordingPrivacySettings)
    }

    private func row(_ title: String, _ note: String, granted: Bool, open: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label(SettingsCopy.granted, systemImage: "checkmark.circle.fill")
                    .labelStyle(GrantedLabelStyle())
            } else {
                Button(SettingsCopy.grant, action: open)
                    .accessibilityLabel(title + "，" + SettingsCopy.grant)
            }
        } label: {
            Text(title)
            Text(note)
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

/// 一行全局快捷键：当前组合（或提示），“录制”和“清除”。录制时只在这一行接收按键，不装全局监听。
@MainActor
private struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let shortcut: GlobalShortcut
    let note: String?
    @State private var recording = false
    @State private var message: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                current
                    .frame(minWidth: 96, alignment: .trailing)
                Button(recording ? SettingsCopy.cancel : SettingsCopy.record) {
                    message = nil
                    recording.toggle()
                }
                Button(SettingsCopy.clear) {
                    recording = false
                    model.setShortcut(nil, for: shortcut)
                }
                .disabled(model.hotKeys[shortcut] == nil)
            }
            .background(KeyCapture(isActive: $recording, onKey: capture))
        } label: {
            Text(shortcut.title)
            if let note { Text(note) }
        }
        .task(id: message) {
            // 录到不能用的组合：说明原因，1.8 秒后回到当前组合。
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            message = nil
        }
    }

    @ViewBuilder private var current: some View {
        if recording {
            Text(SettingsCopy.recording).foregroundStyle(.secondary)
        } else if let message {
            Text(message).foregroundStyle(.secondary)
        } else if let hotKey = model.hotKeys[shortcut] {
            KeyCaps.text(HotKey.keyCaps(for: hotKey))
                .accessibilityLabel(HotKey.displayName(for: hotKey))
        } else {
            Text(SettingsCopy.notSet).foregroundStyle(.secondary)
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
}

/// 录制快捷键时接收按键的透明视图：isActive 为真时成为第一响应者，Esc 或失去焦点时结束录制。
private struct KeyCapture: NSViewRepresentable {
    @Binding var isActive: Bool
    let onKey: (NSEvent) -> Void

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onEnd: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

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
        view.onEnd = { if binding.wrappedValue { binding.wrappedValue = false } }
        if isActive, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !isActive, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

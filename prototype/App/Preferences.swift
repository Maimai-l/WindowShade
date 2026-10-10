// 设置和欢迎窗口背后的动作：改设置、打开窗口、权限刷新。界面本身在 SettingsView.swift 和 Welcome.swift。
// 作为 AppDelegate 扩展实现。

import Cocoa
import SwiftUI

extension AppDelegate {
@objc func toggleTitlebarDoubleClick(_ sender: NSMenuItem) {
        titlebarDoubleClickEnabled.toggle()
        UserDefaults.standard.set(titlebarDoubleClickEnabled, forKey: shadeTitlebarDoubleClickDefaultsKey)
        rebuildMenu()
        refreshPreferencesWindowIfOpen()
    }


    func soundName(defaultsKey: String, fallback: String) -> String {
        let name = UserDefaults.standard.string(forKey: defaultsKey) ?? fallback
        return shadeSoundChoices.contains(where: { $0.name == name }) ? name : fallback
    }

    func playShadeSound(_ name: String) {
        guard soundEnabled else { return }
        shadeSounds.play(name)
    }

    /// 收起、展开动画开始前提前启动音频设备（见 ShadeSoundPlayer 的说明），音效才能和动作同时出现。
    func prewarmShadeSound(_ name: String) {
        guard soundEnabled else { return }
        shadeSounds.prewarm(name)
    }

    func playFoldSound() {
        playShadeSound(soundName(defaultsKey: shadeFoldSoundDefaultsKey, fallback: shadeDefaultFoldSound))
    }

    func prewarmFoldSound() {
        prewarmShadeSound(soundName(defaultsKey: shadeFoldSoundDefaultsKey, fallback: shadeDefaultFoldSound))
    }

    func playUnfoldSound() {
        playShadeSound(soundName(defaultsKey: shadeUnfoldSoundDefaultsKey, fallback: shadeDefaultUnfoldSound))
    }

    func prewarmUnfoldSound() {
        prewarmShadeSound(soundName(defaultsKey: shadeUnfoldSoundDefaultsKey, fallback: shadeDefaultUnfoldSound))
    }

    func refreshPreferencesWindowIfOpen() {
        if let settingsWindow,
           settingsWindow.window?.isVisible == true {
            settingsWindow.refreshSettings()
        }
    }

    func quietNotice(_ message: String, log: String? = nil) {
        wlog(log ?? "notice: \(message)")
        statusNoticeWorkItem?.cancel()
        // 菜单栏上的标题保持简短（完整文案放在鼠标提示和辅助功能的值里），
        // 否则一句长提示会让状态栏按钮变得很宽，把旁边的菜单栏项目推开。
        statusItem.button?.title = " \(PaperSurfaceAccessibility.statusItemNoticeTitle(message))"
        statusItem.button?.toolTip = message
        statusItem.button?.setAccessibilityValue(message)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusNoticeWorkItem = nil
            self.rebuildMenu()
        }
        statusNoticeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

/// 系统标准“关于”面板 + 一句用途说明与许可信息（代理应用从状态栏菜单进入）。
@objc func showAboutPanel() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    NSApp.orderFrontStandardAboutPanel(options: StandardMenu.aboutPanelOptions(
        version: version, build: build))
    NSApp.activate()
}

@objc func showPreferences() {
        showSettingsWindow()
    }

    // MARK: 设置窗口改动的设置（SettingsModel 调用；改完都会刷新菜单和设置窗口）

    func setTitlebarDoubleClick(_ on: Bool) {
        titlebarDoubleClickEnabled = on
        UserDefaults.standard.set(on, forKey: shadeTitlebarDoubleClickDefaultsKey)
        rebuildMenu()
    }

    func setGlanceEnabled(_ on: Bool) {
        GlanceController.isEnabled = on
        if !on { MainActor.assumeIsolated { glance.cancelAll(reason: "setting-off") } }
        rebuildMenu()
    }

    func setFloatingOnTop(_ on: Bool) {
        floatingOnTop = on
        UserDefaults.standard.set(on, forKey: shadeFloatingOnTopDefaultsKey)
        refreshOverlayPresentation(bringForward: on)
        rebuildMenu()
    }

    /// percent：0 到 ShadeTranslucency.maximum × 100。
    func setShadeTranslucency(percent: Double) {
        let stored = ShadeTranslucency.set(percent.rounded() / 100)
        translucent = stored > 0.001
        applyShadeTranslucencyToOverlays()
    }

    func setSoundEnabled(_ on: Bool) {
        soundEnabled = on
        UserDefaults.standard.set(on, forKey: shadeSoundEnabledDefaultsKey)
    }

    func setFoldSound(_ name: String) {
        foldSoundName = name
        UserDefaults.standard.set(name, forKey: shadeFoldSoundDefaultsKey)
        playFoldSound()
    }

    func setUnfoldSound(_ name: String) {
        unfoldSoundName = name
        UserDefaults.standard.set(name, forKey: shadeUnfoldSoundDefaultsKey)
        playUnfoldSound()
    }

    /// 读的是后台最近一次查到的状态（见 App/LaunchAtLogin.swift），不在主线程向系统查询。
    func launchAtLoginEnabled() -> Bool {
        LaunchAtLoginState.status == .enabled
    }

    /// 只在开关本身说明不了的时候写一句。
    func launchAtLoginNote() -> String? {
        switch LaunchAtLoginState.status {
        case .requiresApproval: return SettingsCopy.launchNeedsApproval
        case .notFound: return SettingsCopy.launchUnavailable
        default: return nil
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LaunchAtLoginState.set(on) { [weak self] failure in
            if let failure {
                self?.quietNotice(SettingsCopy.launchFailed, log: "launch-at-login: failed \(failure)")
            }
            self?.refreshPreferencesWindowIfOpen()
        }
    }

    /// 改键后立刻生效：重新注册、刷新菜单；新组合注册失败时退回原来的组合。
    func setShortcut(_ hotKey: HotKey?, for shortcut: GlobalShortcut) {
        let previous = GlobalShortcutSettings.hotKey(for: shortcut)
        guard hotKey != previous else { return }
        GlobalShortcutSettings.setHotKey(hotKey, for: shortcut)
        registerGlobalShortcuts()
        if hotKey != nil, unavailableHotKeyIDs.contains(shortcut.hotKeyID) {
            GlobalShortcutSettings.setHotKey(previous, for: shortcut)
            registerGlobalShortcuts()
        }
        rebuildMenu()
        refreshPreferencesWindowIfOpen()
    }

    func setNumberedShortcuts(_ on: Bool) {
        GlobalShortcutSettings.numberedExpandEnabled = on
        registerGlobalShortcuts()
        rebuildMenu()
        refreshPreferencesWindowIfOpen()
    }

    func resetShortcuts() {
        GlobalShortcutSettings.resetAll()
        registerGlobalShortcuts()
        rebuildMenu()
        refreshPreferencesWindowIfOpen()
    }

    func openDiagnosticsLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WindowShade/windowshade.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }

    // MARK: 欢迎窗口

    @objc func showWelcomeGuide() {
        showPermissionOnboarding()
    }

    func showPermissionOnboardingIfNeeded(force: Bool) {
        let missing = !hasAccessibilityPermission() || !hasScreenRecordingPermission()
        let shouldShowFirstRun = !UserDefaults.standard.bool(forKey: shadeOnboardingShownDefaultsKey)
        guard missing || shouldShowFirstRun || force else { return }
        if !force && UserDefaults.standard.bool(forKey: shadeOnboardingShownDefaultsKey) { return }
        showPermissionOnboarding()
    }

    /// 欢迎使用 WindowShade：两项授权（见 Welcome.swift）。
    func showPermissionOnboarding() {
        MainActor.assumeIsolated { showWelcome() }
    }

    @MainActor private func showWelcome() {
        // 已经开着：不重建、不挪回正中，只拿到最前面。
        if let window = onboardingWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            updateOnboardingRefresh()
            return
        }
        let status = PermissionStatus()
        onboardingPermissions = status
        let content = WelcomeContent(status: status, isAdmin: WelcomeCopy.isAdminUser(),
                                     onFinish: { [weak self] in self?.dismissOnboarding() },
                                     onLater: { [weak self] in self?.dismissOnboarding() })
        let window: NSWindow
        if let existing = onboardingWindow {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: WelcomeContent.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = WelcomeCopy.title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            onboardingWindow = window
            // 点关闭按钮也算看过：否则下次启动它又会自己弹出来。看过之后缺权限也不再自动弹出，
            // 只有 force（例如没有辅助功能权限时按了快捷键）才会再打开。
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(true, forKey: shadeOnboardingShownDefaultsKey)
                    self?.onboardingRefreshTimer?.invalidate()
                    self?.onboardingRefreshTimer = nil
                }
            }
            // 整个被挡住、在别的桌面上时不再每秒查；又看得见了马上刷新一次、接着查。
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOnboardingRefresh() }
            }
        }
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(WelcomeContent.size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateOnboardingRefresh()
    }

    /// 授权的刷新：在系统设置里打开了，这里马上显示“已允许”。只在窗口看得见、还没全部授权时每秒查一次。
    @MainActor func updateOnboardingRefresh() {
        guard let window = onboardingWindow, window.isVisible, window.occlusionState.contains(.visible),
              let status = onboardingPermissions else {
            onboardingRefreshTimer?.invalidate()
            onboardingRefreshTimer = nil
            return
        }
        status.refresh()
        if status.allGranted {
            onboardingRefreshTimer?.invalidate()
            onboardingRefreshTimer = nil
        } else if onboardingRefreshTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOnboardingRefresh() }
            }
            timer.tolerance = 0.2
            onboardingRefreshTimer = timer
        }
    }
}

// 设置窗口与引导页：设置窗口/引导页视图构建、权限引导状态刷新、
// 偏好开关动作。作为 AppDelegate 扩展实现。

import Cocoa
import Carbon.HIToolbox
import ServiceManagement

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

    /// 折叠/展开动画开始前叫醒音频设备（见 ShadeSoundPlayer 的说明）：这样音效落在动作上，不迟半秒。
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
        // 菜单栏标题保持短小（完整文案在 tooltip 与可访问性值里），
        // 否则一句长提示会把状态栏条挤得很宽，顶开旁边的菜单栏项目。
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

    private func makeSettingsPageRoot() -> (NSView, NSStackView) {
        // 背景由设置窗口的详情区统一铺满，页面保持透明。
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return (root, stack)
    }

    // 与“高级”页一致：页内不重复大标题，只留一行说明。
    private func makeSettingsHeader(title: String, subtitle: String, symbolName: String? = nil) -> NSView {
        _ = title
        return SettingsRowContent.content(name: nil, subtitle: subtitle, symbol: SettingsRowContent.tableSymbol(symbolName)).view
    }

    func makeShadeSettingsPage() -> NSView {
        let (root, stack) = makeSettingsPageRoot()
        stack.addArrangedSubview(makeSettingsHeader(
            title: "卷帘", subtitle: "设置怎么收起窗口、收起后什么样、要不要提示音。", symbolName: "rectangle.compress.vertical"))

        let trigger = makeUnifiedSettingsCard([
            makeUnifiedToggleRow(name: "双击标题栏收起窗口", subtitle: titlebarDoubleClickPreferenceSubtitle(),
                                 isOn: titlebarDoubleClickEnabled, action: #selector(prefToggleTitlebarDoubleClick(_:))),
            makeUnifiedToggleRow(name: "看一眼", subtitle: "指针停在卷帘条上，窗口在原处出现，移开就收回",
                                 isOn: GlanceController.isEnabled, action: #selector(prefToggleGlance(_:))),
        ])
        stack.addArrangedSubview(makePrefGroupLabel("触发"))
        stack.addArrangedSubview(trigger)
        trigger.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: trigger)

        stack.addArrangedSubview(makePrefGroupLabel("外观"))
        let collapseRows = makeCollapseAppearanceRows()   // [收起后的样子, 卷帘条/缩略图半透明]
        let appearance = makeUnifiedSettingsCard([
            collapseRows[0],
            makeUnifiedToggleRow(name: "浮在其他窗口上面", subtitle: "收起的窗口也不会被别的窗口挡住",
                                 isOn: floatingOnTop, action: #selector(prefToggleFloating(_:))),
            collapseRows[1],
        ])
        stack.addArrangedSubview(appearance)
        appearance.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(makePrefGroupLabel("声音"))
        let sound = makeUnifiedSettingsCard([
            makeUnifiedToggleRow(name: "收起和展开时播放音效", subtitle: nil,
                                 isOn: soundEnabled, action: #selector(prefToggleSound(_:))),
            makeUnifiedControlRow(name: "收起音效", subtitle: nil,
                                  control: makeSoundPopup(selected: foldSoundName, action: #selector(prefSelectFoldSound(_:)))),
            makeUnifiedControlRow(name: "展开音效", subtitle: nil,
                                  control: makeSoundPopup(selected: unfoldSoundName, action: #selector(prefSelectUnfoldSound(_:)))),
        ])
        stack.addArrangedSubview(sound)
        sound.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return root
    }

    /// 权限与启动：两项系统授权、登录时启动和更新。
    func makePermissionsSettingsPage() -> NSView {
        let (root, stack) = makeSettingsPageRoot()
        stack.addArrangedSubview(makeSettingsHeader(
            title: "权限与启动", subtitle: "WindowShade 只在需要时使用系统权限。", symbolName: "lock.shield"))
        stack.addArrangedSubview(makePrefGroupLabel("权限"))
        let permissions = makeUnifiedSettingsCard([
            makeUnifiedPermissionRow(symbol: "accessibility", name: "辅助功能",
                                     subtitle: "找到、移动和恢复窗口",
                                     granted: hasAccessibilityPermission(), action: #selector(openAccessibilitySettingsAction)),
            makeUnifiedPermissionRow(symbol: "rectangle.inset.filled.and.person.filled",
                                     name: "屏幕录制", subtitle: "截取窗口画面做预览",
                                     granted: hasScreenRecordingPermission(), action: #selector(openScreenRecordingSettingsAction)),
        ])
        stack.addArrangedSubview(permissions)
        permissions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makePrefGroupLabel("启动"))
        let launch = makeUnifiedSettingsCard([
            makeUnifiedToggleRow(name: "登录时自动启动", subtitle: launchAtLoginSubtitle(),
                                 isOn: launchAtLoginEnabled(), action: #selector(prefToggleLaunchAtLogin(_:))),
        ])
        stack.addArrangedSubview(launch)
        launch.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: launch)
        stack.addArrangedSubview(makePrefGroupLabel(UpdateCopy.settingsGroup))
        let update = makeUnifiedSettingsCard(MainActor.assumeIsolated { UpdaterController.shared.makeSettingsRows() })
        stack.addArrangedSubview(update)
        update.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return root
    }

    func makePrefGroupLabel(_ text: String) -> NSView {
        // 分组标题只有文字，与「效果」「高级」两页保持一致。
        let field = NSTextField(labelWithString: text)
        field.font = SystemAppearancePolicy.font(relativeToBody: -1, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// 设置里每一张卡片的外观；各页都从同一处拿，别再写第二套样式。
    func makeUnifiedSettingsCard(_ rows: [NSView], separatorInset: CGFloat = 16) -> NSView {
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
                let line = NSView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                line.addSubview(separator)
                inner.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -16),
                    line.heightAnchor.constraint(equalToConstant: 0.5),
                    separator.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: separatorInset - 16),
                    separator.trailingAnchor.constraint(equalTo: line.trailingAnchor),
                    separator.centerYAnchor.constraint(equalTo: line.centerYAnchor),
                ])
            }
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return card
    }


    private func makeUnifiedLabels(name: String, subtitle: String?, symbol: String? = nil) -> NSStackView {
        SettingsRowContent.content(name: name, subtitle: subtitle, symbol: symbol ?? SettingsRowContent.symbol(for: name)).view
    }

    private func makeUnifiedToggleRow(name: String, subtitle: String?, isOn: Bool,
                                      action: Selector) -> NSView {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.setAccessibilityLabel(name)
        toggle.controlSize = .regular
        let labels = makeUnifiedLabels(name: name, subtitle: subtitle)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, toggle])
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -14),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 40 : 48).isActive = true
        return row
    }

    private func makeUnifiedControlRow(name: String, subtitle: String?, control: NSControl) -> NSView {
        control.sizeToFit()
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let labels = makeUnifiedLabels(name: name, subtitle: subtitle)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, control])
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -14),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 40 : 48).isActive = true
        return row
    }

    private func makeUnifiedPermissionRow(symbol: String, name: String, subtitle: String,
                                           granted: Bool, action: Selector) -> NSView {
        let labels = makeUnifiedLabels(name: name, subtitle: subtitle, symbol: symbol)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chip = NSButton(title: granted ? "✓ 已授权" : "● 去授权", target: self, action: action)
        chip.isBordered = false
        chip.font = SystemAppearancePolicy.font(relativeToBody: -1)
        chip.contentTintColor = granted ? .systemGreen : .systemOrange
        SystemCornerRadius.apply(to: chip, radius: SystemCornerRadius.control)
        chip.setAccessibilityLabel("\(name)，\(granted ? "已授权，打开设置" : "去授权")")
        chip.setContentHuggingPriority(.required, for: .horizontal)
        let trailing = chip
        let row = NSStackView(views: [labels, trailing])
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return row
    }

    func makeSoundPopup(selected: String, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26), pullsDown: false)
        for sound in shadeSoundChoices {
            popup.addItem(withTitle: sound.label)
            popup.lastItem?.representedObject = sound.name
            if sound.name == selected {
                popup.select(popup.lastItem)
            }
        }
        popup.target = self
        popup.action = action
        return popup
    }

    func titlebarDoubleClickPreferenceSubtitle() -> String {
        // 标题已经说了“双击收起”，说明只补标题里没有的信息。
        systemTitlebarTripleClickDescription() ?? "在任意窗口的标题栏上双击"
    }

    func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func launchAtLoginSubtitle() -> String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return "WindowShade 会在登录后自动运行"
            case .requiresApproval:
                return "需要在系统设置中批准登录项"
            case .notRegistered:
                return "开机后自动运行 WindowShade"
            case .notFound:
                return "当前 app bundle 不支持登录项"
            @unknown default:
                return "开机后自动运行 WindowShade"
            }
        }
        return "当前系统不支持"
    }

    @objc func prefToggleTitlebarDoubleClick(_ sender: NSSwitch) {
        titlebarDoubleClickEnabled = sender.state == .on
        UserDefaults.standard.set(titlebarDoubleClickEnabled, forKey: shadeTitlebarDoubleClickDefaultsKey)
        rebuildMenu()
    }

    @objc func prefToggleGlance(_ sender: NSSwitch) {
        GlanceController.isEnabled = sender.state == .on
        if !GlanceController.isEnabled {
            MainActor.assumeIsolated { glance.cancelAll(reason: "setting-off") }
        }
        rebuildMenu()
    }

    @objc func prefToggleFloating(_ sender: NSSwitch) {
        floatingOnTop = sender.state == .on
        UserDefaults.standard.set(floatingOnTop, forKey: shadeFloatingOnTopDefaultsKey)
        refreshOverlayPresentation(bringForward: floatingOnTop)
        rebuildMenu()
    }

    @objc func prefToggleSound(_ sender: NSSwitch) {
        soundEnabled = sender.state == .on
        UserDefaults.standard.set(soundEnabled, forKey: shadeSoundEnabledDefaultsKey)
    }

    @objc func prefToggleLaunchAtLogin(_ sender: NSSwitch) {
        guard #available(macOS 13.0, *) else {
            sender.state = .off
            quietNotice("系统不支持", log: "launch-at-login: unsupported macOS")
            return
        }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
                wlog("launch-at-login: register status=\(SMAppService.mainApp.status)")
            } else {
                try SMAppService.mainApp.unregister()
                wlog("launch-at-login: unregister status=\(SMAppService.mainApp.status)")
            }
        } catch {
            sender.state = launchAtLoginEnabled() ? .on : .off
            quietNotice("无法修改开机自启", log: "launch-at-login: failed \(error.localizedDescription)")
        }
        refreshPreferencesWindowIfOpen()
    }

    @objc func prefSelectFoldSound(_ sender: NSPopUpButton) {
        foldSoundName = sender.selectedItem?.representedObject as? String ?? shadeDefaultFoldSound
        UserDefaults.standard.set(foldSoundName, forKey: shadeFoldSoundDefaultsKey)
        playFoldSound()
    }

    @objc func prefSelectUnfoldSound(_ sender: NSPopUpButton) {
        unfoldSoundName = sender.selectedItem?.representedObject as? String ?? shadeDefaultUnfoldSound
        UserDefaults.standard.set(unfoldSoundName, forKey: shadeUnfoldSoundDefaultsKey)
        playUnfoldSound()
    }

    @objc func openAccessibilitySettingsAction() {
        openAccessibilityPrivacySettings()
    }

    @objc func openScreenRecordingSettingsAction() {
        openScreenRecordingPrivacySettings()
    }

@objc func showWelcomeGuide() {
        // 菜单里的“欢迎使用 WindowShade…”：从头看起。
        showPermissionOnboarding()
    }

    func showPermissionOnboardingIfNeeded(force: Bool) {
        let missing = !hasAccessibilityPermission() || !hasScreenRecordingPermission()
        let shouldShowFirstRun = !UserDefaults.standard.bool(forKey: shadeOnboardingShownDefaultsKey)
        guard missing || shouldShowFirstRun || force else { return }
        if !force && UserDefaults.standard.bool(forKey: shadeOnboardingShownDefaultsKey) { return }
        // force 都是缺权限时的提醒（按快捷键没权限、换显示器时的恢复）：直接到授权页，
        // 和 1.0.15 一样一打开就看得到授权行。首次打开从头看起。
        showPermissionOnboarding(toPermissions: force)
    }

    /// 欢迎使用 WindowShade：授权（见 Welcome.swift）。
    /// toPermissions：缺权限时的提醒，直接到授权页；否则从头开始。
    func showPermissionOnboarding(toPermissions: Bool = false) {
        MainActor.assumeIsolated { showWelcome(fromStart: !toPermissions) }
    }

    /// 欢迎窗口里那一页（窗口没建过或内容换过时是 nil）。
    @MainActor var onboardingWelcomeView: WelcomeView? {
        onboardingWindow?.contentView?.subviews.lazy.compactMap { $0 as? WelcomeView }.first
    }

    /// 装好新版本后辅助功能或屏幕录制没了（系统有时要重新打开）：翻到授权页，换成“再打开一次这两项”那组文案。
    func showPermissionsAgainAfterUpdate() {
        MainActor.assumeIsolated {
            showWelcome(fromStart: false)
            onboardingWelcomeView?.permissionsAgain = true
        }
    }

    @MainActor private func showWelcome(fromStart: Bool) {
        // 已经开着：不重建、不挪回正中，看到哪一步还在哪一步，只拿到最前面；缺权限的提醒才翻到授权页。
        if let window = onboardingWindow, window.isVisible, let current = onboardingWelcomeView {
            if !fromStart, current.onMoveStep { current.showPermissions() }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(current)
            NSApp.activate()
            updateOnboardingRefresh()
            return
        }
        let view = WelcomeView(frame: NSRect(origin: .zero, size: WelcomeView.size))
        view.permissionsGranted = { hasAccessibilityPermission() && hasScreenRecordingPermission() }
        view.onFinish = { [weak self] in self?.dismissOnboarding() }
        view.onLater = { [weak self] in self?.dismissOnboarding() }
        onboardingPermissionStack = view.permissionStack
        onboardingProgressLabel = view.progressLabel
        onboardingDoneButton = nil
        onboardingCaption = nil
        let window: NSWindow
        if let existing = onboardingWindow {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: WelcomeView.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "欢迎使用 WindowShade"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // 引导页是独立工具窗口，不参与系统标签页合并。
            window.tabbingMode = .disallowed
            onboardingWindow = window
            // 点关闭按钮也算看过：否则下次启动它又会自己弹出来。缺权限时的再次提醒
            // 走的是“缺权限”这条判断，不受这个标记影响。
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                // 观察者指定了主队列，回调在主线程。
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(true, forKey: shadeOnboardingShownDefaultsKey)
                    self?.onboardingRefreshTimer?.invalidate()
                    self?.onboardingRefreshTimer = nil
                }
            }
            // 整个被挡住、在别的桌面上时授权页不再每秒查；又看得见了马上刷新一次、接着查。
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOnboardingRefresh() }
            }
        }
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: WelcomeView.size))
        let appearance = SystemAppearanceCapabilities.current
        background.material = SystemAppearancePolicy.usesOpaqueFallback(appearance) ? .contentBackground : .underPageBackground
        background.blendingMode = .withinWindow
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        window.contentView = background
        window.setContentSize(WelcomeView.size)
        window.center()
        refreshOnboardingState()
        view.onPageChange = { [weak self] in self?.updateOnboardingRefresh() }
        // 从头打开、而 App 不在“应用程序”里：授权之前先问要不要放进去（UpdaterMove 决定要不要这一步）。
        // 开发版没有更新清单地址、不启动更新器，“放进去才能更新”对它不成立，不问。
        if fromStart, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
           let move = UpdaterMove.shared.welcomeStep() {
            view.showMove(move)
        } else { view.refreshButtons() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        updateOnboardingRefresh()
    }

    /// 授权页的刷新：在系统设置里打开了，这里马上变成打勾。只在窗口看得见、停在授权页、还没全部授权时每秒查一次；
    /// 停在别的步、两项都有了、窗口收起来或整个被挡住就停（1.0.15 起权限齐全时本来就不跑）。
    @MainActor func updateOnboardingRefresh() {
        guard let window = onboardingWindow, window.isVisible, window.occlusionState.contains(.visible),
              let view = onboardingWelcomeView, !view.onMoveStep else {
            onboardingRefreshTimer?.invalidate()
            onboardingRefreshTimer = nil
            return
        }
        if refreshOnboardingState() { view.refreshButtons() }
        if view.shownGrants == [true, true] {
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

    /// 按现在的授权状态画授权行和进度字；和上次画的一样就什么都不动。返回画没画。
    @MainActor @discardableResult
    func refreshOnboardingState() -> Bool {
        guard let permissionStack = onboardingPermissionStack else { return false }
        let ax = hasAccessibilityPermission()
        let screen = hasScreenRecordingPermission()
        let welcome = onboardingWelcomeView
        if let welcome, welcome.shownGrants == [ax, screen] { return false }
        welcome?.shownGrants = [ax, screen]

        permissionStack.arrangedSubviews.forEach {
            permissionStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let card = makeUnifiedSettingsCard([
            makeUnifiedPermissionRow(symbol: "accessibility", name: "辅助功能",
                subtitle: "找到、移动和恢复窗口", granted: ax,
                action: #selector(openAccessibilitySettingsAction)),
            makeUnifiedPermissionRow(symbol: "rectangle.inset.filled.and.person.filled", name: "屏幕录制",
                subtitle: "截取窗口画面做预览", granted: screen,
                action: #selector(openScreenRecordingSettingsAction)),
        ])
        permissionStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalToConstant: onboardingContentWidth).isActive = true

        let grantedCount = (ax ? 1 : 0) + (screen ? 1 : 0)
        let allGranted = grantedCount == 2
        if let progress = onboardingProgressLabel {
            if allGranted {
                progress.stringValue = "权限已就绪"
                progress.textColor = .systemGreen
            } else {
                progress.stringValue = "还差\(2 - grantedCount)步权限 · \(grantedCount) / 2 已完成"
                progress.textColor = .labelColor
            }
        }
        onboardingDoneButton?.isEnabled = allGranted
        onboardingCaption?.isHidden = allGranted
        return true
    }

    func makeShortcutsSettingsPage() -> NSView {
        let (root, stack) = makeSettingsPageRoot()
        stack.addArrangedSubview(makeSettingsHeader(
            title: "快捷键",
            subtitle: "在任何应用里都能用。点“录制…”再按下新的组合；“清除”会关掉这个快捷键。",
            symbolName: "command"))

        func recorderRow(_ shortcut: GlobalShortcut, subtitle: String?) -> NSView {
            let recorder = HotKeyRecorderView(accessibilityName: shortcut.title)
            recorder.configure(current: GlobalShortcutSettings.hotKey(for: shortcut))
            recorder.validate = { hotKey in
                GlobalShortcutSettings.conflictName(for: hotKey, excluding: shortcut)
                    .map { "已用于：\($0)" }
            }
            recorder.onCapture = { [weak self, weak recorder] hotKey in
                self?.applyShortcut(hotKey, for: shortcut)
                recorder?.configure(current: GlobalShortcutSettings.hotKey(for: shortcut))
            }
            return makeUnifiedControlRow(name: shortcut.title, subtitle: subtitle, control: recorder)
        }

        let window = makeUnifiedSettingsCard([
            recorderRow(.toggleShade, subtitle: nil),
        ])
        stack.addArrangedSubview(makePrefGroupLabel("当前窗口"))
        stack.addArrangedSubview(window)
        window.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: window)

        let strips = makeUnifiedSettingsCard([
            recorderRow(.arrange, subtitle: "把卷帘条排到屏幕一侧，再按放回原位"),
            makeUnifiedToggleRow(
                name: "按编号展开已收起的窗口",
                subtitle: "\(GlobalShortcutSettings.numberedDisplayName) 对应菜单里的前 9 个窗口",
                isOn: GlobalShortcutSettings.numberedExpandEnabled,
                action: #selector(prefToggleNumberedShortcuts(_:))),
        ])
        stack.addArrangedSubview(makePrefGroupLabel("已收起的窗口"))
        stack.addArrangedSubview(strips)
        strips.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(12, after: strips)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(prefResetShortcuts))
        reset.bezelStyle = .rounded
        reset.isEnabled = !GlobalShortcutSettings.isAllDefault
        reset.setContentHuggingPriority(.required, for: .horizontal)
        // 靠右的普通按钮，与分组卡片右边缘对齐；不随页面宽度拉伸。
        let resetRow = NSStackView()
        resetRow.orientation = .horizontal
        resetRow.addView(reset, in: .trailing)
        stack.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return root
    }

    /// 改键后立刻生效：重新注册、刷新菜单；新组合注册失败时退回原来的组合。
    private func applyShortcut(_ hotKey: HotKey?, for shortcut: GlobalShortcut) {
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

    @objc func prefToggleNumberedShortcuts(_ sender: NSSwitch) {
        GlobalShortcutSettings.numberedExpandEnabled = sender.state == .on
        registerGlobalShortcuts()
        rebuildMenu()
        refreshPreferencesWindowIfOpen()
    }

    @objc func prefResetShortcuts() {
        GlobalShortcutSettings.resetAll()
        registerGlobalShortcuts()
        rebuildMenu()
        refreshPreferencesWindowIfOpen()
    }

}

/// 快捷键记录器：只在设置页明确聚焦时读取键盘事件，不安装任何全局监听。
final class HotKeyRecorderView: NSControl {
    var onCapture: ((HotKey?) -> Void)?
    /// 录到的组合不能用时返回原因（显示在标签里）；能用返回 nil。
    var validate: ((HotKey) -> String?)?
    private let label = NSTextField(labelWithString: "未设置")
    private let recordButton = NSButton(title: "录制…", target: nil, action: nil)
    private let clearButton = NSButton(title: "清除", target: nil, action: nil)
    private var current: HotKey?
    private var recording = false
    private var messageWork: DispatchWorkItem?

    init(accessibilityName: String) {
        super.init(frame: .zero)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        for button in [recordButton, clearButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        recordButton.target = self
        recordButton.action = #selector(beginRecording)
        clearButton.target = self
        clearButton.action = #selector(clearHotKey)
        for view in [label, recordButton, clearButton] { addSubview(view) }
        widthAnchor.constraint(equalToConstant: 280).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityName)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func configure(current: HotKey?) {
        self.current = current
        messageWork?.cancel()
        showText(current.map { HotKey.displayName(for: $0) } ?? "未设置")
        clearButton.isEnabled = current != nil
    }

    private func showText(_ text: String) {
        label.stringValue = text
        label.toolTip = text
        setAccessibilityValue(text)
        needsLayout = true
    }

    /// 录到不能用的组合：提示音 + 标签里说明原因，1.8 秒后回到当前组合。
    private func reject(_ message: String) {
        shadeSounds.beep()
        showText(message)
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.configure(current: self.current)
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    override func layout() {
        super.layout()
        clearButton.frame = NSRect(x: bounds.width - 56, y: (bounds.height - 24) / 2,
                                   width: 56, height: 24)
        recordButton.frame = NSRect(x: bounds.width - 56 - 6 - 64,
                                    y: (bounds.height - 24) / 2, width: 64, height: 24)
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2,
                             width: max(60, recordButton.frame.minX - 8), height: 16)
    }

    @objc private func beginRecording() {
        recording = true
        messageWork?.cancel()
        showText("请按快捷键…")
        window?.makeFirstResponder(self)
    }

    @objc private func clearHotKey() {
        recording = false
        onCapture?(nil)
    }

    override func resignFirstResponder() -> Bool {
        if recording {
            recording = false
            configure(current: current)
        }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            configure(current: current)
            return
        }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        // 只按修饰键不构成快捷键：保持录制状态，等真正的键。
        guard !HotKey.isModifierOnlyKeyCode(event.keyCode) else { return }
        recording = false
        let hotKey = HotKey(keyCode: UInt32(event.keyCode),
                            modifiers: Self.carbonModifiers(from: event.modifierFlags))
        if HotKey.isReserved(hotKey) {
            let hasControlOrOption = hotKey.modifiers & UInt32(controlKey | optionKey) != 0
            reject(hasControlOrOption ? "系统在用这个组合" : "组合里要有 ⌃ 或 ⌥")
            return
        }
        if let message = validate?(hotKey) {
            reject(message)
            return
        }
        onCapture?(hotKey)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
